import Foundation
import Citadel
import NIOConcurrencyHelpers

struct HostCredential {
    let authMethod: Machine.AuthMethod
    let secretData: Data
    nonisolated func authenticationMethod(username: String) throws -> OwnedAuth { .init() }
}
struct TOFUHostKeyValidator: OwnedValidator {
    let pinnedFingerprint: String?
    let observedFingerprint: NIOLockedValueBox<String?>
}
// Only the pane value used to create a request is a seam; real store/reader/
// model are compiled unchanged. Full-app builds use real AgentSummary.
struct AgentSummary {
    let paneID: String
    let terminalID: String
    let workingDirectory: String?
    let herdrMachine: String?
}
final class OwnedSecrets: MachineSecretStore {
    var values: [String: Data] = [:]
    var loads = 0
    func saveSecret(_ data: Data, tag: String) throws { values[tag] = data }
    func loadSecret(tag: String) throws -> Data? { loads += 1; return values[tag] }
    func deleteSecret(tag: String) throws { values[tag] = nil }
}

@main @MainActor enum ModelTests {
    static var checks = 0
    static func check(_ b: Bool) { precondition(b); checks += 1 }
    static func main() async throws {
        let directory = ProcessInfo.processInfo.arguments[1]
        let suite = "owned-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = OwnedSecrets()
        let local = Machine(displayName: "Owned Local", hostname: "localhost", username: "owned", isLocal: true)
        let store = MachineStore(defaults: defaults, localMachine: local, keychain: secrets)
        let pane = AgentSummary(paneID: "owned-pane", terminalID: "owned-terminal", workingDirectory: directory, herdrMachine: nil)
        let path = directory + "/model.md"
        try Data("# Local newest".utf8).write(to: URL(fileURLWithPath: path))
        let request = FilePreviewRequest(machine: local, pane: pane, link: "model.md")
        let model = FilePreviewModel()
        await model.load(request, store: store)
        if case .loaded = model.state { checks += 1 } else { preconditionFailure("local loaded") }
        check(secrets.loads == 0)
        check(model.link?.path == path)
        let next = request.following("next.md", directory: directory)
        check(next.id != request.id && next.paneID == request.paneID && next.machine.connectionIdentity == request.machine.connectionIdentity)
        let nested = AgentSummary(paneID: "owned-pane", terminalID: "owned-terminal", workingDirectory: directory, herdrMachine: "nested")
        await model.load(FilePreviewRequest(machine: local, pane: nested, link: "model.md"), store: store)
        if case .failed = model.state { checks += 1 } else { preconditionFailure("nested must not read local") }
        check(secrets.loads == 0)
        let remote = Machine(displayName: "Owned Remote", hostname: "owned.invalid", username: "owned", authMethod: .password)
        try store.addMachine(remote, password: "synthetic-only")
        let remoteRequest = FilePreviewRequest(machine: remote, pane: pane, link: "/remote/a.md")
        await model.load(remoteRequest, store: store)
        if case .failed = model.state { checks += 1 } else { preconditionFailure("unpinned") }
        check(secrets.loads == 0)
        store.pinHostKeyFingerprint("owned-pin", for: remote)
        await OwnedSFTP.shared.plan(Array("# Synthetic remote".utf8))
        await model.load(remoteRequest, store: store)
        if case .loaded = model.state { checks += 1 } else { preconditionFailure("refreshed pin should work") }
        let pins = await OwnedSFTP.shared.pins
        check(pins == ["owned-pin"])
        check(secrets.loads == 1)
        // A late completion must not replace a newer local preview or its path.
        await OwnedSFTP.shared.plan(Array("# Late".utf8), heldConnect: true)
        let old = Task { await model.load(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingConnect) { await Task.yield() }
        await model.load(request, store: store)
        await OwnedSFTP.shared.releaseConnect()
        await old.value
        if case .loaded(let doc) = model.state, case .text(let value, _) = doc.content {
            check(value == "# Local newest")
        } else { preconditionFailure("late result must not win") }
        check(model.link?.path == path)
        // Cancellation closes a pending read and doesn't publish a false error.
        await OwnedSFTP.shared.plan([65], heldRead: true)
        let pending = Task { await model.load(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingRead) { await Task.yield() }
        pending.cancel()
        await pending.value
        let closed = await OwnedSFTP.shared.closes
        check(closed >= 1)
        if case .loading = model.state { checks += 1 } else { preconditionFailure("cancelled result must not publish") }
        // The actual production 15-second timer closes a blocked SFTP read.
        await OwnedSFTP.shared.plan([65], heldRead: true)
        await model.load(remoteRequest, store: store)
        if case .failed(let error) = model.state { check(error == FilePreviewError.timedOut.localizedDescription) }
        else { preconditionFailure("timeout") }
        let timeoutClosed = await OwnedSFTP.shared.closes
        check(timeoutClosed >= 1)
        // Stale credential/endpoint records never reach the reader or Keychain.
        let oldLoads = secrets.loads
        var edited = remote; edited.hostname = "new-owned.invalid"
        try store.updateMachine(edited, replacing: remote)
        await OwnedSFTP.shared.plan()
        await model.load(remoteRequest, store: store)
        if case .failed = model.state { checks += 1 } else { preconditionFailure("stale connection") }
        check(secrets.loads == oldLoads)
        let staleConnects = await OwnedSFTP.shared.connects; check(staleConnects == 0)
        print("PASS \(checks) real preview model/store request, no-local-secret, refreshed-pin, stale-epoch, cancellation and 15s timeout checks; in-memory SSH/secret seams only")
    }
}
