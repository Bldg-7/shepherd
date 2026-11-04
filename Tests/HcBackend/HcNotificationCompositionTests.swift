import Foundation
import ShepherdKit

@MainActor private final class NativeNotifications: HcNotificationsPresenting {
    var presented: [String:HcNotificationRoute] = [:]
    var presentations = 0, requests = 0, badges: [Int] = []
    func becomeHcDelegate(onOpen: @escaping (HcNotificationRoute) -> Void) {}
    func authorization() async -> NotificationAuthorization { .allowed }
    func badgesAreOff() async -> Bool { false }
    func requestAuthorization() async -> NotificationAuthorization { requests += 1; return .allowed }
    func presentHc(identifier: String, content: NotificationText.Content, route: HcNotificationRoute) async -> Bool {
        presentations += 1; presented[identifier] = route; return true
    }
    func retract(identifiers: [String]) { for id in identifiers { presented[id] = nil } }
    func retractHc(machineIDs: Set<UUID>, before: Date?) async { guard before == nil else { return }; presented = presented.filter { !machineIDs.contains($0.value.machineID) } }
    func setBadge(_ count: Int) { badges.append(count) }
    func clearBadgeBeforeQuitting() { badges.append(0) }
}
@MainActor private final class Secrets: MachineSecretStore {
    var reads = 0
    func saveSecret(_ data: Data, tag: String) throws {}
    func loadSecret(tag: String) throws -> Data? { reads += 1; return nil }
    func deleteSecret(tag: String) throws {}
}
private nonisolated struct Status: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}
@main @MainActor private struct HcNotificationCompositionTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain: label, code: 1) }; checks += 1 }
    static func wait(_ label: String, until predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(6))
        while try await !predicate() { guard ContinuousClock.now < end else { throw NSError(domain: label, code: 1) }; try await Task.sleep(for: .milliseconds(10)) }
        checks += 1
    }
    static func main() async throws {
        let a = CommandLine.arguments
        let binary = URL(fileURLWithPath: a[1]), root = URL(fileURLWithPath: a[2]), report = URL(fileURLWithPath: a[3])
        let scope = try HcCoreBootstrap.Scope(root: root)
        let (transport, rpc, hello) = try await HcCoreBootstrap.connect(binary: binary, scope: scope)
        let board = HcTerminalBoard(connection: rpc)
        let domain = "hc-notification-owned-" + UUID().uuidString, defaults = UserDefaults(suiteName: domain)!, secrets = Secrets()
        defer { defaults.removePersistentDomain(forName: domain) }
        let machine = Machine(displayName: "Owned status fixture", hostname: "localhost", port: 0, username: "owned", isLocal: true)
        let store = MachineStore(defaults: defaults, localMachine: machine, keychain: secrets)
        let native = NativeNotifications(), preferences = NotificationPreferences(defaults: defaults)
        var transports: [CoreProcessTransport] = [], owned: [UInt32] = [], failure: (any Error)?
        let coordinator = HcNotificationCoordinator(preferences: preferences, presenter: native, available: true, connect: { store, machine in
            let t = try CoreProcessTransport(configuration: .init(executable: binary, environment: HcCoreBootstrap.environment(for: scope), directory: root))
            transports.append(t)
            return try await store.makeHcConnection(for: machine, localTransport: t)
        })
        coordinator.machineStore = store
        do {
            let status: Status = try await rpc.call("server.status").result(); owned = [status.pid]
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            let ownerTransport = try CoreProcessTransport(configuration: .init(executable: binary, environment: HcCoreBootstrap.environment(for: scope), directory: root))
            transports.append(ownerTransport)
            let owner = HcMachineConnection(directory: root.appending(path: "owned-workspace-state"))
            await owner.open(machine: machine, store: store, localTransport: ownerTransport)
            try check(owner.phase == .connected && owner.identity == machine.connectionIdentity, "owner publishes the exact connected machine scope")
            let another = Machine(displayName: "Not connected", hostname: "not-connected.invalid", username: "owned", authMethod: .password)
            try store.addMachine(another, password: "synthetic-only"); store.activeMachineID = another.id
            try check(owner.identity != store.activeMachine?.connectionIdentity, "selection change cannot present old model as a new host")
            await owner.close()
            try check(owner.identity == nil && owner.model == nil, "close retires scope before reconnect")
            let history = CaptureHistorySource(machine: another, store: store)
            guard let firstHistory = await history.prepare(), let nextHistory = await history.prepare() else { throw NSError(domain: "history prepare", code: 1) }
            do { _ = try await firstHistory.openLineStream(endpoint: .conversations, request: Data("{}\n".utf8)); throw NSError(domain: "retired history read", code: 1) }
            catch ConversationLineConnection.Failure.closed { checks += 1 }
            await history.close(firstHistory)
            try check(history.transport === nextHistory, "late history cleanup cannot close a newer refresh")
            try check(secrets.reads == 0, "preparing read-only history never authenticates or launches a service")
            store.activeMachineID = machine.id; _ = store.removeMachine(another)
            try check(!history.isCurrent, "removed profile invalidates history immediately")
            try check(await history.prepare() == nil, "stale profile cannot prepare a new history connection")
            await history.close()
            let unapprovedHistory = Machine(displayName: "Owned capture negative", hostname: "127.0.0.1", port: 22,
                username: "owned", authMethod: .secureEnclaveKey, addressKind: .privateIPv4)
            try store.addMachine(unapprovedHistory, password: "synthetic-memory-only")
            do { _ = try await store.makeConversationByteTransport(for: unapprovedHistory, endpoint: .conversations); throw NSError(domain: "unapproved capture access", code: 1) }
            catch HerdrLineStreamError.unsupported { checks += 1 }
            try check(secrets.reads == 0, "unapproved capture host cannot read credentials")
            store.pinHostKeyFingerprint("SHA256:owned-fixture-not-a-real-key", for: unapprovedHistory)
            do { _ = try await store.makeConversationByteTransport(for: unapprovedHistory, endpoint: .conversations); throw NSError(domain: "paired capture loopback", code: 1) }
            catch PairingAddressError.invalid { checks += 1 }
            try check(secrets.reads == 0, "paired capture range rejection precedes credential access")
            _ = store.removeMachine(unapprovedHistory)
            let program = "import sys\ndef state(s): print('\\033]7501;state='+s+':app=owned-coordinator\\007',flush=True)\nstate('blocked')\nfor line in sys.stdin:\n s={'w':'working','b':'blocked'}.get(line.strip())\n if s: state(s)"
            let terminal = try await board.run(argv: ["/usr/bin/python3","-I","-S","-B","-c",program], cwd: root.path)
            let live: Status = try await rpc.call("server.status").result()
            owned += live.holders.map(\.pid) + [terminal.pid].compactMap { $0 }
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            try await wait("initial status", until: { try await board.get(terminal.address).status?.state == "blocked" })
            coordinator.prepare(); coordinator.start()
            try await wait("initial badge", until: { native.badges.last == 1 })
            try check(native.presentations == 0, "baseline status is not an old-event banner")
            await coordinator.setViewed(machine: machine, coreID: hello.core.id, terminalIDs: [terminal.address])
            try check(native.badges.last == 0, "actual viewed pane clears app badge")
            await coordinator.setViewed(machine: nil, coreID: nil)
            func key(_ key: String) async throws {
                _ = try await rpc.call("terminal.keys", parameters: JSONSerialization.data(withJSONObject: ["terminal":terminal.address,"keys":[key,"enter"]]))
            }
            try await key("w"); try await wait("working badge", until: { native.badges.last == 0 })
            try await key("b"); try await wait("new banner", until: { native.presentations == 1 })
            try check(native.presented.values.first == HcNotificationRoute(machineID: machine.id, coreID: hello.core.id, terminalID: terminal.address), "native route is exact machine/core/terminal data, not an alias")
            preferences.notifiesNeedsInput = false
            try await wait("disabled kind retracted", until: { native.presented.isEmpty })
            try await key("w"); try await wait("second working badge", until: { native.badges.last == 0 })
            try await key("b"); try await wait("second blocked badge", until: { native.badges.last == 1 })
            try await Task.sleep(for: .seconds(2))
            try check(native.presentations == 1 && native.requests == 0, "disabled kind does not present; no native permission calls in fixture")
            preferences.setMuted(true, machine.id)
            try await wait("muted badge", until: { native.badges.last == 0 })
            await coordinator.stop()
            for t in transports { try check(await t.snapshot().reaped, "watcher connect child reaped after mute/stop") }
            try check(try await board.get(terminal.address).state == "live" && secrets.reads == 0, "notification lifecycle never kills program or reads SSH credentials for local core")
        } catch { failure = error }
        await coordinator.stop()
        _ = try await rpc.call("server.stop"); try await rpc.close()
        try check(await transport.snapshot().reaped, "control child reaped")
        try JSONSerialization.data(withJSONObject: ["passed":failure == nil,"checks":checks,"ownedPIDs":owned,"failure":failure.map { String(describing:$0) } ?? "", "osNotificationsUsed":false]).write(to: report, options: .atomic)
        if let failure { throw failure }
        print("PASS hc notification app composition: \(checks) checks, fake OS boundary only")
    }
}
