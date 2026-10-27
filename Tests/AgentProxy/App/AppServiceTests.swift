import Darwin
import Foundation

// The app's side of the agent proxy (SHPHRD-105): AgentProxyService over the
// real ap.sock client, AgentProxyControlClient, talking to a stand-in proxy
// on a Unix socket under the output folder, and a stand-in LaunchAgent that
// only counts what it is asked. Nothing is registered with launchd, and no
// herdr, agent or network is used: the app's system environment
// (AgentProxyService+System.swift) is not built into this program.

// MARK: - Harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

@MainActor func check(_ condition: Bool, _ name: String) {
    if condition { passes += 1; print("PASS: " + name) } else { failures += 1; print("FAIL: " + name) }
}

/// A proxy that answers ap.sock as AgentProxyControl describes, from the
/// state the tests give it, and records each request.
nonisolated final class FakeProxy: @unchecked Sendable {
    enum Mode { case answer, silent, wrongID, malformed, refuse }
    struct Request { let method: String; let params: [String: Any] }

    let path: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var requests: [Request] = []
    private var _mode = Mode.answer
    private var _build = "build-a"
    private var _protocolVersion = AgentProxyControl.protocolVersion
    private var _state = "running"
    private var _routes: [[String: Any]] = []
    private var nextRoute = 0

    init(path: String) { self.path = path }

    var mode: Mode { get { locked { _mode } } set { locked { _mode = newValue } } }
    var build: String { get { locked { _build } } set { locked { _build = newValue } } }
    var protocolVersion: Int { get { locked { _protocolVersion } } set { locked { _protocolVersion = newValue } } }
    var state: String { get { locked { _state } } set { locked { _state = newValue } } }
    var routes: [[String: Any]] { get { locked { _routes } } set { locked { _routes = newValue } } }
    var calls: [Request] { locked { requests } }
    func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }
    func reset() { locked { requests = [] } }

    func addRoute(kind: String, session: String, pane: String, terminal: String, oauthRejected: Bool = false) -> String {
        locked {
            nextRoute += 1
            let id = "route-\(nextRoute)"
            _routes.append(["routeID": id, "kind": kind, "session": session, "paneID": pane, "terminalID": terminal,
                            "cliVersion": "1.0.0", "createdAt": "2026-10-22T00:00:00Z", "oauthRejected": oauthRejected, "inFlight": 0])
            return id
        }
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func start() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        precondition(bytes.count < 104, "socket path too long for the test")
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(bound == 0 && listen(fd, 16) == 0, "fake proxy socket")
        chmod(path, 0o600)
        locked { descriptor = fd }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() {
        let fd = locked { () -> Int32 in let fd = descriptor; descriptor = -1; return fd }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(path)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }
            data.append(contentsOf: buffer[0..<count])
        }
        let line = data.prefix(upTo: data.firstIndex(of: 0x0A)!)
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = request["id"] as? String, let method = request["method"] as? String else { return }
        let params = request["params"] as? [String: Any] ?? [:]
        locked { requests.append(Request(method: method, params: params)) }
        let answer: Data
        switch mode {
        case .silent:
            Thread.sleep(forTimeInterval: 3)
            return
        case .malformed:
            answer = Data("not json\n".utf8)
        case .refuse:
            answer = try! JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": "invalid_params", "message": "no"]]) + Data([0x0A])
        case .wrongID, .answer:
            let echoed = mode == .wrongID ? "someone-else" : id
            var envelope: [String: Any] = ["id": echoed]
            switch respond(method, params) {
            case .success(let result): envelope["result"] = result
            case .failure(let error): envelope["error"] = ["code": error.code, "message": error.message]
            }
            answer = try! JSONSerialization.data(withJSONObject: envelope) + Data([0x0A])
        }
        _ = answer.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    private func respond(_ method: String, _ params: [String: Any]) -> Result<Any, AgentProxyControlError> {
        locked {
            switch method {
            case "proxy.status":
                return .success(["protocolVersion": _protocolVersion, "build": _build, "port": 24680, "state": _state,
                                 "routeCount": _routes.count, "inFlight": 0,
                                 "recorder": ["state": "running", "pid": 1, "restarts": 0],
                                 "counters": ["exchanges": 0, "rejected": 0, "upstreamFailures": 0, "recorderDropped": 0]])
            case "proxy.restartWhenIdle":
                _state = "draining"
                return .success(["accepted": true, "inFlight": 0])
            case "routes.create":
                nextRoute += 1
                let id = "route-\(nextRoute)"
                var route = params
                route["routeID"] = id; route["createdAt"] = "2026-10-22T00:00:00Z"; route["oauthRejected"] = false; route["inFlight"] = 0
                _routes.append(route)
                let token = String(format: "%032x", nextRoute)
                return .success(["routeID": id, "baseURL": "http://127.0.0.1:24680/p/" + token])
            case "routes.remove":
                let id = params["routeID"] as? String
                let before = _routes.count
                _routes.removeAll { $0["routeID"] as? String == id }
                return .success(["removed": _routes.count < before])
            case "routes.list":
                return .success(["routes": _routes])
            case "conversation.clearSaved":
                guard params["confirmed"] as? Bool == true else {
                    return .failure(AgentProxyControlError(code: .invalidParams, message: "confirmation required"))
                }
                return .failure(AgentProxyControlError(code: .unavailable, message: "producer exclusion unverified"))
            default:
                return .failure(AgentProxyControlError(code: .unknownMethod, message: "unknown"))
            }
        }
    }
}

@MainActor final class FakeLaunchAgent: AgentProxyLaunchAgent {
    var state: AgentProxyLaunchAgentState = .notRegistered
    var registered = 0, unregistered = 0, opened = 0
    var registerError: Error?
    /// What `state` becomes when registered: `.requiresApproval` when the
    /// person turned the app's background items off.
    var registeredState: AgentProxyLaunchAgentState = .enabled

    func register() throws {
        registered += 1
        if let registerError { throw registerError }
        state = registeredState
    }
    func unregister() async throws { unregistered += 1; state = .notRegistered }
    func openSystemSettings() { opened += 1 }
}

struct Failure: Error, LocalizedError { var errorDescription: String? { "refused by the stand-in" } }

@MainActor final class World {
    let proxy: FakeProxy
    let agent = FakeLaunchAgent()
    var setting = false
    var saved: [Bool] = []
    var rejected: Set<String> = []
    var systemProxy = false
    var bundled: String? = "build-a"
    /// session → terminals; a missing session can't be read.
    var live: [String: Set<String>] = [:]
    var liveAsked: [String] = []
    lazy var service = AgentProxyService(environment: environment(timeout: 1))

    init(_ folder: String) {
        proxy = FakeProxy(path: folder + "/ap.sock")
    }

    func environment(timeout: TimeInterval) -> AgentProxyService.Environment {
        let bundled = { [unowned self] in self.bundled }()
        return AgentProxyService.Environment(
            launchAgent: agent,
            control: AgentProxyControlClient(socketPath: proxy.path, timeout: timeout),
            loadSetting: { [unowned self] in setting },
            saveSetting: { [unowned self] in setting = $0; saved.append($0) },
            loadRejectedKinds: { [unowned self] in rejected },
            saveRejectedKinds: { [unowned self] in rejected = $0 },
            bundledBuild: { bundled },
            systemProxyConfigured: { [unowned self] in systemProxy },
            liveTerminals: { [unowned self] session in liveAsked.append(session); return live[session] },
            checkInterval: nil)
    }
}

/// A synthetic control plane whose first two status calls stop at gates. It
/// exercises AgentProxyService's check ownership without a socket or proxy.
actor GatedCheckControl: AgentProxyControlling {
    private var statusCalls = 0
    private var entered: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var liveTerminalSessions: [String] = []

    func status() async throws -> AgentProxyStatus {
        statusCalls += 1
        let call = statusCalls
        waiters.removeValue(forKey: call)?.resume()
        if call <= 2 { await waitForRelease(call) }
        return AgentProxyStatus(protocolVersion: AgentProxyControl.protocolVersion, build: "build-a", port: 24680,
                                state: .running, routeCount: 1, inFlight: 0,
                                recorder: .init(state: .running, pid: nil, restarts: 0),
                                counters: .init(exchanges: 0, rejected: 0, upstreamFailures: 0, recorderDropped: 0))
    }

    func restartWhenIdle() async throws -> AgentProxyRestartWhenIdle { .init(accepted: true, inFlight: 0) }
    func createRoute(_ request: AgentProxyRouteCreate) async throws -> AgentProxyRouteCreated {
        .init(routeID: "synthetic", baseURL: "http://127.0.0.1:24680/p/00000000000000000000000000000000")
    }
    func removeRoute(_ routeID: String) async throws -> Bool { true }
    func listRoutes() async throws -> [AgentProxyRoute] {
        [.init(routeID: "synthetic", kind: .claude, session: "sweep", paneID: "p", terminalID: "live", cliVersion: "1",
               createdAt: "2026-10-26T00:00:00Z", oauthRejected: false, inFlight: 0)]
    }

    func waitForStatusCall(_ call: Int) async {
        guard statusCalls < call else { return }
        await withCheckedContinuation { waiters[call] = $0 }
    }

    func releaseStatusCall(_ call: Int) {
        released.insert(call)
        entered.removeValue(forKey: call)?.resume()
    }

    func statusCallCount() -> Int { statusCalls }
    func recordLiveTerminals(_ session: String) { liveTerminalSessions.append(session) }
    func askedLiveTerminals() -> [String] { liveTerminalSessions }

    private func waitForRelease(_ call: Int) async {
        guard !released.contains(call) else { return }
        await withCheckedContinuation { entered[call] = $0 }
    }
}

@MainActor final class CheckHeartbeat {
    private var beats: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func beat(_ name: String) {
        beats.insert(name)
        waiters.removeValue(forKey: name)?.resume()
    }

    func wait(for name: String) async {
        guard !beats.contains(name) else { return }
        await withCheckedContinuation { waiters[name] = $0 }
    }

    func contains(_ names: Set<String>) -> Bool { names.isSubset(of: beats) }
}

let thisMac = Machine(displayName: "This Mac", hostname: "localhost", username: "owner", isLocal: true)
let remote = Machine(displayName: "Studio", hostname: "studio.invalid", username: "owner")
func pane(_ id: String, terminal: String, session: String = "default", herdrMachine: String? = nil) -> AgentPaneIdentity {
    AgentPaneIdentity(machineID: thisMac.id.uuidString, herdrMachineID: herdrMachine, session: session, paneID: id, terminalID: terminal)
}

// MARK: - Cases

@MainActor func controlClient(_ folder: String) async {
    let proxy = FakeProxy(path: folder + "/c.sock")
    let client = AgentProxyControlClient(socketPath: proxy.path, timeout: 0.5)
    func failure(_ body: () async throws -> Void) async -> AgentProxyControlFailure? {
        do { try await body(); return nil } catch let error as AgentProxyControlFailure { return error } catch { return nil }
    }
    check(await failure { _ = try await client.status() } == .unreachable, "client: no socket is unreachable")
    proxy.start()
    let status = try? await client.status()
    check(status?.build == "build-a" && status?.state == .running && status?.protocolVersion == AgentProxyControl.protocolVersion,
          "client: proxy.status decoded")
    let created = try? await client.createRoute(AgentProxyRouteCreate(kind: .claude, session: "default", paneID: "w1:p1", terminalID: "t1", cliVersion: "2.1.288"))
    check(created?.baseURL.hasPrefix("http://127.0.0.1:24680/p/") == true, "client: routes.create gives a base URL")
    let sent = proxy.calls.last
    check(sent?.method == "routes.create" && sent?.params["kind"] as? String == "claude" && sent?.params["terminalID"] as? String == "t1"
          && sent?.params["cliVersion"] as? String == "2.1.288", "client: routes.create sends the route's fields")
    check((try? await client.listRoutes())?.map(\.routeID) == [created?.routeID ?? "?"], "client: routes.list decoded")
    let removed = try? await client.removeRoute(created?.routeID ?? ""), absent = try? await client.removeRoute("absent")
    check(removed == true && absent == false, "client: routes.remove says whether it removed one")
    proxy.mode = .wrongID
    check(await failure { _ = try await client.status() } == .malformed, "client: an answer to another request is malformed")
    proxy.mode = .malformed
    check(await failure { _ = try await client.status() } == .malformed, "client: a line that isn't JSON is malformed")
    proxy.mode = .silent
    let started = Date()
    check(await failure { _ = try await client.status() } == .timedOut && Date().timeIntervalSince(started) < 2.5,
          "client: a proxy that doesn't answer times out")
    proxy.mode = .refuse
    if case .refused(let error)? = await failure({ _ = try await client.restartWhenIdle() }) {
        check(error.code == "invalid_params", "client: a refusal carries the proxy's error code")
    } else { check(false, "client: a refusal carries the proxy's error code") }
    proxy.mode = .answer
    let long = folder + "/" + String(repeating: "x", count: 120)
    check(await failure { _ = try await AgentProxyControlClient(socketPath: long).status() } == .unreachable,
          "client: a path too long for a socket is never tried")
    proxy.stop()
    check(await failure { _ = try await client.status() } == .unreachable, "client: a proxy gone is unreachable")
}

@MainActor func registration(_ folder: String) async {
    let world = World(folder)
    world.proxy.start()
    let service = world.service
    await service.check()
    check(service.phase == .off && world.agent.registered == 0 && world.proxy.calls.isEmpty, "off: nothing registered, the proxy not asked")
    await service.clearSavedHistory()
    check(world.proxy.count("conversation.clearSaved") == 0 && service.savedHistoryMessage != nil,
          "offline clear fails closed without sending an unconfirmed request")
    check(await service.route(for: .claude, pane: pane("w1:p1", terminal: "t1"), cliVersion: "2.1.288 (Claude Code)", on: thisMac) == nil
          && service.lastSkip == .settingOff && world.proxy.count("routes.create") == 0, "off: a launch goes without the proxy")

    await service.setOn(true)
    check(world.saved == [true] && world.agent.registered == 1 && world.agent.state == .enabled, "on: saved, and the LaunchAgent registered")
    check(service.phase == .running && world.proxy.count("proxy.status") == 1 && world.proxy.count("routes.list") == 1,
          "on: the proxy asked how it is and for its routes, and running")
    await service.clearSavedHistory()
    check(world.proxy.count("conversation.clearSaved") == 0 && service.savedHistoryMessage != nil,
          "running proxy still fails clear closed without dispatching a mutation")
    await service.check()
    check(world.agent.registered == 1, "on: registered once")

    // Launches.
    world.proxy.reset()
    let claude = await service.route(for: .claude, pane: pane("w1:p1", terminal: "t1"), cliVersion: "2.1.288 (Claude Code)", on: thisMac)
    let create = world.proxy.calls.first { $0.method == "routes.create" }
    check(claude != nil && service.lastSkip == nil && AgentProxyService.isBaseURL(claude?.baseURL ?? ""), "Claude 2.1.288: a route")
    check(world.proxy.calls.map(\.method).prefix(2) == ["proxy.status", "routes.list"], "the proxy is asked how it is before each route")
    check(create?.params["kind"] as? String == "claude" && create?.params["session"] as? String == "default"
          && create?.params["paneID"] as? String == "w1:p1" && create?.params["terminalID"] as? String == "t1"
          && create?.params["cliVersion"] as? String == "2.1.288 (Claude Code)", "the route is the pane's, with the CLI's version")
    for (kind, version, gets) in [(AgentKind.claude, "2.1.282 (Claude Code)", false), (.claude, "2.1.283", true), (.claude, "3.0", true),
                                  (.codex, "codex-cli 0.161.9", false), (.codex, "codex-cli 0.162.0", true), (.pi, "1.2.9", false),
                                  (.pi, "1.3.0", true), (.pi, "1.4.0", true), (.claude, nil, false), (.codex, "unknown", false)] {
        let before = world.proxy.count("routes.create")
        let route = await service.route(for: kind, pane: pane("w1:p2", terminal: "t2"), cliVersion: version, on: thisMac)
        check((route != nil) == gets && (world.proxy.count("routes.create") > before) == gets
              && (gets || service.lastSkip == .cliVersion), "\(kind) \(version ?? "with no version"): \(gets ? "a route" : "too old, none asked for")")
        if let route { await service.discard(route) }
    }
    world.systemProxy = true
    var before = world.proxy.count("routes.create")
    check(await service.route(for: .codex, pane: pane("w1:p2", terminal: "t2"), cliVersion: "0.170.0", on: thisMac) == nil
          && service.lastSkip == .systemProxy && world.proxy.count("routes.create") == before, "a system HTTP proxy: none")
    world.systemProxy = false
    check(await service.route(for: .codex, pane: pane("w1:p2", terminal: "t2"), cliVersion: "0.170.0", on: remote) == nil
          && service.lastSkip == .notThisMac, "another machine than This Mac: none")
    check(await service.route(for: .codex, pane: pane("w1:p2", terminal: "t2", herdrMachine: "hm"), cliVersion: "0.170.0", on: thisMac) == nil
          && service.lastSkip == .notThisMac, "a herdr machine's pane: none")

    // A route whose agent never started is removed; one whose agent did stays.
    before = world.proxy.count("routes.remove")
    if let claude { await service.discard(claude) }
    check(world.proxy.count("routes.remove") == before + 1 && !world.proxy.routes.contains { $0["routeID"] as? String == claude?.routeID },
          "a route discarded is removed from the proxy")

    // Another build of the proxy: asked once to restart when idle; no route meanwhile.
    world.proxy.build = "build-old"
    world.proxy.reset()
    await service.check()
    check(service.phase == .starting && world.proxy.count("proxy.restartWhenIdle") == 1, "another build: asked to restart once idle")
    await service.check()
    check(world.proxy.count("proxy.restartWhenIdle") == 1, "…once")
    check(await service.route(for: .claude, pane: pane("w1:p3", terminal: "t3"), cliVersion: "2.1.288", on: thisMac) == nil
          && service.lastSkip == .proxyUnavailable && world.proxy.count("routes.create") == 0, "…and no agent is given it meanwhile")
    world.proxy.build = "build-a"; world.proxy.state = "running"
    await service.check()
    check(service.phase == .running, "this app's build running again: running")
    world.proxy.protocolVersion = AgentProxyControl.protocolVersion + 1
    await service.check()
    if case .unavailable = service.phase { check(true, "another protocol: unavailable") } else { check(false, "another protocol: unavailable") }
    world.proxy.protocolVersion = AgentProxyControl.protocolVersion
    world.proxy.state = "draining"
    await service.check()
    check(service.phase == .starting, "draining: starting, no routes given")
    world.proxy.state = "running"

    // Not answering: starting while launchd starts it, then unavailable.
    world.proxy.stop()
    await service.check()
    check(service.phase == .starting, "not answering once: starting")
    await service.check(); await service.check()
    if case .unavailable = service.phase { check(true, "not answering three times: unavailable") } else { check(false, "not answering three times: unavailable") }
    check(await service.route(for: .claude, pane: pane("w1:p3", terminal: "t3"), cliVersion: "2.1.288", on: thisMac) == nil
          && service.lastSkip == .proxyUnavailable, "…and launches go without it")
    world.proxy.start()
    await service.check()
    check(service.phase == .running, "answering again: running")
}

@MainActor func unverifiedBuild(_ folder: String) async {
    let world = World(folder)
    world.bundled = nil
    world.setting = true
    world.agent.state = .enabled
    world.proxy.start()
    let service = world.service
    await service.check()
    if case .unavailable = service.phase {
        check(true, "unreadable bundled build: unavailable")
    } else { check(false, "unreadable bundled build: unavailable") }
    check(await service.route(for: .claude, pane: pane("w1:p1", terminal: "t1"), cliVersion: "2.1.290", on: thisMac) == nil
          && service.lastSkip == .proxyUnavailable && world.proxy.count("routes.create") == 0,
          "unreadable bundled build: never inject an unverified proxy")
    world.proxy.stop()
}

@MainActor func rejections(_ folder: String) async {
    let world = World(folder)
    world.proxy.start()
    world.setting = true
    world.agent.state = .enabled
    let service = world.service
    _ = world.proxy.addRoute(kind: "codex", session: "default", pane: "w1:p1", terminal: "t1", oauthRejected: true)
    world.live["default"] = ["t1"]
    await service.check()
    check(service.rejectedKinds == ["codex"] && world.rejected == ["codex"], "a route turned away for its sign-in: that kind is remembered")
    let creates = world.proxy.count("routes.create")
    check(await service.route(for: .codex, pane: pane("w1:p2", terminal: "t2"), cliVersion: "codex-cli 0.170.0", on: thisMac) == nil
          && service.lastSkip == .oauthRejected && world.proxy.count("routes.create") == creates, "…and Codex goes without the proxy from then on")
    let claude = await service.route(for: .claude, pane: pane("w1:p2", terminal: "t2"), cliVersion: "2.1.290", on: thisMac)
    check(claude != nil, "…Claude Code still gets it")
    if let claude { await service.discard(claude) }
    // A fresh service remembers it.
    let again = AgentProxyService(environment: world.environment(timeout: 1))
    check(again.rejectedKinds == ["codex"], "remembered across the app's restarts")
    world.live["default"] = []
    await service.setOn(false)
    await service.setOn(true)
    check(service.rejectedKinds.isEmpty && world.rejected.isEmpty, "turned off and on: every kind is tried again")
    world.proxy.stop()
}

@MainActor func sweepAndStop(_ folder: String) async {
    let world = World(folder)
    world.proxy.start()
    world.setting = true
    world.agent.state = .enabled
    let service = world.service
    let gone = world.proxy.addRoute(kind: "claude", session: "default", pane: "w1:p1", terminal: "t-gone")
    let kept = world.proxy.addRoute(kind: "codex", session: "default", pane: "w1:p2", terminal: "t-live")
    let unread = world.proxy.addRoute(kind: "pi", session: "work", pane: "w2:p1", terminal: "t-work")
    world.live = ["default": ["t-live", "t-new"]]
    await service.check()
    let ids = Set(world.proxy.routes.compactMap { $0["routeID"] as? String })
    check(!ids.contains(gone) && ids.contains(kept), "a route whose terminal is gone from its session is removed; a live one stays")
    check(ids.contains(unread) && world.liveAsked.contains("work"), "a session that can't be read keeps its routes")

    // A launch's route is never swept before its agent starts, and a
    // launch doesn't wait for herdr to be asked about the others.
    let asked = world.liveAsked.count
    let launched = await service.route(for: .claude, pane: pane("w1:p9", terminal: "t-new2"), cliVersion: "2.1.290", on: thisMac)
    check(launched != nil && world.liveAsked.count == asked, "a launch's route is given without asking herdr")
    await service.check()
    check(launched != nil && world.proxy.routes.contains { $0["routeID"] as? String == launched?.routeID },
          "a route made for a launch not yet started isn't swept")
    if let launched { service.started(launched) }
    await service.check()
    check(!world.proxy.routes.contains { $0["routeID"] as? String == launched?.routeID }, "…once started, it goes with its pane like the rest")

    // Turned off with agents still using it: stays until they are gone.
    world.proxy.reset()
    await service.setOn(false)
    check(world.saved.last == false && world.agent.unregistered == 0, "off with agents on it: still registered")
    check(service.phase == .stopping(agents: 2), "…shown as stopping once those 2 agents have ended")
    check(await service.route(for: .claude, pane: pane("w1:p8", terminal: "t8"), cliVersion: "2.1.290", on: thisMac) == nil
          && service.lastSkip == .settingOff && world.proxy.count("routes.create") == 0, "…and new launches go without it")
    world.live["work"] = []
    await service.check()
    check(service.phase == .stopping(agents: 1) && world.agent.unregistered == 0, "one agent's pane gone: 1 left")
    world.live["default"] = []
    await service.check()
    check(world.agent.unregistered == 1 && service.phase == .off && world.agent.state == .notRegistered,
          "the last one gone: the LaunchAgent is unregistered")
    let calls = world.proxy.calls.count
    await service.check()
    check(world.proxy.calls.count == calls, "off and unregistered: the proxy isn't asked again")

    // A broken control socket cannot prove the forwarder has no users.
    world.agent.state = .enabled
    _ = world.proxy.addRoute(kind: "claude", session: "default", pane: "w1:p1", terminal: "t-x")
    world.live["default"] = ["t-x"]
    world.proxy.stop()
    await service.check(); await service.check(); await service.check(); await service.check()
    check(world.agent.unregistered == 1, "off, control unavailable: do not terminate possibly active agents")
    if case .unavailable = service.phase {
        check(true, "unknown routes while stopping are shown as unavailable")
    } else { check(false, "unknown routes while stopping are shown as unavailable") }
    world.proxy.start()
    await service.check()
    check(world.agent.unregistered == 1 && service.phase == .stopping(agents: 1), "control recovers: live route is still protected")
    world.live["default"] = []
    await service.check()
    check(world.agent.unregistered == 2 && service.phase == .off, "only a confirmed empty route list allows unregistering")
    world.proxy.stop()
}

@MainActor func approval(_ folder: String) async {
    let world = World(folder)
    world.proxy.start()
    world.agent.registeredState = .requiresApproval
    let service = world.service
    await service.setOn(true)
    check(service.phase == .needsApproval, "turned off in Login Items: shown so")
    check(await service.route(for: .claude, pane: pane("w1:p1", terminal: "t1"), cliVersion: "2.1.290", on: thisMac) == nil
          && service.lastSkip == .proxyUnavailable, "…and no route")
    service.openLoginItems()
    check(world.agent.opened == 1, "Open Login Items Settings… asks the LaunchAgent's stand-in, nothing else")
    let failing = World(folder + "/f")
    failing.agent.registerError = Failure()
    await failing.service.setOn(true)
    if case .unavailable(let message) = failing.service.phase {
        check(message.contains("refused by the stand-in"), "registration refused: shown with why")
    } else { check(false, "registration refused: shown with why") }
    world.proxy.stop()
}

@MainActor func checkOwnership() async {
    let control = GatedCheckControl()
    let agent = FakeLaunchAgent()
    agent.state = .enabled
    let heartbeat = CheckHeartbeat()
    let service = AgentProxyService(environment: .init(
        launchAgent: agent,
        control: control,
        loadSetting: { true },
        saveSetting: { _ in },
        loadRejectedKinds: { [] },
        saveRejectedKinds: { _ in },
        bundledBuild: { "build-a" },
        systemProxyConfigured: { false },
        liveTerminals: { session in
            await control.recordLiveTerminals(session)
            return ["live"]
        },
        checkInterval: nil))

    // The owner is stopped in status while the contender joins its check.
    let owner = Task { @MainActor in
        heartbeat.beat("owner-started")
        await service.check(sweeping: false)
        heartbeat.beat("owner-completed")
    }
    await control.waitForStatusCall(1)
    let contender = Task { @MainActor in
        heartbeat.beat("contender-started")
        await service.check(sweeping: true)
        heartbeat.beat("contender-completed")
    }
    await heartbeat.wait(for: "contender-started")
    await control.releaseStatusCall(1)
    await control.waitForStatusCall(2)

    // While the second check is gated, the observer must wait on its published
    // marker rather than begin a third status call.
    let observer = Task { @MainActor in
        heartbeat.beat("observer-started")
        await service.check(sweeping: false)
        heartbeat.beat("observer-completed")
    }
    await heartbeat.wait(for: "observer-started")
    check(await control.statusCallCount() == 2, "check: a gated newer task stays published for waiting callers")

    await control.releaseStatusCall(2)
    await owner.value
    await contender.value
    await observer.value
    check(heartbeat.contains(["owner-completed", "contender-completed", "observer-completed"]),
          "check: every overlapping caller completes with a MainActor heartbeat")
    check(await control.statusCallCount() == 3, "check: every caller performs its serialized check")
    check(await control.askedLiveTerminals() == ["sweep"],
          "check: true sweeping intent runs once; false callers do not sweep")
}

@MainActor func baseURLs() {
    let token = String(repeating: "ab", count: 16)
    check(AgentProxyService.isBaseURL("http://127.0.0.1:24680/p/" + token), "base URL: the proxy's form")
    for bad in ["https://127.0.0.1:24680/p/" + token, "http://localhost:24680/p/" + token, "http://127.0.0.1:0/p/" + token,
                "http://127.0.0.1:70000/p/" + token, "http://127.0.0.1:24680/p/" + token.uppercased(), "http://127.0.0.1:24680/p/" + token + "/x",
                "http://127.0.0.1:24680/p/abc", "http://127.0.0.1:24680/q/" + token] {
        check(!AgentProxyService.isBaseURL(bad), "base URL refused: \(bad)")
    }
}

@main struct AppServiceTests {
    @MainActor static func main() async {
        let root = CommandLine.arguments[1]
        for name in ["client", "registration", "unverified", "rejections", "sweep", "approval", "approval/f"] {
            try? FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        await controlClient(root + "/client")
        await registration(root + "/registration")
        await unverifiedBuild(root + "/unverified")
        await rejections(root + "/rejections")
        await sweepAndStop(root + "/sweep")
        await approval(root + "/approval")
        await checkOwnership()
        baseURLs()
        print("agent proxy service: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
