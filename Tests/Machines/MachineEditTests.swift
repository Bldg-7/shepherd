import Foundation

@MainActor final class MemorySecrets: MachineSecretStore {
    enum Failure: Error { case denied }
    var values: [String: Data] = [:]
    var events: [String] = []
    var failSave = false
    var failRead = false
    func saveSecret(_ data: Data, tag: String) throws {
        events.append("save")
        if failSave { throw Failure.denied }
        values[tag] = data
    }
    func loadSecret(tag: String) throws -> Data? {
        events.append("read")
        if failRead { throw Failure.denied }
        return values[tag]
    }
    func deleteSecret(tag: String) throws {
        events.append("delete")
        values.removeValue(forKey: tag)
    }
}

// Test-only transport constructors: no network, SSH accounts or actual Keychain.
protocol HerdrTransport {}
struct LocalHerdrTransport: HerdrTransport {
    init() {}
    init(socketPath: String) {}
}
struct StubHerdrTransport: HerdrTransport {}
struct HostCredential { let authMethod: Machine.AuthMethod; let secretData: Data }
struct SSHHerdrTransport: HerdrTransport {
    let host: String
    let port: Int
    let username: String
    let credential: HostCredential
    let sessionName: String
    let pinnedFingerprint: String?
}

@main @MainActor enum MachineEditTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        precondition(condition(), name); checks += 1
    }
    static func rejects(_ name: String, _ work: () throws -> Void) {
        do { try work(); preconditionFailure(name) } catch { checks += 1 }
    }
    static func main() throws {
        let domain = "shepherd.machine-edit.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let secrets = MemorySecrets()
        let store = MachineStore(defaults: defaults, keychain: secrets)
        var first = Machine(displayName: "Owned", hostname: "owned.invalid", username: "tester", authMethod: .password)
        first.pinnedHostKeyFingerprint = "SHA256:owned-a"
        let second = Machine(displayName: "Other", hostname: "other.invalid", username: "other")
        let originalSecret = Data("synthetic-original-password".utf8)
        try store.addMachine(first, password: String(decoding: originalSecret, as: UTF8.self))
        try store.addMachine(second, privateKey: Data("synthetic-other-key".utf8))
        store.activeMachineID = first.id
        secrets.events = []
        var draft = first
        draft.displayName = " Renamed "
        draft.keychainTag = second.keychainTag // ignored: UI cannot redirect credentials
        draft.pinnedHostKeyFingerprint = "SHA256:untrusted" // also ignored
        try store.updateMachine(draft, replacing: first)
        var current = store.machines[0]
        check(current.displayName == "Renamed", "metadata trimmed")
        check(current.id == first.id && store.activeMachineID == first.id, "ID and active choice preserved")
        check(store.machines.map(\.id) == [first.id, second.id], "row order preserved")
        check(current.keychainTag == first.keychainTag && current.pinnedHostKeyFingerprint == first.pinnedHostKeyFingerprint, "caller cannot change credential tag or pin")
        check(current.connectionIdentity == first.connectionIdentity, "rename does not reconnect")
        check(secrets.events.isEmpty, "metadata-only edit never reads or writes Keychain")
        rejects("stale edit cannot overwrite another window") { try store.updateMachine(first, replacing: first) }

        let beforeHost = current
        draft = current; draft.hostname = " new.invalid "
        try store.updateMachine(draft, replacing: current); current = store.machines[0]
        check(current.hostname == "new.invalid" && current.pinnedHostKeyFingerprint == nil, "new host resets pin")
        check(current.connectionIdentity != beforeHost.connectionIdentity, "host change retires old identity")
        check(!store.isCurrentConnection(beforeHost), "old connection no longer current")
        store.pinHostKeyFingerprint("SHA256:stale", for: beforeHost)
        check(store.machines[0].pinnedHostKeyFingerprint == nil, "late old-host pin denied")
        rejects("stale secret read denied") { _ = try store.secret(for: beforeHost) }
        rejects("stale transport denied before resolving credentials") { _ = try store.makeHerdrTransport(for: beforeHost) }
        check(secrets.events.isEmpty, "stale calls do not access Keychain")
        let beforePin = current
        store.pinHostKeyFingerprint("SHA256:owned-b", for: current)
        current = store.machines[0]
        check(current.connectionIdentity == beforePin.connectionIdentity, "TOFU pin does not reconnect")
        store.pinHostKeyFingerprint("SHA256:overwrite", for: current)
        check(store.machines[0].pinnedHostKeyFingerprint == "SHA256:owned-b", "existing host pin cannot be overwritten")
        let refreshed = try store.currentMachine(matching: beforePin)
        check(refreshed.pinnedHostKeyFingerprint == "SHA256:owned-b", "current pin refreshed for old view value")
        let transport = try store.makeHerdrTransport(for: beforePin) as! SSHHerdrTransport
        check(transport.pinnedFingerprint == "SHA256:owned-b", "transport uses freshly stored pin")
        check(transport.host == current.hostname && transport.credential.secretData == originalSecret, "transport uses expected endpoint and saved credential")

        for field in ["username", "session", "port"] {
            let old = current; draft = current
            if field == "username" { draft.username = " changed-user " }
            if field == "session" { draft.sessionName = " new-session " }
            if field == "port" { draft.port = 2222 }
            try store.updateMachine(draft, replacing: current); current = store.machines[0]
            check(current.connectionIdentity != old.connectionIdentity, field + " reconnect identity")
            check(current.pinnedHostKeyFingerprint == (field == "port" ? nil : "SHA256:owned-b"), field + " pin policy")
        }
        draft = current; draft.sessionName = " default "
        try store.updateMachine(draft, replacing: current); current = store.machines[0]
        check(current.sessionName.isEmpty, "default session normalized")
        let beforeInvalid = current; let saved = defaults.data(forKey: "herdr-client.machines")
        secrets.events = []
        for kind in 0..<7 {
            draft = current
            switch kind {
            case 0: draft.displayName = " \n"
            case 1: draft.hostname = ""
            case 2: draft.username = " "
            case 3: draft.port = 0
            case 4: draft.port = 65536
            case 5: draft.sessionName = "../other"
            default: draft.sessionName = "bad;session"
            }
            rejects("invalid metadata rejected") { try store.updateMachine(draft, replacing: current) }
        }
        check(store.machines[0] == beforeInvalid && defaults.data(forKey: "herdr-client.machines") == saved && secrets.events.isEmpty, "validation failures have no persistence or credential side effects")
        draft = current; draft.authMethod = .key
        rejects("auth change requires a new credential") { try store.updateMachine(draft, replacing: current) }
        rejects("empty replacement denied") { try store.updateMachine(current, replacing: current, replacementSecret: Data()) }
        secrets.failSave = true
        rejects("failed new credential save") { try store.updateMachine(draft, replacing: current, replacementSecret: Data("synthetic-new-key".utf8)) }
        check(store.machines[0] == beforeInvalid && secrets.values[current.keychainTag] == originalSecret, "failed save preserves existing machine and only copy of credential")
        check(secrets.events == ["save"], "failed save never deletes the old key")
        secrets.failSave = false; secrets.events = []
        let beforeCredential = current
        try store.updateMachine(draft, replacing: current, replacementSecret: Data("synthetic-new-key".utf8)); current = store.machines[0]
        check(current.authMethod == .key && current.id == beforeCredential.id, "authentication changed in place")
        check(current.keychainTag != beforeCredential.keychainTag && current.connectionIdentity != beforeCredential.connectionIdentity, "credential change creates a new connection identity")
        check(secrets.events == ["save", "delete"] && secrets.values[beforeCredential.keychainTag] == nil, "save precedes old-credential cleanup")
        check(secrets.values[current.keychainTag] == Data("synthetic-new-key".utf8), "new credential retained")
        let encoded = String(decoding: defaults.data(forKey: "herdr-client.machines")!, as: UTF8.self)
        check(!encoded.contains("synthetic-new-key") && !encoded.contains("synthetic-original-password"), "secrets never enter defaults JSON")
        secrets.events = []
        let reloaded = MachineStore(defaults: defaults, keychain: secrets)
        check(reloaded.machines[0] == current && reloaded.activeMachineID == current.id, "saved metadata reloads")
        check(secrets.events.isEmpty, "loading the list does not load credentials")
        let beforeSameMethod = current
        try store.updateMachine(current, replacing: current, replacementSecret: Data("synthetic-another-key".utf8)); current = store.machines[0]
        check(current.authMethod == beforeSameMethod.authMethod && current.connectionIdentity != beforeSameMethod.connectionIdentity, "same-method key replacement also reconnects")
        secrets.failRead = true
        rejects("Keychain read failure is not a stub transport") { _ = try store.makeHerdrTransport(for: current) }
        secrets.failRead = false
        let kept = secrets.values.removeValue(forKey: current.keychainTag)
        rejects("missing credential is not a stub transport") { _ = try store.makeHerdrTransport(for: current) }
        secrets.values[current.keychainTag] = kept

        var local = current; local.isLocal = true
        rejects("local identity edit denied") { try store.updateMachine(local, replacing: current) }
        rejects("builtin local machine denied") { try store.updateMachine(MachineStore.localMachine, replacing: MachineStore.localMachine) }
        var wrongID = current; wrongID.id = UUID()
        rejects("identity replacement denied") { try store.updateMachine(wrongID, replacing: current) }
        let tag = current.keychainTag
        store.removeMachine(beforeCredential)
        check(!store.machines.contains(where: { $0.id == current.id }) && secrets.values[tag] == nil, "stale removal confirmation deletes current credential")
        check(store.machines.map(\.id) == [second.id] && secrets.values[second.keychainTag] != nil, "other machines and credentials retained")
        rejects("removed machine cannot be resurrected by old editor") { try store.updateMachine(current, replacing: current) }
        print("PASS \(checks) machine edit checks; synthetic credentials only, no real Keychain/network")
    }
}
