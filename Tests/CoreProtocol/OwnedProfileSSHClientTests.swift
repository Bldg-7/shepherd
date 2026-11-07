import Foundation
import ShepherdKit

private nonisolated struct PrivateProfile: Decodable { let machine: Machine; let password: String; let expectedCoreID: String }
private nonisolated struct PublicProfile: Decodable { let fingerprint: String; let terminal: String }
@MainActor private final class ProfileSecrets: MachineSecretStore {
    var data: [String:Data] = [:]; var reads = 0
    func saveSecret(_ secret: Data, tag: String) throws { data[tag] = secret }
    func loadSecret(tag: String) throws -> Data? { reads += 1; return data[tag] }
    func deleteSecret(tag: String) throws { data[tag] = nil }
}
@main @MainActor private struct OwnedProfileSSHClientTests {
    static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let secretFile = root.appending(path:"remote-profile-secret.json")
        let attributes = try FileManager.default.attributesOfItem(atPath:secretFile.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 65536 else { throw CoreConnectionFailure.notReady }
        let profile = try JSONDecoder().decode(PrivateProfile.self,from:Data(contentsOf:secretFile))
        try FileManager.default.removeItem(at:secretFile)
        let ready = try JSONDecoder().decode(PublicProfile.self,from:Data(contentsOf:root.appending(path:"remote-ready.json")))
        let domain = "owned-profile-client-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!; defer { defaults.removePersistentDomain(forName:domain) }
        let secrets = ProfileSecrets(), store = MachineStore(defaults:defaults,keychain:secrets)
        try store.addMachine(profile.machine,password:profile.password)
        let owner = HcMachineConnection(directory:root.appending(path:"client-owned-cache"))
        await owner.open(machine:profile.machine,store:store)
        guard owner.phase == .approveHostKey(ready.fingerprint), secrets.reads == 0, owner.model == nil else { throw CoreConnectionFailure.notReady }
        await owner.approve(machine:profile.machine,store:store)
        guard owner.phase == .connected, owner.model?.coreID == profile.expectedCoreID, secrets.reads == 1 else { throw CoreConnectionFailure.notReady }
        let connection = try await store.makeHcConnection(for:profile.machine)
        let terminal = try await HcTerminalBoard(connection:connection).get(ready.terminal)
        guard terminal.state == "live", CoreTerminalID.isCanonical(terminal.address) else { throw CoreConnectionFailure.notReady }
        var rendered = false
        for _ in 0..<100 {
            let read = try await HcTerminalBoard(connection:connection).read(ready.terminal)
            if read.text.contains("HC-REMOTE-ORIGIN-B") { rendered = true; break }
            try await Task.sleep(for:.milliseconds(20))
        }
        guard rendered else { throw CoreConnectionFailure.requestTimedOut }
        try await connection.close(); await owner.close()
        guard owner.phase == .idle, owner.model == nil else { throw CoreConnectionFailure.notReady }
        try JSONSerialization.data(withJSONObject:["passed":true,"actualProductOwner":true,"explicitHostKeyApproval":true,
            "realPrivateOrigin":true,"credentialFileRemoved":!FileManager.default.fileExists(atPath:secretFile.path),
            "credentialLogged":false,"guiQualified":false]).write(to:root.appending(path:"client-report.json"),options:.atomic)
        print("PASS owned profile SSH sidecar client; no user account/GUI/provider")
    }
}
