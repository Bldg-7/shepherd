import Foundation

/// One unfiltered subscription on one direct origin connection. Terminal
/// snapshots do not contain documents. This reducer requests reads, never writes.
nonisolated struct CoreWorkspaceEvents: Sendable {
    struct Initial: Decodable, Sendable { let seq: UInt64 }
    struct Effect: Sendable {
        var refresh = false
        var minimumVersion: UInt64?
        mutating func merge(_ other: Self) {
            refresh = refresh || other.refresh
            if let next = other.minimumVersion { minimumVersion = max(minimumVersion ?? 0, next) }
        }
    }
    private struct Notice: Decodable {
        struct Params: Decodable {
            struct Change: Decodable { let name: String?; let version: UInt64? }
            let seq: UInt64
            let type: String?
            let machine: String?
            let data: Change?
            private enum CodingKeys: String, CodingKey { case seq, type, machine, data }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                seq = try c.decode(UInt64.self, forKey: .seq)
                type = try c.decodeIfPresent(String.self, forKey: .type)
                machine = try c.decodeIfPresent(String.self, forKey: .machine)
                data = type == "doc" ? try c.decode(Change.self, forKey: .data) : nil
            }
        }
        let jsonrpc: String
        let method: String
        let params: Params
    }
    private(set) var sequence: UInt64
    private let remoteDocuments: Bool
    init(sequence: UInt64, remoteDocuments: Bool = false) { self.sequence = sequence; self.remoteDocuments = remoteDocuments }

    mutating func consume(_ bytes: Data) throws -> Effect {
        let notice = try JSONDecoder().decode(Notice.self, from: bytes)
        guard notice.jsonrpc == "2.0" else { throw CoreWorkspaceFailure.invalidDocument }
        let next = notice.params.seq
        switch notice.method {
        case "snapshot", "missed":
            guard next >= sequence else { throw CoreWorkspaceSyncFailure.inconsistentSnapshot }
            sequence = next
            return Effect(refresh: true)
        case "heartbeat":
            guard next >= sequence else { throw CoreWorkspaceSyncFailure.inconsistentSnapshot }
            let gap = next > sequence; sequence = next
            return Effect(refresh: gap)
        case "event":
            // After missed, the protocol explicitly permits events at/below
            // the snapshot sequence. Never let them regress document versions.
            guard next > sequence else { return Effect() }
            let gap = next - sequence > 1; sequence = next
            guard let type = notice.params.type, !type.isEmpty else { throw CoreWorkspaceFailure.invalidDocument }
            guard type == "doc" else { return Effect(refresh: gap) }
            guard let change = notice.params.data, let name = change.name, let version = change.version else {
                throw CoreWorkspaceFailure.invalidDocument
            }
            guard name == CoreWorkspaceDocument.documentName else { return Effect(refresh: gap) }
            if remoteDocuments {
                // machine is a mutable alias, not a stable origin. Any matching
                // remote notice conservatively invalidates our selected ID's
                // read, but NEVER advances its version from another origin.
                return Effect(refresh: gap || notice.params.machine != nil)
            }
            // A gateway's remote document is not the direct origin's document.
            guard notice.params.machine == nil else { return Effect(refresh: gap) }
            return Effect(refresh: true, minimumVersion: version)
        default: throw CoreWorkspaceFailure.invalidDocument
        }
    }
}
