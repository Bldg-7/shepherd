import Foundation
import CryptoKit
#if canImport(ShepherdKit)
import ShepherdKit
#endif

/// Display-only cache. Never supplies a connection, credential, live status
/// precondition or write baseline. Every terminal action opens/fetches afresh.
@MainActor final class HcMobileCache {
    nonisolated struct Record: Codable, Identifiable {
        let address: String; let title: String; let state: String; let status: String?
        var id: String { address }
    }
    nonisolated struct Snapshot: Codable {
        let schema: Int; let coreID: String; let date: Date
        let documentData: Data?; let terminals: [Record]
        var document: CoreWorkspaceDocument? { documentData.flatMap { try? CoreWorkspaceDocument.decode($0) } }
    }
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Shepherd/HcDisplay", directoryHint: .isDirectory)
    }
    private func file(_ identity: Machine.ConnectionIdentity) throws -> URL {
        struct Scope: Encodable {
            let host: String; let port: Int; let user: String; let session: String
            let auth: Machine.AuthMethod; let key: String; let kind: Machine.AddressKind?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Scope(host: identity.hostname, port: identity.port, user: identity.username, session: identity.sessionName, auth: identity.authMethod, key: identity.keychainTag, kind: identity.addressKind))
        let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: identity.machineID.uuidString, directoryHint: .isDirectory).appending(path: key + ".json")
    }
    func load(machine: Machine, store: MachineStore) -> Snapshot? {
        guard store.isCurrentConnection(machine), let file = try? file(machine.connectionIdentity),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1 << 20,
              let data = try? Data(contentsOf: file), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schema == 1, snapshot.terminals.count <= 4096,
              snapshot.documentData == nil || snapshot.document != nil else { return nil }
        return snapshot
    }
    @discardableResult func save(model: HcWorkspaceModel, machine: Machine, store: MachineStore) -> Snapshot? {
        guard model.state == .connected, store.isCurrentConnection(machine), let coreID = model.coreID else { return nil }
        let snapshot = Snapshot(schema: 1, coreID: coreID, date: Date(), documentData: try? model.document?.encoded(),
            terminals: model.terminals.map { Record(address: $0.address, title: String(($0.name ?? $0.title).prefix(512)), state: $0.state, status: $0.reported ? $0.status?.state : nil) })
        return save(snapshot: snapshot, machine: machine, store: store)
    }
    @discardableResult func save(snapshot: Snapshot, machine: Machine, store: MachineStore) -> Snapshot? {
        guard snapshot.schema == 1, snapshot.terminals.count <= 4096,
              snapshot.documentData == nil || snapshot.document != nil, store.isCurrentConnection(machine) else { return nil }
        do {
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= 1 << 20 else { return nil }
            let file = try file(machine.connectionIdentity)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return snapshot
        } catch { return nil }
    }
    func retire(_ identity: Machine.ConnectionIdentity) -> Bool {
        do { let file = try file(identity); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }; return true }
        catch { return false }
    }
    func remove(_ id: UUID) -> Bool {
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        do { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }; return true }
        catch { return false }
    }
}
