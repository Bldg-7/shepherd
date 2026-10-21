#if os(macOS)
import Foundation

/// A device this Mac let in by its pairing page: what it said it was, and
/// the line written for it. Nothing secret.
nonisolated struct PairedDevice: Codable, Hashable, Sendable, Identifiable {
    var deviceID: UUID
    var name: String
    var model: String
    var appVersion: String
    /// `SHA256:…` of the device's key.
    var keyFingerprint: String
    /// The `authorized_keys` line, as written.
    var line: String
    var addedAt: Date
    /// The kind of address it paired over.
    var addressKind: PairingAddressKind?

    var id: String { deviceID.uuidString + " " + keyFingerprint }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case name
        case model
        case appVersion = "app_version"
        case keyFingerprint = "key_fingerprint"
        case line
        case addedAt = "added_at"
        case addressKind = "address_kind"
    }
}

/// One thing that happened on the pairing page, for the history it keeps.
nonisolated struct PairingAuditEntry: Codable, Hashable, Sendable, Identifiable {
    enum Event: String, Codable, Sendable {
        /// A device sent the code's request.
        case requested
        /// Another request came for a code that had been used.
        case requestAfterUse = "request_after_use"
        case approved
        case rejected
        /// No answer within the time allowed.
        case timedOut = "timed_out"
        /// The device closed its connection before it was answered.
        case cancelled
        case keyAdded = "key_added"
        case keyAlreadyPresent = "key_already_present"
        case keyNotWritten = "key_not_written"
        /// The device's report of its first connection.
        case connectionChecked = "connection_checked"
        case connectionNotReported = "connection_not_reported"
        /// The listener closed after too many requests that weren't right.
        case tooManyFailures = "too_many_failures"
        case removed
        case removedNotInFile = "removed_not_in_file"
    }

    var id: UUID
    var date: Date
    var event: Event
    var deviceID: UUID?
    var deviceName: String?
    var deviceModel: String?
    var keyFingerprint: String?
    var remoteAddress: String?
    var addressKind: PairingAddressKind?
    var detail: String?

    init(id: UUID = UUID(), date: Date, event: Event, deviceID: UUID? = nil, deviceName: String? = nil, deviceModel: String? = nil,
         keyFingerprint: String? = nil, remoteAddress: String? = nil, addressKind: PairingAddressKind? = nil, detail: String? = nil) {
        self.id = id
        self.date = date
        self.event = event
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.keyFingerprint = keyFingerprint
        self.remoteAddress = remoteAddress
        self.addressKind = addressKind
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case event
        case deviceID = "device_id"
        case deviceName = "device_name"
        case deviceModel = "device_model"
        case keyFingerprint = "key_fingerprint"
        case remoteAddress = "remote_address"
        case addressKind = "address_kind"
        case detail
    }
}

/// The devices the pairing page added and its history, as JSON in the
/// app's Application Support folder: `paired-devices.json` and
/// `pairing-history.json`, the latter the last 1,000 entries. Read again
/// every time the list is shown, so a device whose line was taken out of
/// `authorized_keys` by hand shows as such.
///
/// Debug and release builds share the folder, as they share the
/// `authorized_keys` file the list describes.
nonisolated struct PairedDeviceStore: Sendable {
    static let historyLimit = 1000

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func standard() -> PairedDeviceStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PairedDeviceStore(directory: support.appending(path: Bundle.main.bundleIdentifier ?? "com.bldg-7.shepherd"))
    }

    var devicesURL: URL { directory.appending(path: "paired-devices.json") }
    var historyURL: URL { directory.appending(path: "pairing-history.json") }

    func devices() throws -> [PairedDevice] {
        try read([PairedDevice].self, from: devicesURL) ?? []
    }

    func add(_ device: PairedDevice) throws {
        var devices = try devices()
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        try write(devices, to: devicesURL)
    }

    func remove(_ device: PairedDevice) throws {
        var devices = try devices()
        devices.removeAll { $0.id == device.id }
        try write(devices, to: devicesURL)
    }

    /// Newest last.
    func history() throws -> [PairingAuditEntry] {
        try read([PairingAuditEntry].self, from: historyURL) ?? []
    }

    func record(_ entry: PairingAuditEntry) throws {
        var entries = try history()
        entries.append(entry)
        if entries.count > Self.historyLimit { entries.removeFirst(entries.count - Self.historyLimit) }
        try write(entries, to: historyURL)
    }

    // MARK: - Files

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Small values the pairing page keeps between visits. `UserDefaults` in
/// the app; a dictionary in tests, which leave the real defaults alone.
nonisolated struct PairingPreferences: @unchecked Sendable {
    let read: @Sendable (String) -> String?
    let write: @Sendable (String, String?) -> Void

    static let installationIDKey = "pairing.installationID"
    static let lastAddressKindKey = "pairing.lastAddressKind"

    static var standard: PairingPreferences {
        PairingPreferences(read: { UserDefaults.standard.string(forKey: $0) },
                           write: { key, value in UserDefaults.standard.set(value, forKey: key) })
    }

    /// This Mac's installation ID, made the first time it is asked for. A
    /// device saves the Mac it pairs with under it, so each Mac's is its
    /// own — unlike the built-in "This Mac" entry's ID, which is the same
    /// on every Mac.
    func installationID() -> UUID {
        if let text = read(Self.installationIDKey), let id = UUID(uuidString: text) { return id }
        let id = UUID()
        write(Self.installationIDKey, id.uuidString)
        return id
    }

    /// The kind of address chosen last; only the kind, never the address.
    var lastAddressKind: PairingAddressKind? {
        read(Self.lastAddressKindKey).flatMap(PairingAddressKind.init(rawValue:))
    }

    func setLastAddressKind(_ kind: PairingAddressKind) {
        write(Self.lastAddressKindKey, kind.rawValue)
    }
}
#endif
