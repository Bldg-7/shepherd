#if os(macOS)
import Foundation

/// A manual page attachment is independent of root auto-attach. Policy epochs
/// invalidate automatic acquisitions before a disable can await native replies.
@MainActor final class CDPPageSessionState {
    enum Kind: Hashable { case automatic, manual }
    struct Key: Hashable {
        let target: String
        let kind: Kind
    }
    private(set) var autoAttach = false
    private(set) var epoch: UInt64 = 0
    var changing = false
    var acquiring = Set<Key>()
    private var records: [Key: String] = [:]
    private(set) var retiringAutomatic = Set<String>()

    @discardableResult
    func setAutoAttach(_ enabled: Bool) -> UInt64 {
        epoch += 1
        autoAttach = enabled
        if !enabled {
            retiringAutomatic.formUnion(records.filter { $0.key.kind == .automatic }.values)
        }
        return epoch
    }

    func canPublish(_ key: Key, epoch acquisitionEpoch: UInt64) -> Bool {
        key.kind == .manual || (autoAttach && epoch == acquisitionEpoch)
    }

    func session(for key: Key) -> String? {
        guard let session = records[key], !retiringAutomatic.contains(session) else { return nil }
        return session
    }

    func record(_ session: String, for key: Key) { records[key] = session }

    func remove(_ session: String) {
        records = records.filter { $0.value != session }
        retiringAutomatic.remove(session)
    }

    func contains(_ session: String) -> Bool { records.values.contains(session) }

    func sessions(for target: String) -> [String] {
        records.filter { $0.key.target == target }.map(\.value)
    }

    var hasAutomaticAcquisition: Bool { acquiring.contains { $0.kind == .automatic } }
}
#endif
