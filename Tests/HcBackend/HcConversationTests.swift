import Foundation

@MainActor private final class Secrets: MachineSecretStore {
    var values: [String:Data] = [:]; var reads = 0
    func saveSecret(_ data: Data, tag: String) throws { values[tag] = data }
    func loadSecret(tag: String) throws -> Data? { reads += 1; return values[tag] }
    func deleteSecret(tag: String) throws { values[tag] = nil }
}
private nonisolated struct Status: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}
@main @MainActor private struct HcConversationTests {
    static var checks = 0
    static func check(_ b: Bool, _ label: String) throws { guard b else { throw NSError(domain: label, code: 1) }; checks += 1 }
    static func wait(_ label: String, until predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() { guard ContinuousClock.now < end else { throw NSError(domain: label, code: 1) }; try await Task.sleep(for: .milliseconds(10)) }
        checks += 1
    }
    static func output(_ model: HcConversationModel, contains text: String) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while model.output?.contains(text) != true {
            guard ContinuousClock.now < end else { throw NSError(domain: "owned peer output missing", code: 1) }
            try await model.refresh(); try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func main() async throws {
        let a = CommandLine.arguments
        let binary = URL(fileURLWithPath: a[1]), root = URL(fileURLWithPath: a[2]), report = URL(fileURLWithPath: a[3])
        let scope = try HcCoreBootstrap.Scope(root: root)
        let (controlTransport, control, hello) = try await HcCoreBootstrap.connect(binary: binary, scope: scope)
        var owned: [UInt32] = []
        var transports: [CoreProcessTransport] = [controlTransport]
        var failure: (any Error)?
        let domain = "hc-conversation-owned-" + UUID().uuidString, secrets = Secrets()
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let local = Machine(displayName: "Owned local", hostname: "localhost", port: 0, username: "owned", isLocal: true)
        let store = MachineStore(defaults: defaults, localMachine: local, keychain: secrets)
        func connect() async throws -> CoreRPCConnection {
            let t = try CoreProcessTransport(configuration: .init(executable: binary, environment: HcCoreBootstrap.environment(for: scope), directory: root))
            transports.append(t)
            return try await store.makeHcConnection(for: local, localTransport: t)
        }
        let board = HcTerminalBoard(connection: control)
        var running: Task<Void,Never>?
        var model: HcConversationModel?
        do {
            let status: Status = try await control.call("server.status").result(); owned = [status.pid]
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            let program = "import sys,time; print('HC-CONVERSATION-READY',flush=True)\nfor _ in range(3):\n s=input(); print('ECHO:'+s.encode().hex(),flush=True)\ntime.sleep(60)"
            let terminal = try await board.run(argv: ["/usr/bin/python3","-I","-S","-B","-c",program], cwd: root.path)
            let live: Status = try await control.call("server.status").result()
            owned += live.holders.map(\.pid) + [terminal.pid].compactMap { $0 }
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            let screen = HcConversationModel(machine: local, store: store, origin: hello.core.id, terminalID: terminal.address, connect: connect)
            model = screen
            let task = Task { await screen.run() }; running = task
            try await wait("snapshot connection", until: { screen.connected })
            try check(screen.record?.address == terminal.address && screen.record?.reported == false, "exact terminal, no fabricated agent readiness")
            screen.draft = "한글😀"
            await screen.send(textOnly: true)
            try check(screen.draft.isEmpty && !screen.busy, "type-only acknowledged, draft cleared once")
            await screen.send(keys: ["enter"])
            let hex = Data("한글😀".utf8).map { String(format:"%02x",$0) }.joined()
            try await output(screen, contains: "ECHO:" + hex)
            try check(screen.output?.contains("ECHO:" + hex) == true, "Unicode type-only plus explicit Enter reaches owned program")
            screen.draft = "second"
            await screen.send()
            try await output(screen, contains: "ECHO:7365636f6e64")
            try check(screen.output?.contains("ECHO:7365636f6e64") == true && screen.draft.isEmpty, "send plus Enter without replay")
            await screen.pause(); task.cancel(); await task.value
            try check(!screen.connected, "background pause retires input")
            screen.draft = "MUST-NOT-SEND"; await screen.send()
            let after = try await board.read(terminal.address, lines: 1000)
            try check(!after.text.contains(Data("MUST-NOT-SEND".utf8).map { String(format:"%02x",$0) }.joined()), "disconnected draft cannot dispatch")
            try check(try await board.get(terminal.address).state == "live", "snapshot disconnect preserves program")
            let wrongOrigin = HcConversationModel(machine: local, store: store, origin: "different-core", terminalID: terminal.address, connect: connect)
            await wrongOrigin.run()
            try check(!wrongOrigin.connected && wrongOrigin.record == nil, "cached foreign origin never retargeted")
            try await cache(root: root, store: store, secrets: secrets, origin: hello.core.id, terminal: terminal.address)
            try check(secrets.reads == 0, "local connections and display cache never read SSH credentials")
        } catch { failure = error }
        await model?.pause(); running?.cancel(); await running?.value
        _ = try await control.call("server.stop")
        try await control.close()
        for transport in transports { try await transport.close(); try check(await transport.snapshot().reaped, "all connect children reaped") }
        try JSONSerialization.data(withJSONObject: ["passed":failure == nil,"checks":checks,"ownedPIDs":owned,"failure":failure.map { String(describing:$0) } ?? "", "modelMessage":model?.message ?? ""]).write(to: report, options: .atomic)
        if let failure { throw failure }
        print("PASS hc conversation/cache: \(checks) checks")
    }
    static func cache(root: URL, store: MachineStore, secrets: Secrets, origin: String, terminal: String) async throws {
        let cache = HcMobileCache(directory: root.appending(path: "display-cache"))
        var machine = Machine(displayName: "Owned cache", hostname: "owned.invalid", username: "owned", authMethod: .password)
        try store.addMachine(machine, password: "synthetic-only")
        store.connectionWillInvalidate = { cache.retire($0) }; store.machineWillRemove = { cache.remove($0) }
        let document = try CoreWorkspaceDocument(workspaces: [.init(name: "Cached", tabs: [.init(name: "View", layout: .leaf(.init(terminal: .init(coreID: origin, terminalID: terminal))))])])
        let snapshot = HcMobileCache.Snapshot(schema: 1, coreID: origin, date: Date(), documentData: try document.encoded(), terminals: [.init(address: terminal, title: "Owned", state: "live", status: nil)])
        try check(cache.save(snapshot: snapshot, machine: machine, store: store) != nil, "bounded display cache saved")
        try check(cache.load(machine: machine, store: store)?.document == document, "strict document cache roundtrip")
        var renamed = machine; renamed.displayName = "Renamed"
        try store.updateMachine(renamed, replacing: machine)
        try check(cache.load(machine: renamed, store: store) != nil, "rename preserves connection-scoped display")
        var replacement = renamed; replacement.hostname = "changed.invalid"
        try store.updateMachine(replacement, replacing: renamed)
        try check(cache.save(snapshot: snapshot, machine: machine, store: store) == nil, "stale cache writer rejected after edit")
        machine = try store.currentMachine(matching: replacement)
        try check(cache.load(machine: machine, store: store) == nil, "new connection does not inherit old display")
        _ = cache.save(snapshot: snapshot, machine: machine, store: store)
        try check(store.removeMachine(machine), "machine removal retires display cache first")
        try store.addMachine(machine, password: "synthetic-only")
        try check(cache.load(machine: machine, store: store) == nil, "removed cache cannot resurrect with reused identity")
        let malformed = HcMobileCache.Snapshot(schema: 1, coreID: origin, date: Date(), documentData: Data("{}".utf8), terminals: [])
        try check(cache.save(snapshot: malformed, machine: machine, store: store) == nil, "invalid cached workspace rejected")
    }
}
