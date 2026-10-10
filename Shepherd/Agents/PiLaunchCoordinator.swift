#if os(macOS)
import Foundation

/// A separate Herdr connection observes startup while agent.start waits for TUI
/// readiness. The session-only shim waits for this binding before importing Pi.
@MainActor final class PiLaunchCoordinator {
    private final class Admission {
        let owner: AgentPaneIdentity
        var process: PaneProcessInfo?
        var received: ContinuousClock.Instant?
        var active = true
        var nativeAuthorized: (() -> Bool)?
        var reportSequence = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        init(owner: AgentPaneIdentity) { self.owner = owner }
        func permits(_ launch: PiBridgeLaunch, _ proof: PiProcessIdentity) -> Bool {
            active && launch.owner == owner && process?.paneID == owner.paneID &&
                received.map { $0.duration(to: ContinuousClock().now) < .seconds(3) } == true &&
                process?.foregroundProcesses.contains(where: { $0.pid == UInt32(proof.pid) }) == true
        }
    }
    let stage: PiStagedLaunch
    private let owner: AgentPaneIdentity
    private let machine: Machine
    private let client: HerdrClient
    private let admission: Admission
    private let provider: PiBrowserLeaseProvider
    private let host: PiHostBridge
    private let listener = PiBridgeListener()
    private let launch: PiBridgeLaunch
    private let socketDirectory: URL
    private var monitor: Task<Void, Never>?
    private(set) var failure: String?
    private(set) var stopped = false
    #if DEBUG
    private var bindingSamples: [[String: Any]] = []
    var fixtureDiagnostics: [String: Any] { ["requests":host.requestCount,"nativeFailure":host.lastFailure?.rawValue ?? "none","failure":failure ?? "none","samples":bindingSamples] }
    #endif
    var isReady: Bool { !stopped && failure == nil && host.isMcpReady(launchID: stage.id) }
    var hasWork: Bool { !stopped || host.hasWork }

    init(stage: PiStagedLaunch, owner: AgentPaneIdentity, machine: Machine, client: HerdrClient,
         cwd: String, preferences: AgentRuntimePreferences, proxy: CDPProxy = .shared) throws {
        guard machine.isLocal, owner.herdrMachineID == nil, owner.machineID == machine.id.uuidString,
              owner.session == BrowserKey.session(named: machine.sessionName), !preferences.disableCompetingBrowsers else { throw PiBridgeFailure.denied }
        self.stage = stage; self.owner = owner; self.machine = machine; self.client = client
        admission = Admission(owner: owner)
        let admissionState = admission
        let claim = try proxy.claimRoute(for: BrowserKey(machineID: machine.id, herdrMachineID: nil, session: owner.session, paneID: owner.paneID), terminalID: owner.terminalID,
            authorize: { [weak admissionState] in admissionState?.nativeAuthorized?() == true })
        provider = PiBrowserLeaseProvider(proxy: proxy, claim: claim, directory: URL(fileURLWithPath: stage.folder), preferences: preferences)
        let admission = admission, provider = provider
        host = PiHostBridge(admit: { admission.permits($0, $1) }, acquire: { try provider.acquire(launch: $0, identity: $1, attempt: $2) },
            reportState: { launch, identity, state in
                admission.reportSequence = max(admission.reportSequence + 2, UInt64(Date().timeIntervalSince1970 * 1_000_000))
                try await client.reportPiState(paneID: launch.owner.paneID, sessionFile: identity.sessionFile, state: state, sequence: admission.reportSequence)
            })
        let bridge = host, launchID = stage.id
        admission.nativeAuthorized = { [weak bridge] in bridge?.isMcpReady(launchID: launchID) == true }
        launch = PiBridgeLaunch(id: stage.id, owner: owner, node: stage.node, entry: stage.entry,
            arguments: [stage.manifest] + stage.arguments, cwd: PiProcessIdentity.canonical(cwd), sessionID: stage.sessionID,
            sessionDirectory: stage.folder + "/sessions", helper: stage.resources + "/pi-control.mjs", wrapper: stage.resources + "/pi-mcp-run.mjs",
            bootstrap: stage.bootstrap, permitsPiTitleRewrite: true)
        socketDirectory = URL(fileURLWithPath: "/private/tmp/shp-pi-" + UUID().uuidString.lowercased())
    }

    func prepare() async throws {
        do {
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let socket = socketDirectory.appendingPathComponent("c.sock").path
            try await listener.start(path: socket, host: host)
            try host.provision(launch, socketPath: socket)
            try PiBrowserLeaseProvider.write(["version":1,"cli":stage.cli,"bootstrap":stage.bootstrap,"cwd":launch.cwd,"arguments":stage.arguments],
                                             to: URL(fileURLWithPath: stage.manifest))
            try await client.connect()
            monitor = Task { await observe() }
        } catch { await stop(); throw error }
    }
    func waitUntilReady() async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(20))
        while !isReady {
            guard !stopped, failure == nil, ContinuousClock().now < deadline else { throw AgentRuntimeError.rejected(failure ?? "pi-mcp-readiness-unconfirmed") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func observe() async {
        var bound: Int32?
        let deadline = ContinuousClock().now.advanced(by: .seconds(20))
        do {
            while !Task.isCancelled {
                let snapshot = try await client.launchSnapshot()
                guard snapshot.panes.contains(where: { $0.paneID == owner.paneID && $0.terminalID == owner.terminalID }) else { throw PiBridgeFailure.identity }
                MachineBrowserService.shared.accept(snapshot.panes, on: machine)
                let process = try await client.processInfo(paneID: owner.paneID)
                admission.process = process; admission.received = ContinuousClock().now
                if let bound {
                    guard process.foregroundProcesses.contains(where: { $0.pid == UInt32(bound) }) else { throw PiBridgeFailure.identity }
                } else {
                    #if DEBUG
                    if bindingSamples.count < 40 {
                        bindingSamples.append(["foreground":process.foregroundProcesses.map { item -> [String: Any] in
                            guard item.pid <= UInt32(Int32.max), let p = try? PiProcessIdentity.capture(pid: Int32(item.pid)) else { return ["pid":item.pid,"captured":false] }
                            return ["pid":item.pid,"captured":true,"node":p.executable == launch.node,"cwd":p.cwd == launch.cwd,
                                    "argc":p.arguments.count,"expectedArgc":launch.arguments.count + 2,
                                    "entry":p.arguments.dropFirst().first == launch.entry,"tail":Array(p.arguments.dropFirst(2)) == launch.arguments]
                        }])
                    }
                    #endif
                    let candidates = process.foregroundProcesses.compactMap { item -> PiProcessIdentity? in
                        guard item.pid <= UInt32(Int32.max), let proof = try? PiProcessIdentity.capture(pid: Int32(item.pid)),
                              proof.matches(node: launch.node, entry: launch.entry, tail: launch.arguments, cwd: launch.cwd) else { return nil }
                        return proof
                    }
                    if candidates.count == 1 {
                        try host.bindProcess(launchID: stage.id, pid: candidates[0].pid); bound = candidates[0].pid
                    } else if candidates.count > 1 || ContinuousClock().now >= deadline { throw PiBridgeFailure.identity }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            if !Task.isCancelled { failure = "pi-foreground-binding-lost" }
        }
        admission.active = false; provider.retire(); host.retire(launchID: stage.id)
        let closed = await listener.stop(host: host)
        stopped = closed
        if !closed { failure = "pi-native-retirement-unconfirmed" }
        await client.disconnect()
        if closed {
            do { try provider.releaseAfterHostCleanup() }
            catch { stopped = false; failure = "pi-native-retirement-unconfirmed" }
            try? FileManager.default.removeItem(at: socketDirectory)
        }
    }
    func stop() async {
        guard !stopped else { return }
        admission.active = false; provider.retire(); host.retire(launchID: stage.id)
        if let monitor { monitor.cancel(); await monitor.value; self.monitor = nil }
        else {
            stopped = await listener.stop(host: host)
            await client.disconnect()
            if stopped {
                do { try provider.releaseAfterHostCleanup() }
                catch { stopped = false; failure = "pi-native-retirement-unconfirmed" }
                try? FileManager.default.removeItem(at: socketDirectory)
            }
        }
    }
}
#endif
