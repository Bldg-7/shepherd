import Foundation

private actor OwnedGate {
    private(set) var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func hold() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let all = waiters; waiters = []; for waiter in all { waiter.resume() } }
}
private actor StartObservation {
    private(set) var started = false
    func mark() { started = true }
}
private nonisolated final class ObservedConnect: CoreByteTransport {
    let base: CoreProcessTransport
    let startObservation = StartObservation()
    let closeGate: OwnedGate?
    let readGate: OwnedGate?
    let failClose: Bool
    private let docRequested = StartObservation()
    init(_ base: CoreProcessTransport, closeGate: OwnedGate? = nil, readGate: OwnedGate? = nil, failClose: Bool = false) {
        self.base = base; self.closeGate = closeGate; self.readGate = readGate; self.failClose = failClose
    }
    func start() async throws { await startObservation.mark(); try await base.start() }
    func read() async throws -> Data? {
        let data = try await base.read()
        if data != nil, let readGate, await docRequested.started { await readGate.hold() }
        return data
    }
    func write(_ bytes: Data) async throws {
        // Inspect only this fixture's own control request, never terminal data.
        if readGate != nil, bytes.range(of:Data("\"doc.get\"".utf8)) != nil { await docRequested.mark() }
        try await base.write(bytes)
    }
    func close() async throws {
        if let closeGate { await closeGate.hold() }
        try await base.close()
        if failClose { throw OwnerFailure.assertion("injected cleanup confirmation failure") }
    }
}
private final class NoSecrets: MachineSecretStore {
    func saveSecret(_ data: Data, tag: String) throws { preconditionFailure("no credential writes permitted") }
    func loadSecret(tag: String) throws -> Data? { preconditionFailure("no credential reads permitted") }
    func deleteSecret(tag: String) throws { preconditionFailure("no credential deletion permitted") }
}
private nonisolated struct OwnerStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let live: Int; let holders: [Holder]
}
private nonisolated struct OwnerStopped: Decodable, Sendable { let stopped: Bool }
private nonisolated enum OwnerFailure: Error { case assertion(String) }
@main @MainActor private struct HcMachineOwnerIntegrationTests {
    static var checks = 0
    static func check(_ value: Bool, _ text: String) throws { guard value else { throw OwnerFailure.assertion(text) }; checks += 1 }
    static func until(_ condition: @MainActor () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by:.seconds(5))
        while !(await condition()) { guard ContinuousClock.now < end else { throw OwnerFailure.assertion("owned readiness timeout") }; try await Task.sleep(for:.milliseconds(10)) }
    }
    static func main() async throws {
        let binary = URL(fileURLWithPath:CommandLine.arguments[1]), home = URL(fileURLWithPath:CommandLine.arguments[2])
        let report = URL(fileURLWithPath:CommandLine.arguments[3])
        let env = ["PATH":"/usr/bin:/bin","HOME":home.path,"XDG_STATE_HOME":home.appending(path:"state").path,
            "XDG_CONFIG_HOME":home.appending(path:"config").path,"XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
            "SSH_CONNECTION":"owned-fixture-no-launchd","HC_SESSION":"owned","HC_SOCKET":home.appending(path:"c.sock").path,"LANG":"en_US.UTF-8"]
        let config = CoreProcessTransport.Configuration(executable:binary,environment:env,directory:home)
        let controlTransport = try CoreProcessTransport(configuration:config)
        let control = try CoreRPCConnection(transport:controlTransport)
        let hello = try await control.connect()
        try check(hello.version == CommandLine.arguments[4],"official selected baseline")
        let initial: OwnerStatus = try await control.call("server.status").result()
        var pids: Set<UInt32> = [initial.pid]
        try JSONSerialization.data(withJSONObject:["corePID":initial.pid,"ownedPIDs":Array(pids)]).write(to:report,options:.atomic)
        let sleeper = try await HcTerminalBoard(connection:control).run(argv:["/bin/sleep","60"],cwd:home.path)
        if let pid = sleeper.pid { pids.insert(pid) }
        let running: OwnerStatus = try await control.call("server.status").result()
        pids.formUnion(running.holders.map(\.pid))
        func saveIdentities() throws {
            try JSONSerialization.data(withJSONObject:["corePID":initial.pid,"ownedPIDs":Array(pids).sorted()]).write(to:report,options:.atomic)
        }
        try saveIdentities()
        var failure: (any Error)?
        var observations: [[String:Bool]] = []
        for closeFirst in [true,false] {
            if failure != nil { break }
            let gate = OwnedGate()
            let first = ObservedConnect(try CoreProcessTransport(configuration:config),closeGate:gate)
            let replacement = ObservedConnect(try CoreProcessTransport(configuration:config))
            let superseded = ObservedConnect(try CoreProcessTransport(configuration:config))
            let suite = "owned-hc-owner-" + UUID().uuidString
            let defaults = UserDefaults(suiteName:suite)!
            let machine = Machine(displayName:"Owned local",hostname:"localhost",username:"owned",isLocal:true)
            let store = MachineStore(defaults:defaults,localMachine:machine,keychain:NoSecrets())
            let owner = HcMachineConnection(directory:home.appending(path:"owner-cache"))
            var retiring: Task<Void,Never>?, opening: Task<Void,Never>?
            do {
                await owner.open(machine:machine,store:store,localTransport:first)
                try check(owner.phase == .connected && owner.model != nil,"product owner connected via real private core")
                retiring = Task {
                    if closeFirst { await owner.close() }
                    else { await owner.open(machine:machine,store:store,localTransport:superseded) }
                }
                try await until { await gate.entered }
                opening = Task { await owner.open(machine:machine,store:store,localTransport:replacement) }
                // Deliberate cleanup gate, not terminal quiet-time/readiness inference.
                let window = ContinuousClock.now.advanced(by:.seconds(1))
                while !(await replacement.startObservation.started), ContinuousClock.now < window { try await Task.sleep(for:.milliseconds(10)) }
                let startedEarly = await replacement.startObservation.started
                if startedEarly { await opening?.value }
                await gate.release(); await retiring?.value; await opening?.value
                let phaseConsistent = owner.phase == .connected && owner.model != nil && owner.identity == machine.connectionIdentity
                observations.append(["closeFirst":closeFirst,"replacementStartedBeforeRetirement":startedEarly,"newOwnerConsistent":phaseConsistent])
                for transport in [first,replacement,superseded] {
                    if let pid = await transport.base.snapshot().childPID { pids.insert(UInt32(pid)) }
                }
                try saveIdentities()
                try check(!startedEarly,"replacement started before previous owned cleanup completed")
                try check(phaseConsistent,"late cleanup overwrote newer owner phase")
                let after = try await HcTerminalBoard(connection:control).get(sleeper.address)
                try check(after.pid == sleeper.pid && after.createdMs == sleeper.createdMs && after.state == "live","replacement preserves owned program incarnation")
                try check(!(await superseded.startObservation.started),"superseded pending open never dispatches a child")
            } catch { failure = error }
            await gate.release(); await retiring?.value; await opening?.value
            await owner.close()
            for transport in [first,replacement,superseded] {
                try await transport.base.close()
                let snapshot = await transport.base.snapshot()
                if let pid = snapshot.childPID { pids.insert(UInt32(pid)) }
                if snapshot.started { try check(snapshot.reaped,"all owned connect children reaped") }
            }
            defaults.removePersistentDomain(forName:suite)
        }
        // A connected RPC awaiting initial metadata is still an owned resource.
        // Replacement must close it, not just ignore its eventual UI result.
        if failure == nil {
            let readGate = OwnedGate(), closeGate = OwnedGate()
            let first = ObservedConnect(try CoreProcessTransport(configuration:config),closeGate:closeGate,readGate:readGate)
            let replacement = ObservedConnect(try CoreProcessTransport(configuration:config))
            let suite = "owned-hc-starting-" + UUID().uuidString
            let defaults = UserDefaults(suiteName:suite)!
            let machine = Machine(displayName:"Owned starting",hostname:"localhost",username:"owned",isLocal:true)
            let store = MachineStore(defaults:defaults,localMachine:machine,keychain:NoSecrets())
            let owner = HcMachineConnection(directory:home.appending(path:"starting-cache"))
            let opening = Task { await owner.open(machine:machine,store:store,localTransport:first) }
            var closing: Task<Void,Never>?, replacing: Task<Void,Never>?
            var closeWasCalled = false
            do {
                try await until { await readGate.entered }
                try check(owner.phase == .connecting && owner.model == nil,"initial metadata is not a published model")
                closing = Task { closeWasCalled = true; await owner.close() }
                try await until { closeWasCalled }
                replacing = Task { await owner.open(machine:machine,store:store,localTransport:replacement) }
                await readGate.release() // Let CLOSE acknowledgements through; do not manufacture a stream-close timeout.
                try await until { await closeGate.entered }
                try check(!(await replacement.startObservation.started),"initializing owner cleanup gates its replacement")
                await closeGate.release()
                await opening.value; await closing?.value; await replacing?.value
                try check(owner.phase == .connected && owner.model != nil,"late initial metadata cannot overwrite replacement: \(owner.phase), \(owner.message ?? "no message")")
                observations.append(["initializingModelRetired":true,"newOwnerConsistent":true])
            } catch { failure = error }
            await readGate.release(); await closeGate.release()
            await opening.value; await closing?.value; await replacing?.value
            await owner.close()
            for transport in [first,replacement] {
                try await transport.base.close()
                let snap = await transport.base.snapshot()
                if let pid = snap.childPID { pids.insert(UInt32(pid)) }
                if snap.started { try check(snap.reaped,"initializing/replacement clients reaped") }
            }
            try saveIdentities(); defaults.removePersistentDomain(forName:suite)
        }
        if failure == nil {
            let first = ObservedConnect(try CoreProcessTransport(configuration:config),failClose:true)
            let replacement = ObservedConnect(try CoreProcessTransport(configuration:config))
            let suite = "owned-hc-cleanup-failure-" + UUID().uuidString
            let defaults = UserDefaults(suiteName:suite)!
            let machine = Machine(displayName:"Owned cleanup",hostname:"localhost",username:"owned",isLocal:true)
            let store = MachineStore(defaults:defaults,localMachine:machine,keychain:NoSecrets())
            let owner = HcMachineConnection(directory:home.appending(path:"failed-cache"))
            do {
                await owner.open(machine:machine,store:store,localTransport:first)
                try check(owner.phase == .connected,"cleanup failure fixture initially connected")
                await owner.close()
                try check(owner.phase == .failed && owner.model == nil,"cleanup uncertainty is not idle/success")
                await owner.open(machine:machine,store:store,localTransport:replacement)
                let replacementStarted = await replacement.startObservation.started
                try check(owner.phase == .failed && !replacementStarted,"failed cleanup tail blocks later child dispatch")
                observations.append(["cleanupFailureBlocksReplacement":true])
            } catch { failure = error }
            await owner.close()
            for transport in [first,replacement] {
                try await transport.base.close()
                let snap = await transport.base.snapshot()
                if let pid = snap.childPID { pids.insert(UInt32(pid)) }
                if snap.started { try check(snap.reaped,"failed-confirmation fixture client actually reaped") }
            }
            try saveIdentities(); defaults.removePersistentDomain(forName:suite)
        }
        let finalStatus: OwnerStatus = try await control.call("server.status").result()
        pids.formUnion(finalStatus.holders.map(\.pid))
        let stopped: OwnerStopped = try await control.call("server.stop").result()
        try await control.close()
        let controlSnapshot = await controlTransport.snapshot()
        if let pid = controlSnapshot.childPID { pids.insert(UInt32(pid)) }
        var result: [String:Any] = ["passed":failure == nil,"checks":checks,"corePID":initial.pid,"ownedPIDs":Array(pids).sorted(),
            "connectChildrenReaped":controlSnapshot.reaped,"stopAcknowledged":stopped.stopped,"scenarios":observations,
            "nativeGUIQualified":false,"launchdLifecycleQualified":false]
        if let failure { result["failure"] = String(describing:failure) }
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:report,options:.atomic)
        if let failure { throw failure }
        print("PASS product hc owner: \(checks) checks; actual core, gated transport cleanup; no GUI/service qualification")
    }
}
