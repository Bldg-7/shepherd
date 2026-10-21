import CryptoKit
import Foundation

/// What a Mac's pairing QR code holds (SHPHRD-77, "QR 내용"), and the
/// code's text: `SHPHRD1:` and the fields as binary TLV, in base64url without
/// padding, 1 KiB at most. Only Shepherd's own scanner reads it.
///
/// Each field is one byte of tag, one byte of length and the value. Every
/// field is required except the herdr session, which is left out for herdr's
/// default session. A field this version doesn't know, a field twice, or
/// anything after the last field makes the whole code unreadable: a new
/// field comes with a new version, which this version turns down as needing
/// an update, as it does an address kind it doesn't know.
public nonisolated struct PairingPayload: Hashable, Sendable {
    public static let prefix = "SHPHRD1:"
    public static let version: UInt8 = 1
    /// Of the whole text, prefix included.
    public static let maximumLength = 1024
    /// The pairing listener's port is a user port.
    public static let minimumPairingPort: UInt16 = 1024
    /// The Mac's Remote Login, the only SSH server this pairs with.
    public static let sshPort: UInt16 = 22
    /// For the user name and the Mac's name, in UTF-8.
    public static let maximumTextLength = 255

    /// The host key's algorithm, as the code names it in one byte.
    public enum HostKeyAlgorithm: UInt8, CaseIterable, Sendable {
        case ed25519 = 1
        case ecdsaP256 = 2
        case ecdsaP384 = 3
        case ecdsaP521 = 4
        case rsa = 5

        /// The SSH name of the key type.
        public var name: String {
            switch self {
            case .ed25519: "ssh-ed25519"
            case .ecdsaP256: "ecdsa-sha2-nistp256"
            case .ecdsaP384: "ecdsa-sha2-nistp384"
            case .ecdsaP521: "ecdsa-sha2-nistp521"
            case .rsa: "ssh-rsa"
            }
        }

        public init?(name: String) {
            guard let algorithm = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = algorithm
        }
    }

    /// The Mac's SSH host key: its algorithm and the SHA-256 of its blob.
    /// The device pins it before its first connection, so that connection
    /// isn't trust-on-first-use.
    public struct HostKey: Hashable, Sendable {
        public let algorithm: HostKeyAlgorithm
        public let sha256: Data

        public init(algorithm: HostKeyAlgorithm, sha256: Data) throws {
            guard sha256.count == 32 else { throw PairingPayloadError.malformed }
            self.algorithm = algorithm
            self.sha256 = sha256
        }

        /// From the host key's SSH wire form; the algorithm is read from it.
        public init(publicKeyBlob: Data) throws {
            var reader = SSHFieldReader(Array(publicKeyBlob))
            guard let type = reader.readString(), let algorithm = HostKeyAlgorithm(name: String(decoding: type, as: UTF8.self)) else {
                throw PairingPayloadError.malformed
            }
            try self.init(algorithm: algorithm, sha256: Data(SHA256.hash(data: publicKeyBlob)))
        }

        /// In the form `Machine.pinnedHostKeyFingerprint` holds.
        public var fingerprint: String {
            SSHKeyFingerprint.sha256(digest: sha256)
        }
    }

    /// Names this code's channel; also the HPKE PSK identifier. 16 bytes.
    public var sessionID: Data
    /// The code's one-time secret, the HPKE pre-shared key. 32 bytes.
    public var presharedKey: Data
    /// The X25519 public key the Mac made for this code alone. 32 bytes.
    public var macPublicKey: Data
    /// Whole seconds.
    public var expiresAt: Date
    public var pairingPort: UInt16
    public var address: PairingAddress
    public var sshPort: UInt16
    public var hostKey: HostKey
    /// The Mac account the device logs in as.
    public var username: String
    /// Empty for herdr's default session, as in `Machine.sessionName`.
    public var herdrSession: String
    /// The Mac's installation ID, which becomes the device's `Machine.id`.
    public var macID: UUID
    public var macName: String

    public init(sessionID: Data, presharedKey: Data, macPublicKey: Data, expiresAt: Date, pairingPort: UInt16,
                address: PairingAddress, sshPort: UInt16 = PairingPayload.sshPort, hostKey: HostKey, username: String,
                herdrSession: String = "", macID: UUID, macName: String) throws {
        self.sessionID = sessionID
        self.presharedKey = presharedKey
        self.macPublicKey = macPublicKey
        self.expiresAt = Date(timeIntervalSince1970: expiresAt.timeIntervalSince1970.rounded(.down))
        self.pairingPort = pairingPort
        self.address = address
        self.sshPort = sshPort
        self.hostKey = hostKey
        self.username = username
        self.herdrSession = herdrSession
        self.macID = macID
        self.macName = macName
        try validate()
    }

    public func isExpired(at now: Date) -> Bool {
        now >= expiresAt
    }

    /// The machine the device saves once the Mac has approved it: the Mac's
    /// installation ID as its ID, the code's address and its kind, the host
    /// key pinned from the code, and the device key as its credential — which
    /// goes in with `MachineStore.addMachine(_:privateKey:)` and
    /// `SecureEnclaveSSHKey.storedRepresentation`.
    @MainActor public func machine(displayName: String? = nil) -> Machine {
        var machine = Machine(id: macID, displayName: displayName ?? macName, hostname: address.hostname, port: Int(sshPort),
                              username: username, authMethod: .secureEnclaveKey, sessionName: herdrSession, addressKind: address.kind)
        machine.pinnedHostKeyFingerprint = hostKey.fingerprint
        return machine
    }

    // MARK: - Text

    public func encoded() throws -> String {
        try validate()
        var bytes: [UInt8] = []
        func field(_ tag: Tag, _ value: [UInt8]) {
            bytes.append(tag.rawValue)
            bytes.append(UInt8(value.count))
            bytes.append(contentsOf: value)
        }
        field(.version, [Self.version])
        field(.sessionID, Array(sessionID))
        field(.presharedKey, Array(presharedKey))
        field(.macPublicKey, Array(macPublicKey))
        field(.expiresAt, Self.bigEndian(UInt64(expiresAt.timeIntervalSince1970), count: 8))
        field(.pairingPort, Self.bigEndian(UInt64(pairingPort), count: 2))
        switch address.value {
        case .ipv4(let ipv4): field(.address, [address.kind.tag] + ipv4.bytes)
        case .name(let name): field(.address, [address.kind.tag] + Array(name.utf8))
        }
        field(.sshPort, Self.bigEndian(UInt64(sshPort), count: 2))
        field(.hostKey, [hostKey.algorithm.rawValue] + Array(hostKey.sha256))
        field(.username, Array(username.utf8))
        if !herdrSession.isEmpty { field(.herdrSession, Array(herdrSession.utf8)) }
        field(.macID, Self.bytes(of: macID))
        field(.macName, Array(macName.utf8))
        let text = Self.prefix + Self.base64URL(Data(bytes))
        guard text.utf8.count <= Self.maximumLength else { throw PairingPayloadError.tooLong }
        return text
    }

    /// Reads a scanned code. Every check a code's fields are held to is made
    /// here, before anything is connected to: the address against its kind
    /// (`PairingAddress`), the ports, the lengths. Expiry is the caller's,
    /// with `isExpired(at:)`.
    public init(scanned: String) throws {
        guard scanned.utf8.count <= Self.maximumLength else { throw PairingPayloadError.tooLong }
        guard scanned.hasPrefix(Self.prefix) else {
            throw Self.isLaterVersionPrefix(scanned) ? PairingPayloadError.needsNewerApp : PairingPayloadError.notAPairingCode
        }
        guard let data = Self.decodeBase64URL(scanned.dropFirst(Self.prefix.count)) else { throw PairingPayloadError.malformed }

        var fields: [UInt8: [UInt8]] = [:]
        var order: [UInt8] = []
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { throw PairingPayloadError.malformed }
            let tag = bytes[offset], length = Int(bytes[offset + 1])
            offset += 2
            guard bytes.count - offset >= length, fields[tag] == nil else { throw PairingPayloadError.malformed }
            fields[tag] = Array(bytes[offset..<offset + length])
            order.append(tag)
            offset += length
        }
        // The version comes first, so that a later version's other changes
        // are reported as needing an update rather than as damage.
        guard let version = fields[Tag.version.rawValue], version.count == 1 else { throw PairingPayloadError.malformed }
        guard version[0] == Self.version else {
            throw version[0] > Self.version ? PairingPayloadError.needsNewerApp : PairingPayloadError.malformed
        }
        guard order.allSatisfy({ Tag(rawValue: $0) != nil }) else { throw PairingPayloadError.malformed }

        func required(_ tag: Tag, count: Int? = nil) throws -> [UInt8] {
            guard let value = fields[tag.rawValue], count.map({ value.count == $0 }) ?? true else { throw PairingPayloadError.malformed }
            return value
        }
        func text(_ tag: Tag) throws -> String {
            guard let value = String(bytes: try required(tag), encoding: .utf8) else { throw PairingPayloadError.malformed }
            return value
        }

        let addressField = try required(.address)
        guard let kindTag = addressField.first else { throw PairingPayloadError.malformed }
        guard let kind = PairingAddressKind(tag: kindTag) else { throw PairingPayloadError.needsNewerApp }
        let addressValue = addressField.dropFirst()
        let address: PairingAddress
        do {
            if kind.isName {
                guard let name = String(bytes: addressValue, encoding: .utf8) else { throw PairingPayloadError.malformed }
                address = try PairingAddress(kind: kind, name: name)
            } else {
                guard let ipv4 = PairingIPv4(bytes: addressValue) else { throw PairingPayloadError.malformed }
                address = try PairingAddress(kind: kind, ipv4: ipv4)
            }
        } catch let error as PairingAddressError {
            throw PairingPayloadError.invalidAddress(error)
        }

        let hostKeyField = try required(.hostKey, count: 33)
        guard let algorithm = HostKeyAlgorithm(rawValue: hostKeyField[0]) else { throw PairingPayloadError.malformed }
        let herdrSession: String
        if let session = fields[Tag.herdrSession.rawValue] {
            guard let name = String(bytes: session, encoding: .utf8), !name.isEmpty else { throw PairingPayloadError.malformed }
            herdrSession = name
        } else {
            herdrSession = ""
        }
        let macIDBytes = try required(.macID, count: 16)

        try self.init(
            sessionID: Data(try required(.sessionID, count: 16)),
            presharedKey: Data(try required(.presharedKey, count: 32)),
            macPublicKey: Data(try required(.macPublicKey, count: 32)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(Self.number(try required(.expiresAt, count: 8)))),
            pairingPort: UInt16(Self.number(try required(.pairingPort, count: 2))),
            address: address,
            sshPort: UInt16(Self.number(try required(.sshPort, count: 2))),
            hostKey: HostKey(algorithm: algorithm, sha256: Data(hostKeyField.dropFirst())),
            username: try text(.username),
            herdrSession: herdrSession,
            macID: UUID(uuid: (macIDBytes[0], macIDBytes[1], macIDBytes[2], macIDBytes[3], macIDBytes[4], macIDBytes[5], macIDBytes[6], macIDBytes[7],
                               macIDBytes[8], macIDBytes[9], macIDBytes[10], macIDBytes[11], macIDBytes[12], macIDBytes[13], macIDBytes[14], macIDBytes[15])),
            macName: try text(.macName)
        )
    }

    // MARK: - Checks

    private func validate() throws {
        guard sessionID.count == 16, presharedKey.count == 32, macPublicKey.count == 32,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicKey)) != nil else {
            throw PairingPayloadError.malformed
        }
        guard pairingPort >= Self.minimumPairingPort, sshPort == Self.sshPort else { throw PairingPayloadError.malformed }
        guard expiresAt.timeIntervalSince1970 >= 0, expiresAt.timeIntervalSince1970 < 0x1_0000_0000_0000 else { throw PairingPayloadError.malformed }
        guard Self.isAcceptableText(username, allowingSpaces: false), Self.isAcceptableText(macName, allowingSpaces: true) else {
            throw PairingPayloadError.malformed
        }
        guard herdrSession.isEmpty || Machine.normalizedSessionName(herdrSession) == herdrSession else { throw PairingPayloadError.malformed }
    }

    /// One to 255 bytes of UTF-8 with no control character; with no
    /// whitespace at all for the user name.
    private static func isAcceptableText(_ text: String, allowingSpaces: Bool) -> Bool {
        let count = text.utf8.count
        guard (1...maximumTextLength).contains(count) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format { return false }
            if !allowingSpaces && scalar.properties.isWhitespace { return false }
            return scalar.value != 0x2028 && scalar.value != 0x2029
        }
    }

    // MARK: - Encoding helpers

    private enum Tag: UInt8 {
        case version = 0x01
        case sessionID = 0x02
        case presharedKey = 0x03
        case macPublicKey = 0x04
        case expiresAt = 0x05
        case pairingPort = 0x06
        case address = 0x07
        case sshPort = 0x08
        case hostKey = 0x09
        case username = 0x0A
        case herdrSession = 0x0B
        case macID = 0x0C
        case macName = 0x0D
    }

    private static func isLaterVersionPrefix(_ text: String) -> Bool {
        guard text.hasPrefix("SHPHRD"), let colon = text.firstIndex(of: ":") else { return false }
        let digits = text[text.index(text.startIndex, offsetBy: 6)..<colon]
        guard (1...4).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else { return false }
        return number > Int(version)
    }

    private static func bigEndian(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private static func number(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64url without padding, and nothing else: no padding, no line
    /// breaks, no characters of standard base64.
    static func decodeBase64URL(_ text: Substring) -> Data? {
        let allowed = text.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }
        guard allowed, text.utf8.count % 4 != 1 else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}

public nonisolated enum PairingPayloadError: Error, Equatable, LocalizedError {
    case notAPairingCode
    /// A later version of the code, or an address kind this version doesn't know.
    case needsNewerApp
    case tooLong
    case malformed
    case invalidAddress(PairingAddressError)
    /// For the scanner to throw when `isExpired(at:)`.
    case expired

    public var errorDescription: String? {
        switch self {
        case .notAPairingCode:
            String(localized: "This isn't a Shepherd pairing code.", bundle: .shepherdKit)
        case .needsNewerApp:
            String(localized: "This pairing code needs a newer version of Shepherd. Update the app, then scan the code again.", bundle: .shepherdKit)
        case .tooLong, .malformed:
            String(localized: "This pairing code is damaged or incomplete.", bundle: .shepherdKit)
        case .invalidAddress(let error):
            error.errorDescription
        case .expired:
            String(localized: "This pairing code has expired. Show a new one on the Mac.", bundle: .shepherdKit)
        }
    }
}
