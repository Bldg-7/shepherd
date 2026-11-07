#if DEBUG && os(macOS)
import Foundation
import Darwin
import ShepherdKit

/// Private UI fixture credentials only. Never delegates to the user's Keychain.
@MainActor final class HcFixtureSecrets: MachineSecretStore {
    private var data: [String:Data] = [:]
    private(set) var reads = 0
    func saveSecret(_ secret: Data, tag: String) throws { data[tag] = secret }
    func loadSecret(tag: String) throws -> Data? { reads += 1; return data[tag] }
    func deleteSecret(tag: String) throws { data[tag] = nil }
}
@MainActor struct HcFixtureRemoteProfile {
    private nonisolated struct Credentials: Decodable { let machine: Machine; let password: String; let expectedCoreID: String }
    private nonisolated struct Ready: Decodable { let port: Int; let fingerprint: String; let coreID: String; let machineID: String; let terminal: String }
    let machine: Machine
    let coreID: String
    let fingerprint: String
    let terminal: String
    static func load(root: URL, store: MachineStore) throws -> Self {
        let folder = root.appending(path:"remote-sidecar")
        let file = folder.appending(path:"remote-profile-secret.json")
        let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 65536 else { throw CoreConnectionFailure.notReady }
        let input = try JSONDecoder().decode(Credentials.self,from:Data(contentsOf:file))
        defer { try? FileManager.default.removeItem(at:file) }
        let ready = try JSONDecoder().decode(Ready.self,from:Data(contentsOf:folder.appending(path:"remote-ready.json")))
        guard input.machine.id.uuidString == ready.machineID,
              input.machine.hostname == "127.0.0.1", input.machine.username == "fixture",
              input.machine.port == ready.port, (1...65535).contains(ready.port),
              !input.machine.isLocal, input.machine.sessionName == "owned", input.machine.addressKind == nil,
              input.machine.pinnedHostKeyFingerprint == nil, input.expectedCoreID == ready.coreID,
              CoreTerminalID.isCanonical(ready.terminal), !input.password.isEmpty else { throw CoreConnectionFailure.notReady }
        try FileManager.default.removeItem(at:file)
        try store.addMachine(input.machine,password:input.password)
        return .init(machine:input.machine,coreID:ready.coreID,fingerprint:ready.fingerprint,terminal:ready.terminal)
    }
}
#endif
