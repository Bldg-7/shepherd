#if os(macOS)
import Foundation
import Observation

/// The iPhone and iPad page's list: the devices the pairing page added,
/// each with whether its line is still in `~/.ssh/authorized_keys`, and the
/// pairing history, newest first. Read again each time the page appears.
@MainActor @Observable final class PairedDevicesModel {
    struct Row: Identifiable, Equatable {
        enum Status: Equatable {
            case inFile
            /// Taken out of `authorized_keys` by hand: the device can't log in.
            case notInFile
            /// `authorized_keys` couldn't be read as one the page writes.
            case unknown
        }

        let device: PairedDevice
        let status: Status
        var id: String { device.id }
    }

    /// Why a device couldn't be removed, and its line, to take out by hand.
    struct RemovalFailure: Equatable {
        let deviceName: String
        let message: String
        let line: String
    }

    private(set) var rows: [Row] = []
    private(set) var history: [PairingAuditEntry] = []
    private(set) var loadError: String?
    var removalFailure: RemovalFailure?

    private let store: PairedDeviceStore
    private let authorizedKeys: AuthorizedKeysFile
    private let now: () -> Date

    init(store: PairedDeviceStore, authorizedKeys: AuthorizedKeysFile, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.authorizedKeys = authorizedKeys
        self.now = now
    }

    static func system() -> PairedDevicesModel {
        PairedDevicesModel(store: .standard(), authorizedKeys: .forThisAccount())
    }

    func reload() {
        loadError = nil
        do {
            rows = try store.devices().sorted { $0.addedAt > $1.addedAt }.map { device in
                switch authorizedKeys.contains(lineText: device.line) {
                case true?: Row(device: device, status: .inFile)
                case false?: Row(device: device, status: .notInFile)
                case nil: Row(device: device, status: .unknown)
                }
            }
        } catch {
            rows = []
            loadError = error.localizedDescription
        }
        history = ((try? store.history()) ?? []).reversed()
    }

    /// Takes the device's line out of `authorized_keys` — only the line
    /// with its key and marker — and forgets it. When the file can't be
    /// written, it is left as it is and the device stays listed.
    func remove(_ row: Row) {
        let device = row.device
        let event: PairingAuditEntry.Event
        do {
            event = try authorizedKeys.remove(lineText: device.line) == .removed ? .removed : .removedNotInFile
            try store.remove(device)
        } catch {
            removalFailure = RemovalFailure(deviceName: device.name, message: error.localizedDescription, line: device.line)
            reload()
            return
        }
        try? store.record(PairingAuditEntry(date: now(), event: event, deviceID: device.deviceID, deviceName: device.name,
                                            deviceModel: device.model, keyFingerprint: device.keyFingerprint))
        reload()
    }
}
#endif
