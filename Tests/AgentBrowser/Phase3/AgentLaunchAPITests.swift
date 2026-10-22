import Foundation

actor LaunchTransport: HerdrTransport {
    var response: JSONValue = .object([:])
    var requests: [(String, JSONValue)] = []
    var commands: [[String]] = []
    func configure(_ response: JSONValue) { self.response = response }
    func lastRequest() -> (String, JSONValue)? { requests.last }
    func lastCommand() -> [String]? { commands.last }
    func connect() async throws {}
    func disconnect() async {}
    func send(method: String, params: JSONValue) async throws -> JSONValue { requests.append((method, params)); return response }
    func runHerdr(_ arguments: [String]) async throws -> Data { commands.append(arguments); return try JSONEncoder().encode(JSONValue.object(["result": response])) }
    func runScript(_ script: String) async throws -> Data { throw AgentRuntimeError.rejected("not-a-runtime-test") }
}

/// herdr while a new pane's shell runs its startup files: the same snapshot
/// and agent.list every time, and the pane's foreground from `steps` in
/// turn, the last one repeated. A step is the shell's PID and whether a
/// child (a command substitution) is in the foreground with it.
actor ShellStartTransport: HerdrTransport {
    let pane: JSONValue
    let steps: [(shell: UInt32, child: Bool)]
    let agents: [JSONValue]
    private(set) var processReads = 0
    init(pane: JSONValue, steps: [(shell: UInt32, child: Bool)], agents: [JSONValue] = []) {
        self.pane = pane; self.steps = steps; self.agents = agents
    }
    func connect() async throws {}
    func disconnect() async {}
    func send(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "session.snapshot": return .object(["snapshot": .object(["panes": .array([pane])])])
        case "agent.list": return .object(["type": .string("agent_list"), "agents": .array(agents)])
        case "pane.process_info":
            let step = steps[min(processReads, steps.count - 1)]
            processReads += 1
            var foreground: [JSONValue] = [.object(["pid": .number(Double(step.shell)), "name": .string("zsh")])]
            if step.child { foreground.append(.object(["pid": .number(Double(step.shell + 1000)), "name": .string("brew")])) }
            return .object(["type": .string("pane_process_info"), "process_info": .object([
                "pane_id": params["pane_id"] ?? .null, "shell_pid": .number(Double(step.shell)), "foreground_processes": .array(foreground)])])
        default: throw AgentRuntimeError.rejected("unexpected-" + method)
        }
    }
    func runHerdr(_ arguments: [String]) async throws -> Data { throw AgentRuntimeError.rejected("not-a-cli-test") }
    func runScript(_ script: String) async throws -> Data { throw AgentRuntimeError.rejected("not-a-runtime-test") }
}

@main struct AgentLaunchAPITests {
    static func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    static func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS: " + name) }
    static func rejects(_ name: String, _ body: @Sendable () async throws -> Void) async {
        do { try await body(); preconditionFailure(name) } catch { print("PASS: " + name) }
    }
    static func main() async throws {
        let row = try json("""
        {"pane_id":"w1:p1","terminal_id":"term_owned","agent":"claude-code","agent_status":"idle","interactive_ready":true,"launch_pending":false,"revision":4,"state_change_seq":3,"agent_session":{"source":"hook-owned","agent":"claude","kind":"id","value":"actual-id"}}
        """)
        let agent = AgentSummary(json: row)!
        check(agent.source == "hook-owned" && agent.sessionReference?.resumeID(for: .claude) == "actual-id", "actual compatible ID is distinct from source")
        check(agent.sessionReference?.resumeID(for: .codex) == nil, "incompatible session kind rejected")
        let path = AgentSessionReference(json: try json("""
        {"source":"hook","agent":"claude","kind":"path","value":"/owned/session.json"}
        """))!
        check(path.resumeID(for: .claude) == nil, "path session is never a resume ID")
        let absent = AgentSummary(json: try json("{\"pane_id\":\"p\",\"terminal_id\":\"t\"}"))!
        check(absent.interactiveReady == nil && absent.launchPending == nil, "absent readiness remains unknown")
        check(AgentSummary(json: try json("{\"pane_id\":\"\",\"terminal_id\":\"t\"}")) == nil, "blank pane identity cannot authorize disappearance")
        check(AgentSummary(json: try json("{\"pane_id\":\"p\",\"terminal_id\":\"  \"}")) == nil, "blank terminal identity rejected")
        let transport = LaunchTransport(), client = HerdrClient(transport: transport)
        await transport.configure(.object(["type": .string("agent_started"), "agent": row, "argv": .array([.string("claude"), .string("--plugin-dir"), .string("/owned/plugin")])]))
        let started = try await client.agentStart(name: "owned", kind: .claude, paneID: "w1:p1", arguments: ["--plugin-dir", "/owned/plugin"])
        check(started.agent.terminalID == "term_owned" && started.arguments.count == 3, "typed agent.start result retains actual argv and terminal")
        let request = await transport.lastRequest()!
        check(request.0 == "agent.start" && request.1["timeout_ms"]?.intValue == 30_000 && request.1["kind"]?.stringValue == "claude", "exact start wire params")
        await rejects("invalid startup deadline rejected") { _ = try await client.agentStart(name: "owned", kind: .claude, paneID: "w1:p1", arguments: [], timeoutMs: 3000) }
        await transport.configure(.object(["type": .string("agent_list"), "agents": .array([row])]))
        let listed = try await client.agentList()
        check(listed == [agent], "typed agent.list retains readiness and session fields")
        await transport.configure(.object([:]))
        await rejects("missing agent.list envelope rejected") { _ = try await client.agentList() }
        await transport.configure(.object(["type": .string("agent_started"), "agent": row, "argv": .array([.null])]))
        await rejects("malformed start argv rejected") { _ = try await client.agentStart(name: "owned", kind: .claude, paneID: "w1:p1", arguments: []) }
        let infoJSON = try json("""
        {"pane_id":"w1:p1","shell_pid":1,"foreground_process_group_id":2,"foreground_processes":[{"pid":2,"name":"claude","argv":null,"argv0":null}]}
        """)
        await transport.configure(.object(["type": .string("pane_process_info"), "process_info": infoJSON]))
        let nullInfo = try await client.processInfo(paneID: "w1:p1")
        check(nullInfo.agentArguments(for: .claude) == nil && !nullInfo.isShellForeground, "null argv does not prove missing injection or shell readiness")
        let shellInfo = try JSONDecoder().decode(PaneProcessInfo.self, from: Data("{\"pane_id\":\"p\",\"shell_pid\":1,\"foreground_processes\":[{\"pid\":1,\"name\":\"zsh\"}]}".utf8))
        check(shellInfo.isShellForeground, "actual foreground shell PID proves shell process")
        await transport.configure(.object(["type": .string("pane_process_info"), "process_info": try json("{\"pane_id\":\"other\",\"foreground_processes\":[]}")]))
        await rejects("wrong process pane identity rejected") { _ = try await client.processInfo(paneID: "w1:p1") }
        let tab = try json("{\"tab_id\":\"w1:t1\",\"workspace_id\":\"w1\",\"label\":\"owned\",\"number\":1}")
        await transport.configure(.object(["root_pane": row, "tab": tab]))
        _ = try await client.createTab(inWorkspace: "w1", label: nil, on: nil, environment: ["Z": "value with spaces=equals", "A": "/owned/descriptor"])
        let envRequest = await transport.lastRequest()!
        check(envRequest.1["env"]?["Z"]?.stringValue == "value with spaces=equals", "tab.create sends actual env object")
        let remote = HerdrMachine(id: "owned-remote", label: "Owned", target: "owned-invalid", session: "default", enabled: true)
        _ = try await client.createWorkspace(label: nil, on: remote, environment: ["Z": "spaces=equals", "A": "first"])
        check(await transport.lastCommand() == ["--machine", "owned-remote", "workspace", "create", "--no-focus", "--env", "A=first", "--env", "Z=spaces=equals"], "nested workspace env is deterministic argv, not shell text")
        let plan = PreparedAgentLaunch(kind: .claude, executable: "claude", arguments: ["--plugin-dir", "/owned/plugin"], environment: [:], outputFolder: "/owned/output", sessionFolder: "/owned/session", pluginDirectory: "/owned/plugin", mcpConfiguration: "/owned/mcp.json", mcpArguments: [], codexPluginKey: nil, injection: .plugin)
        let process = try JSONDecoder().decode(PaneProcessInfo.self, from: Data("{\"pane_id\":\"w1:p1\",\"foreground_processes\":[{\"pid\":2,\"name\":\"claude\",\"argv\":[\"claude\"]}]}".utf8))
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: false, connectedPID: nil, mode: .plugin, fresh: true) == .missingInjection, "actual uninjected foreground argv classified missing")
        check(AgentBrowserStatus.inspect(agent: agent, process: nullInfo, prepared: plan, socketConnected: false, connectedPID: nil, mode: .plugin, fresh: true) == .unknown, "null argv classified unknown")
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: false, connectedPID: nil, mode: .global, fresh: true) == .unknown, "global argv is not proof of missing injection")
        check(AgentBrowserStatus.inspect(agent: agent, process: nullInfo, prepared: nil, socketConnected: true, connectedPID: nil, mode: .global, fresh: true) == .connected, "global live socket is actual connection authority")
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: true, connectedPID: nil, mode: .plugin, fresh: false) == .unknown, "stale inspection is never healthy")
        // The process seen with the socket open, after its MCP idled out and closed it.
        let injectedProcess = try JSONDecoder().decode(PaneProcessInfo.self, from: Data("{\"pane_id\":\"w1:p1\",\"foreground_processes\":[{\"pid\":2,\"name\":\"claude\",\"argv\":[\"claude\",\"--plugin-dir\",\"/owned/plugin\"]}]}".utf8))
        check(injectedProcess.agentProcess(for: .claude)?.pid == 2 && injectedProcess.agentProcess(for: .codex) == nil && injectedProcess.agentProcess(for: .pi) == nil, "agent process is the one foreground process of the kind")
        check(AgentBrowserStatus.inspect(agent: agent, process: injectedProcess, prepared: plan, socketConnected: false, connectedPID: nil, mode: .plugin, fresh: true) == .injectedDisconnected, "injected process never seen connected is not connected")
        check(AgentBrowserStatus.inspect(agent: agent, process: injectedProcess, prepared: plan, socketConnected: false, connectedPID: 2, mode: .plugin, fresh: true) == .connected, "process seen connected stays connected after its socket closes")
        check(AgentBrowserStatus.inspect(agent: agent, process: injectedProcess, prepared: plan, socketConnected: false, connectedPID: 3, mode: .plugin, fresh: true) == .injectedDisconnected, "another process in the pane does not inherit the connection")
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: false, connectedPID: 3, mode: .plugin, fresh: true) == .missingInjection, "a later uninjected process is still missing injection")
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: false, connectedPID: 2, mode: .global, fresh: true) == .connected, "global process seen connected stays connected")
        check(AgentBrowserStatus.inspect(agent: agent, process: nullInfo, prepared: plan, socketConnected: false, connectedPID: 2, mode: .plugin, fresh: true) == .unknown, "null argv is not taken for the process seen connected")
        check(AgentBrowserStatus.inspect(agent: agent, process: injectedProcess, prepared: plan, socketConnected: false, connectedPID: 2, mode: .plugin, fresh: false) == .unknown, "stale inspection of the process seen connected is unknown")
        // A pre-restart Shepherd launch: its argv already carries Shepherd's own registration.
        let injectedArgv = ["claude", "--plugin-dir", "/owned/reservations/r1/plugin"]
        for code in ["duplicate-registration", "uninspectable-claude-registration"] {
            check(AgentDirectPreparation.isQuiet(AgentRuntimeError.rejected(code)), "\(code) remembered without a diagnostic")
        }
        check(AgentDirectPreparation.shouldPrepare(injectedArgv, rejected: nil), "unremembered direct argv is prepared")
        check(!AgentDirectPreparation.shouldPrepare(injectedArgv, rejected: injectedArgv), "same rejected argv is not prepared again")
        check(AgentDirectPreparation.shouldPrepare(["claude"], rejected: injectedArgv), "different argv in the pane is prepared again")
        for error: Error in [AgentRuntimeError.rejected("cli-missing"), AgentRuntimeError.rejected("setup-busy"), AgentRuntimeError.rejected("duplicate-registration-other"), AgentRuntimeError.nodeUnavailable, HostScriptError(status: 1, message: "transport")] {
            check(!AgentDirectPreparation.isQuiet(error), "\(error) reported and retried")
        }
        check(AgentResumeEligibility.sessionID(agent: agent, process: process, status: .missingInjection, fresh: true) == "actual-id", "idle compatible ID eligibility")
        check(AgentResumeEligibility.sessionID(agent: agent, process: process, status: .missingInjection, fresh: false) == nil, "stale idle resume denied")
        check(AgentResumeEligibility.unchanged(agent, agent), "same fresh idle identity retains eligibility")
        let changed = AgentSummary(json: try json("{\"pane_id\":\"w1:p1\",\"terminal_id\":\"different\",\"agent\":\"claude\",\"agent_status\":\"working\"}"))!
        check(!AgentResumeEligibility.unchanged(agent, changed), "busy or replaced terminal cannot authorize stop")
        // Paired herdr seen/unseen quiescent candidates; every other guard stays strict.
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        func variant(_ changes: [String: Any], removing: [String] = []) throws -> AgentSummary {
            var value = base
            for (key, replacement) in changes { value[key] = replacement }
            for key in removing { value.removeValue(forKey: key) }
            return AgentSummary(json: try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value)))!
        }
        for state in ["idle", "done"] {
            let valid = try variant(["agent_status": state])
            check(valid.state.isQuiescent && AgentResumeEligibility.sessionID(agent: valid, process: process, status: .missingInjection, fresh: true) == "actual-id", "\(state) strict eligibility")
            check(AgentResumeEligibility.unchanged(valid, valid) && AgentIdleStopPolicy.sameIdleSession(valid, valid), "\(state) shared same-session policy")
            for (key, value) in [("agent_status", "working" as Any), ("agent_status", "blocked"), ("agent_status", "unknown"), ("interactive_ready", false), ("interactive_ready", NSNull()), ("launch_pending", true), ("screen_detection_skipped", true), ("agent", "unrecognized")] {
                let denied = try variant(["agent_status": state].merging([key: value]) { _, new in new })
                check(AgentResumeEligibility.sessionID(agent: denied, process: process, status: .missingInjection, fresh: true) == nil, "\(state) denies \(key)=\(value)")
                check(!AgentResumeEligibility.unchanged(valid, denied) && !AgentIdleStopPolicy.sameIdleSession(valid, denied), "\(state) rechecks deny \(key)=\(value)")
            }
            let noReadiness = try variant(["agent_status": state], removing: ["interactive_ready"])
            check(AgentResumeEligibility.sessionID(agent: noReadiness, process: process, status: .missingInjection, fresh: true) == nil && !AgentIdleStopPolicy.sameIdleSession(valid, noReadiness), "\(state) absent readiness denied")
            check(AgentResumeEligibility.sessionID(agent: valid, process: process, status: .missingInjection, fresh: false) == nil, "\(state) stale denied")
            for status: AgentBrowserStatus in [.unknown, .connected, .injectedDisconnected, .launchPending, .remoteUnavailable] {
                check(AgentResumeEligibility.sessionID(agent: valid, process: process, status: status, fresh: true) == nil, "\(state) non-missing status denied")
            }
            for (key, value) in [("pane_id", "other" as Any), ("terminal_id", "other"), ("revision", 5), ("state_change_seq", 4), ("agent", "codex"), ("agent_session", ["source": "hook-owned", "agent": "claude", "kind": "id", "value": "other-id"])] {
                let changed = try variant(["agent_status": state].merging([key: value]) { _, new in new })
                check(!AgentResumeEligibility.unchanged(valid, changed), "\(state) changed \(key) denied")
                if key != "revision" { check(!AgentIdleStopPolicy.sameIdleSession(valid, changed), "\(state) stop changed \(key) denied") }
            }
            let remoteRow = AgentSummary(json: row, on: remote)!
            check(!AgentResumeEligibility.unchanged(valid, remoteRow) && !AgentIdleStopPolicy.sameIdleSession(valid, remoteRow), "\(state) changed owner denied")
            for reference in [["source": "hook", "agent": "codex", "kind": "id", "value": "actual-id"], ["source": "hook", "agent": "claude", "kind": "path", "value": "/owned/path"]] {
                let incompatible = try variant(["agent_status": state, "agent_session": reference])
                check(AgentResumeEligibility.sessionID(agent: incompatible, process: process, status: .missingInjection, fresh: true) == nil, "\(state) incompatible session denied")
            }
            for processJSON in ["{\"pane_id\":\"w1:p1\",\"foreground_processes\":[{\"pid\":2,\"name\":\"codex\",\"argv\":[\"codex\"]}]}", "{\"pane_id\":\"w1:p1\",\"foreground_processes\":[{\"pid\":2,\"name\":\"claude\",\"argv\":[\"claude\"]},{\"pid\":3,\"name\":\"claude\",\"argv\":[\"claude\"]}]}"] {
                let conflicting = try JSONDecoder().decode(PaneProcessInfo.self, from: Data(processJSON.utf8))
                check(AgentResumeEligibility.sessionID(agent: valid, process: conflicting, status: .missingInjection, fresh: true) == nil, "\(state) wrong/multiple foreground denied")
            }
            check(AgentResumeEligibility.sessionID(agent: valid, process: nullInfo, status: .missingInjection, fresh: true) == nil, "\(state) unknown foreground denied")
        }
        check(AgentIdleStopPolicy.isEmptyEditor(kind: .claude, ansi: "❯\n") && !AgentIdleStopPolicy.isEmptyEditor(kind: .claude, ansi: "❯ draft\n"), "Claude empty versus draft editor")
        let emptyCodex = "\u{1b}[0m\u{1b}[1m›\u{1b}[0m \u{1b}[0m\u{1b}[2mAsk Codex to do anything\u{1b}[0m"
        check(AgentIdleStopPolicy.isEmptyEditor(kind: .codex, ansi: emptyCodex), "Codex empty dim composer")
        check(!AgentIdleStopPolicy.isEmptyEditor(kind: .codex, ansi: "› draft"), "Codex draft denied")
        check(AgentKind(herdrName: "pi") == .pi, "Pi classified without pretending to be Codex")
        check(!AgentIdleStopPolicy.isEmptyEditor(kind: .pi, ansi: emptyCodex), "Codex rendering cannot authorize Pi stop")
        for kind in AgentKind.allCases { check(!AgentIdleStopPolicy.isEmptyEditor(kind: kind, ansi: emptyCodex + "\nesc to go back"), "\(kind) review modal denied") }
        #if os(macOS)
        let startupOnly: [[String: Any]] = [["sessionId": "actual-id", "cwd": "/owned/project", "type": "system"]]
        check(!AgentSavedSession.matches(kind: .claude, sessionID: "actual-id", cwd: "/owned/project", rows: startupOnly), "opaque startup ID is not a saved conversation")
        let conversation: [[String: Any]] = [["sessionId": "actual-id", "cwd": "/owned/project", "type": "user"], ["sessionId": "actual-id", "cwd": "/owned/project", "type": "assistant"]]
        check(AgentSavedSession.matches(kind: .claude, sessionID: "actual-id", cwd: "/owned/project", rows: conversation), "saved matching Claude conversation metadata accepted (unit metadata, not live readiness)")
        check(!AgentSavedSession.matches(kind: .claude, sessionID: "other-id", cwd: "/owned/project", rows: conversation), "saved conversation with different ID denied")
        check(!AgentSavedSession.matches(kind: .claude, sessionID: "actual-id", cwd: "/other/project", rows: conversation), "different CLI working folder denied before stop")
        let codexConversation: [[String: Any]] = [["type": "session_meta", "payload": ["id": "codex-id", "cwd": "/owned/project"]], ["type": "response_item", "payload": ["type": "message", "role": "user"]], ["type": "response_item", "payload": ["type": "message", "role": "assistant"]]]
        check(AgentSavedSession.matches(kind: .codex, sessionID: "codex-id", cwd: "/owned/project", rows: codexConversation), "real Codex metadata shape requires saved user and assistant roles")
        check(!AgentSavedSession.matches(kind: .pi, sessionID: "codex-id", cwd: "/owned/project", rows: codexConversation), "Pi saved-session proof cannot use Codex parser")
        check(!AgentSavedSession.matches(kind: .codex, sessionID: "codex-id", cwd: "/owned/project", rows: Array(codexConversation.prefix(1))), "Codex startup metadata alone denied")
        await rejects("unavailable persisted-session context does not authorize a stop") {
            try AgentSavedSession.verify(kind: .claude, sessionID: "actual-id", cwd: nil, configurationDirectory: "/owned/unavailable", process: process)
        }
        #endif
        try retryAndReuse(agent: agent, row: row)
        try await typedPiShim(client: client, transport: transport)
        try launchReadiness(row: row)
        try await runtimeLockWait()
        try await shellWait()
        try piLaunchSource()
        try await agentProxyLaunch()
        try agentProxySource()
        print("AGENT LAUNCH API/STATE PASS")
    }

    /// The agent proxy (SHPHRD-105): which launches ask it for a route, and
    /// what `prepare` is given and answers.
    static func agentProxyLaunch() async throws {
        typealias Policy = AgentProxyInjectionPolicy
        check(Policy.version(in: "2.1.288 (Claude Code)") == [2, 1, 288] && Policy.version(in: "codex-cli 0.162.0") == [0, 162, 0]
              && Policy.version(in: "1.4") == [1, 4, 0] && Policy.version(in: "Claude Code") == nil && Policy.version(in: nil) == nil,
              "a CLI's version is the first x.y[.z] it reports")
        for (kind, version, meets) in [(AgentKind.claude, "2.1.283 (Claude Code)", true), (.claude, "2.1.282 (Claude Code)", false), (.claude, "2.2.0", true),
                                       (.claude, "10.0.0", true), (.codex, "codex-cli 0.162.0", true), (.codex, "codex-cli 0.161.99", false),
                                       (.codex, "codex-cli 1.0.0", true), (.pi, "1.3.0", true), (.pi, "1.2.12", false), (.pi, "1.10.0", true)] {
            check(Policy.meetsMinimum(kind, version: version) == meets, "\(kind) \(version): \(meets ? "new enough" : "too old") for the proxy")
        }
        func skip(_ kind: AgentKind = .claude, _ version: String? = "2.1.290", on: Bool = true, thisMac: Bool = true, systemProxy: Bool = false,
                  rejected: Set<String> = []) -> Policy.Skip? {
            Policy.skip(kind: kind, cliVersion: version, settingOn: on, isThisMac: thisMac, systemProxyConfigured: systemProxy, rejectedKinds: rejected)
        }
        check(skip() == nil, "setting on, This Mac, new enough, no system proxy, not turned away: a route is asked for")
        check(skip(on: false, thisMac: false, systemProxy: true) == .settingOff, "the setting off is said first")
        check(skip(thisMac: false, systemProxy: true) == .notThisMac, "then another machine than This Mac")
        check(skip(.codex, "0.100.0", rejected: ["codex"]) == .oauthRejected && skip(.codex, "0.170.0", rejected: ["claude"]) == nil,
              "then the kind turned away for its sign-in, only that kind")
        check(skip(.pi, "1.2.0", systemProxy: true) == .cliVersion, "then a CLI too old")
        check(skip(systemProxy: true) == .systemProxy, "then a system HTTP proxy")

        // What prepare is given and answers.
        actor Scripts { var last = ""; func set(_ value: String) { last = value } }
        let scripts = Scripts()
        let answer = #"{"ok":true,"result":{"kind":"claude","executable":"claude","arguments":["--plugin-dir","/owned/plugin"],"environment":{},"outputFolder":"/o","sessionFolder":"/s","pluginDirectory":"/owned/plugin","mcpConfiguration":"/m","mcpArguments":[],"codexPluginKey":null,"injection":"plugin","apiProxy":{"injected":false,"reason":"custom-endpoint"}}}"#
        let runtime = AgentRuntime(root: "/owned/root", resourceDirectory: "/owned/resources", scriptRunner: { script in
            await scripts.set(script); return Data(answer.utf8)
        })
        let pane = AgentPaneIdentity(machineID: "m", herdrMachineID: nil, session: "default", paneID: "w1:p1", terminalID: "t1")
        let endpoint = AgentBrowserEndpoint(origin: "thisMac", url: "ws://127.0.0.1:1/v1/herdr/default/pane/w1:p1", tokenFile: "/owned/token")
        let base = "http://127.0.0.1:24680/p/" + String(repeating: "ab", count: 16)
        let plan = try await runtime.prepare(kind: .claude, executable: "claude", pane: pane, endpoint: endpoint, codexHome: "/owned/codex",
                                             claudeSettingsFile: "/owned/claude/settings.json", apiProxy: AgentAPIProxyRequest(baseURL: base), on: .thisMac)
        check(await scripts.last.contains(#""apiProxy":{"baseURL":"\#(base)"}"#), "prepare is given the base URL as apiProxy")
        check(plan.apiProxy == AgentAPIProxyPreparation(injected: false, reason: "custom-endpoint"), "prepare's answer says whether the agent goes through it, and why not")
        check(try plan.resuming(sessionID: "session-1").apiProxy == plan.apiProxy, "a resumed plan keeps that answer")
        _ = try await runtime.prepare(kind: .claude, executable: "claude", pane: pane, endpoint: endpoint, codexHome: "/owned/codex",
                                      claudeSettingsFile: "/owned/claude/settings.json", on: .thisMac)
        check(!(await scripts.last.contains("apiProxy")), "a launch not given the proxy sends no apiProxy")
        let plain = try JSONDecoder().decode(PreparedAgentLaunch.self, from: Data(#"{"kind":"codex","executable":"codex","arguments":[],"environment":{},"outputFolder":"/o","sessionFolder":"/s","pluginDirectory":"/p","mcpConfiguration":"/m","mcpArguments":[],"codexPluginKey":null,"injection":"codexConfigurationFallback"}"#.utf8))
        check(plain.apiProxy == nil, "a plan from an older runtime has no apiProxy")
        let stage = try JSONDecoder().decode(PiStagedLaunch.self, from: Data(#"{"id":"1","sessionID":"s","folder":"/owned/pi/1","manifest":"m","bootstrap":"b","cli":"c","node":"n","entry":"e","resources":"r","arguments":[],"environment":{},"cliVersion":"1.4.0"}"#.utf8))
        check(stage.cliVersion == "1.4.0", "the staged Pi's version reaches the launch")
    }

    /// Where the launches ask the proxy, in AgentLaunchService.swift and
    /// PiLaunchCoordinator.swift: once the pane is known, a route discarded
    /// unless the agent is asked to start, and never on a resume.
    static func agentProxySource() throws {
        let text = try String(contentsOfFile: "Shepherd/Agents/AgentLaunchService.swift", encoding: .utf8)
        func section(_ start: String, _ end: String, in text: String = text) -> Substring {
            guard let from = text.range(of: start), let to = text.range(of: end, range: from.upperBound..<text.endIndex) else {
                preconditionFailure("no \(start)")
            }
            return text[from.lowerBound..<to.lowerBound]
        }
        func order(_ section: Substring, _ parts: [String], _ name: String) {
            var at = section.startIndex
            for part in parts {
                guard let found = section.range(of: part, range: at..<section.endIndex) else { check(false, name + " (" + part + ")"); return }
                at = found.upperBound
            }
            check(true, name)
        }
        let launch = section("    func launch(kind: AgentKind,", "    private func launchPi(")
        order(launch, ["let resolved = try await waitForShell(created.pane, on: machine, client: client)",
                       "guard let endpoint = CDPProxy.shared.endpoint(for: resolved.key)",
                       "proxyRoute = await agentProxy?.route(for: kind, pane: pane, cliVersion: available.version, on: machine)",
                       "preparationAttempted = true",
                       "apiProxy: apiProxy, on: .thisMac)",
                       "if let route = proxyRoute, plan.apiProxy?.injected != true {", "await agentProxy?.discard(route)",
                       "_ = try await waitForShell(created.pane, on: machine, client: client)",
                       "startRequested = true", "if let proxyRoute { agentProxy?.started(proxyRoute) }",
                       "let result = try await client.agentStart(",
                       "} catch {", "if let proxyRoute, !startRequested { await agentProxy?.discard(proxyRoute) }"],
              "Claude Code and Codex: a route once the pane is known, given to prepare, discarded unless the agent is asked to start")
        let pi = section("    private func launchPi(", "    /// herdr's `agent.start` and Pi's typed command")
        order(pi, ["let cwd = try await waitForPiShell(created.pane, on: machine, client: client).cwd",
                   "proxyRoute = await agentProxy?.route(for: .pi, pane: pane, cliVersion: stage.cliVersion, on: machine)",
                   "apiProxyBaseURL: proxyRoute?.baseURL)", "try await coordinator.prepare()",
                   "startRequested = true", "if let proxyRoute { agentProxy?.started(proxyRoute) }",
                   "try await client.runCommand(paneID: pane.paneID, argv: [stage.shim] + stage.arguments)",
                   "} catch {", "if let proxyRoute, !startRequested { await agentProxy?.discard(proxyRoute) }"],
              "Pi: a route once its shell is settled, written for its extension, discarded unless its command is typed")
        let resume = section("    func resume(_ agent: AgentSummary,", "    private func resumeObservation(")
        check(!resume.contains("agentProxy") && !resume.contains("apiProxy"), "a resume never gives the agent the proxy")
        check(text.components(separatedBy: "agentProxy?.route(").count == 3, "only the launcher's two launches ask for a route")
        let coordinator = try String(contentsOfFile: "Shepherd/Agents/PiLaunchCoordinator.swift", encoding: .utf8)
        check(coordinator.contains(#"if let apiProxyBaseURL { manifest["apiProxy"] = ["baseURL": apiProxyBaseURL] }"#)
              && coordinator.contains("try PiBrowserLeaseProvider.write(manifest, to: URL(fileURLWithPath: stage.manifest))"),
              "Pi's launch.json has apiProxy only when the launch got a route")
        let app = try String(contentsOfFile: "Shepherd/Shepherd.swift", encoding: .utf8)
        check(app.contains("AgentLaunchService.shared.agentProxy = AgentProxyService.shared\n        AgentProxyService.shared.start()\n        guard ShepherdBrowserFeature.shared.isEnabled else { return }"),
              "the app hands the launches the proxy service, and starts it whether or not the browser is on")
    }

    /// Where Pi's launch takes the wait above, in AgentLaunchService.swift
    /// (read from the repository root the stage runs in): the folder from the
    /// settled shell, and nothing more asked of herdr about the shell before
    /// the second wait, which the shim is typed after.
    static func piLaunchSource() throws {
        let text = try String(contentsOfFile: "Shepherd/Agents/AgentLaunchService.swift", encoding: .utf8)
        func section(_ start: String, _ end: String) -> Substring {
            guard let from = text.range(of: start), let to = text.range(of: end, range: from.upperBound..<text.endIndex) else {
                preconditionFailure("AgentLaunchService.swift has no \(start)")
            }
            return text[from.lowerBound..<to.lowerBound]
        }
        let pi = section("    private func launchPi(", "    /// herdr's `agent.start` and Pi's typed command")
        check(pi.contains("let cwd = try await waitForPiShell(created.pane, on: machine, client: client).cwd"), "Pi's launch takes the folder the settled shell wait read")
        for gone in ["processInfo(", "isShellForeground", "PiBridgeFailure.identity", "PiProcessIdentity.capture"] {
            check(!pi.contains(gone), "Pi's launch no longer has \(gone) of its own")
        }
        let second = pi.range(of: "_ = try await waitForShell(created.pane, on: machine, client: client)")
        check(pi.components(separatedBy: "waitForShell(created.pane, on: machine, client: client)").count == 2, "Pi's launch keeps one plain wait for the shell")
        if let second, let prepared = pi.range(of: "try await coordinator.prepare()"), let typed = pi.range(of: "try await client.runCommand(paneID: pane.paneID") {
            check(prepared.upperBound <= second.lowerBound && second.upperBound <= typed.lowerBound, "the plain wait is after the bridge is prepared and before the shim is typed")
        } else { preconditionFailure("Pi's launch has no prepare, plain wait and typed shim") }
        let waits = section("    /// The new pane's shell, alone in its foreground (`AgentShellWait`).", "    func status(for agent:")
        check(waits.contains("try await AgentShellWait.shell {") && waits.contains("try await AgentShellWait.settledShell(")
              && waits.contains("PiProcessIdentity.capture(pid: $0).cwd") && waits.contains("try await AgentShellWait.look(at: expected"),
              "the service's waits are AgentShellWait's, Pi's reading the folder by the shell's PID")
    }

    /// The wait for a new pane's shell (`AgentShellWait`) over a fake herdr
    /// and a clock only the waits move: Claude Code's and Codex's first look
    /// that finds the shell alone, and Pi's two in a row in the same folder,
    /// whatever the startup files put in the foreground in between.
    static func shellWait() async throws {
        typealias Wait = AgentShellWait
        check(Wait.interval == .milliseconds(200) && Wait.limit == .seconds(10) && Wait.settle == .milliseconds(400),
              "looks every 200 ms for up to 10 s; Pi's two looks 400 ms apart")
        let pane = try json(#"{"pane_id":"w1:p1","terminal_id":"term_new"}"#)
        let expected = AgentSummary(json: pane)!
        let project = "/Users/owned/project"
        struct Outcome {
            var result: Result<(pid: UInt32, cwd: String?), Error>
            var looks = 0, processReads = 0, cwdReads = 0, accepted = 0
            var slept: [Duration] = []
            var code: String? {
                guard case .failure(AgentRuntimeError.rejected(let code)) = result else { return nil }
                return code
            }
            var shell: (pid: UInt32, cwd: String?)? { try? result.get() }
        }
        /// One wait over `steps`, Pi's when `cwds` gives the folder each read
        /// of it finds (the last one repeated; nil for one it can't read).
        func waitFor(_ steps: [(shell: UInt32, child: Bool)], cwds: [String?]? = nil, pane: JSONValue = pane,
                  agents: [JSONValue] = [], resolvable: Bool = true) async -> Outcome {
            let transport = ShellStartTransport(pane: pane, steps: steps, agents: agents), client = HerdrClient(transport: transport)
            var clock = ContinuousClock().now, outcome = Outcome(result: .failure(CancellationError()))
            let sleep: (Duration) async throws -> Void = { outcome.slept.append($0); clock = clock.advanced(by: $0) }
            let now = { clock }
            let look = { () async throws -> Wait.Shell<String>? in
                outcome.looks += 1
                return try await Wait.look(at: expected, client: client, accept: { _ in outcome.accepted += 1 },
                                           resolve: { resolvable ? $0.paneID : nil })
            }
            do {
                if let cwds {
                    let settled = try await Wait.settledShell(sleep: sleep, now: now, look: look, cwd: { _ in
                        defer { outcome.cwdReads += 1 }
                        return cwds[min(outcome.cwdReads, cwds.count - 1)]
                    })
                    check(settled.shell.resolved == "w1:p1", "the settled shell is the created pane's")
                    outcome.result = .success((settled.shell.pid, settled.cwd))
                } else {
                    let shell = try await Wait.shell(sleep: sleep, now: now, look: look)
                    outcome.result = .success((shell.pid, nil))
                }
            } catch { outcome.result = .failure(error) }
            outcome.processReads = await transport.processReads
            return outcome
        }
        let alone = (shell: UInt32(100), child: false), withChild = (shell: UInt32(100), child: true)
        let ms200 = Duration.milliseconds(200), ms400 = Duration.milliseconds(400)

        // SHPHRD-109: the startup files' children come and go; Pi's launch waits them out, never failing for one.
        let flapping = await waitFor([withChild, alone, withChild, alone, alone], cwds: [project])
        check(flapping.shell?.pid == 100 && flapping.shell?.cwd == project, "a child between two looks at the shell alone is waited out, not an identity failure")
        check(flapping.looks == 5 && flapping.processReads == 5 && flapping.slept == [ms200, ms400, ms200, ms400],
              "the shell is taken at the second of two looks in a row, 400 ms apart, and herdr is asked nothing after it")
        check(flapping.accepted == 5, "every snapshot read goes to the browser service")
        check(flapping.cwdReads == 3, "the folder is read at each look that finds the shell alone")

        // The shell alone once, then a child: not taken.
        let once = await waitFor([alone, withChild], cwds: [project])
        check(once.code == "pi-shell-not-ready" && once.cwdReads == 1, "the shell seen alone once and then not is never taken")
        check(once.looks == 49 && once.slept.first == ms400 && once.slept.dropFirst().allSatisfy { $0 == ms200 } && once.slept.reduce(.zero, +) == .seconds(10),
              "the wait looks again every 200 ms after it and gives up after 10 s")
        let onceThenSettled = await waitFor([alone, withChild, alone, alone], cwds: [project])
        check(onceThenSettled.shell?.cwd == project && onceThenSettled.looks == 4, "a look at the shell alone before a child does not count toward the two")

        // Seen alone at every other look until the end: never two in a row.
        let alternating = await waitFor(Array(repeating: [alone, withChild], count: 40).flatMap { $0 }, cwds: [project])
        check(alternating.code == "pi-shell-not-ready", "a shell never seen alone twice in a row fails with pi-shell-not-ready after 10 s")
        check(alternating.slept.reduce(.zero, +) >= .seconds(10) && alternating.looks == 33, "alternating looks wait 400 ms and 200 ms in turn")
        let busy = await waitFor([withChild], cwds: [project])
        check(busy.code == "pi-shell-not-ready" && busy.looks == 50 && busy.cwdReads == 0, "a child in the foreground for 10 s fails with pi-shell-not-ready")

        // The startup files change folder between two looks: the folder after it.
        let moved = await waitFor([alone, alone, alone], cwds: ["/Users/owned", project])
        check(moved.shell?.cwd == project && moved.looks == 3 && moved.slept == [ms400, ms400], "a folder changed between two looks is waited on again")
        let moving = await waitFor([alone], cwds: ["/a", "/b", "/c", "/d", "/e", "/f", "/g", "/h", "/i", "/j", "/k", "/l", "/m", "/n", "/o", "/p", "/q", "/r", "/s", "/t", "/u", "/v", "/w", "/x", "/y", "/z"])
        check(moving.code == "pi-shell-not-ready", "a folder that changes at every look is never taken")

        // Another shell: the two looks must find the same one.
        let replaced = await waitFor([alone, (shell: 101, child: false), (shell: 101, child: false)], cwds: [project])
        check(replaced.shell?.pid == 101 && replaced.looks == 3, "a shell PID that changed between two looks is waited on again")
        // A folder the kernel didn't give: a look that didn't find the shell.
        let unreadable = await waitFor([alone, alone, alone], cwds: [nil, project])
        check(unreadable.shell?.cwd == project && unreadable.looks == 3 && unreadable.slept == [ms200, ms400], "an unreadable folder counts as no look at the shell")

        // Nothing changes for a look: an agent, a pane not resolvable, another pane in the terminal's place.
        let agentRow = try json(#"{"pane_id":"w1:p1","terminal_id":"term_new","agent":"pi","agent_status":"idle"}"#)
        let withAgent = await waitFor([alone], cwds: [project], agents: [agentRow])
        check(withAgent.code == "pi-shell-not-ready" && withAgent.processReads == 0, "an agent row in the terminal is no shell")
        let unresolved = await waitFor([alone], cwds: [project], resolvable: false)
        check(unresolved.code == "pi-shell-not-ready" && unresolved.cwdReads == 0, "a pane the browser service can't place is not taken")
        let movedPane = await waitFor([alone], cwds: [project], pane: try json(#"{"pane_id":"w1:p2","terminal_id":"term_new"}"#))
        check(movedPane.code == "created-pane-identity-changed" && movedPane.looks == 1, "another pane in the terminal's place fails at once, as before")

        // Claude Code and Codex: the first look that finds the shell alone, as before.
        let first = await waitFor([withChild, alone, withChild])
        check(first.shell?.pid == 100 && first.looks == 2 && first.slept == [ms200], "Claude Code and Codex take the first look at the shell alone")
        let timeout = await waitFor([withChild])
        check(timeout.code == "shell-readiness-timeout" && timeout.looks == 50 && timeout.slept.reduce(.zero, +) == .seconds(10),
              "Claude Code's and Codex's wait still fails with shell-readiness-timeout after 10 s")
    }

    /// A launch's runtime calls wait out the browser check's hold on the
    /// runtime lock (`AgentRuntimeLockWait`): setup-busy only, every 100 ms,
    /// for up to 5 s.
    static func runtimeLockWait() async throws {
        typealias Wait = AgentRuntimeLockWait
        let busy = AgentRuntimeError.rejected("setup-busy")
        check(Wait.interval == .milliseconds(100) && Wait.limit == .seconds(5), "waits every 100 ms for up to 5 s")
        /// A call refused `times` times, then failing with `failure` or
        /// succeeding, each taking `cost`, on a clock only the call and the
        /// waits move.
        func attempt(busy times: Int, then failure: Error? = nil, cost: Duration = .zero) async -> (result: Result<String, Error>, calls: Int, slept: [Duration]) {
            var clock = ContinuousClock().now, slept: [Duration] = [], calls = 0
            do {
                let value = try await Wait.run(sleep: { slept.append($0); clock = clock.advanced(by: $0) }, now: { clock }) {
                    calls += 1; clock = clock.advanced(by: cost)
                    if calls <= times { throw busy }
                    if let failure { throw failure }
                    return "prepared"
                }
                return (.success(value), calls, slept)
            } catch { return (.failure(error), calls, slept) }
        }
        func code(_ result: Result<String, Error>) -> String? {
            guard case .failure(AgentRuntimeError.rejected(let code)) = result else { return nil }
            return code
        }
        func transportFailure(_ result: Result<String, Error>) -> Bool {
            guard case .failure(let error) = result else { return false }
            return error is HostScriptError
        }

        let free = await attempt(busy: 0)
        check(free.calls == 1 && free.slept.isEmpty && (try? free.result.get()) == "prepared", "a free lock is not waited for")
        let twice = await attempt(busy: 2)
        check(twice.calls == 3 && twice.slept == [.milliseconds(100), .milliseconds(100)] && (try? twice.result.get()) == "prepared",
              "setup-busy twice: the third call succeeds after two 100 ms waits")
        let held = await attempt(busy: .max)
        check(code(held.result) == "setup-busy" && held.calls == 51 && held.slept.count == 50 && held.slept.reduce(.zero, +) == .seconds(5),
              "a lock held throughout fails with setup-busy once 5 s have passed")
        let slow = await attempt(busy: .max, cost: .seconds(1))
        check(code(slow.result) == "setup-busy" && slow.calls == 5 && slow.slept.count == 4, "the calls' own time counts toward the 5 s")
        let missing = await attempt(busy: 0, then: AgentRuntimeError.rejected("cli-missing"))
        check(code(missing.result) == "cli-missing" && missing.calls == 1 && missing.slept.isEmpty, "cli-missing fails at once")
        let lockFailed = await attempt(busy: 0, then: AgentRuntimeError.rejected("runtime-lock-failed"))
        check(code(lockFailed.result) == "runtime-lock-failed" && lockFailed.calls == 1 && lockFailed.slept.isEmpty,
              "runtime-lock-failed fails at once without another try")
        let transport = await attempt(busy: 0, then: HostScriptError(status: 1, message: "transport"))
        check(transportFailure(transport.result) && transport.calls == 1 && transport.slept.isEmpty, "a script failure fails at once")
        let afterBusy = await attempt(busy: 1, then: AgentRuntimeError.rejected("cli-missing"))
        check(code(afterBusy.result) == "cli-missing" && afterBusy.calls == 2 && afterBusy.slept.count == 1, "another failure after a wait fails at once")

        var cancelledCalls = 0
        do {
            try await Wait.run(sleep: { _ in throw CancellationError() }) { () async throws -> Void in cancelledCalls += 1; throw busy }
            preconditionFailure("a cancelled wait went on")
        } catch is CancellationError { check(cancelledCalls == 1, "a cancelled wait throws its cancellation and calls no more") }
        let started = ContinuousClock().now
        let task = Task { try await Wait.run { () async throws -> Void in throw busy } }
        task.cancel()
        do { try await task.value; preconditionFailure("a cancelled task's wait went on") }
        catch is CancellationError { check(started.duration(to: ContinuousClock().now) < .seconds(1), "cancelling the task ends Task.sleep's wait at once") }
    }

    /// When a launch takes the agent it started for ready: before the
    /// launcher has handed the tab off, and after, when the user may have
    /// sent a prompt already (`AgentLaunchReadiness`).
    static func launchReadiness(row: JSONValue) throws {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        func agent(_ changes: [String: Any], removing: [String] = []) throws -> AgentSummary {
            var value = base.merging(changes) { _, new in new }
            for key in removing { value.removeValue(forKey: key) }
            return AgentSummary(json: try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value)))!
        }
        func ready(_ row: AgentSummary, _ kind: AgentKind, handedOff: Bool, pane: String = "w1:p1", terminal: String = "term_owned") -> Bool {
            AgentLaunchReadiness.isReady(row, kind: kind, paneID: pane, terminalID: terminal, handedOff: handedOff)
        }
        let both = [false, true]

        // Pi is typed in by Shepherd: herdr gives it no interactive_ready, and its idle state is read instead.
        func pi(_ state: String, _ changes: [String: Any] = [:]) throws -> AgentSummary {
            try agent(["agent": "pi", "agent_status": state].merging(changes) { _, new in new },
                      removing: ["interactive_ready", "launch_pending"].filter { changes[$0] == nil })
        }
        for state in ["idle", "done"] {
            for handedOff in both {
                check(ready(try pi(state), .pi, handedOff: handedOff), "Pi \(state) is ready (handed off: \(handedOff))")
                check(ready(try pi(state, ["interactive_ready": false]), .pi, handedOff: handedOff), "Pi \(state) needs no interactive_ready (handed off: \(handedOff))")
                check(!ready(try pi(state, ["launch_pending": true]), .pi, handedOff: handedOff), "Pi \(state) with launch_pending is not ready (handed off: \(handedOff))")
            }
        }
        check(!ready(try pi("working"), .pi, handedOff: false), "Pi working before the hand-off is not ready")
        check(ready(try pi("working"), .pi, handedOff: true), "Pi working after the hand-off is ready")
        for state in ["blocked", "unknown"] {
            for handedOff in both {
                check(!ready(try pi(state), .pi, handedOff: handedOff), "Pi \(state) is not ready (handed off: \(handedOff))")
            }
        }

        // Claude Code and Codex are started by herdr, which marks interactive_ready and launch_pending.
        for (kind, name) in [(AgentKind.claude, "claude-code"), (.claude, "claude"), (.codex, "codex")] {
            func started(_ state: String, ready interactive: Any?, pending: Any?) throws -> AgentSummary {
                var changes: [String: Any] = ["agent": name, "agent_status": state], removing: [String] = []
                if let interactive { changes["interactive_ready"] = interactive } else { removing.append("interactive_ready") }
                if let pending { changes["launch_pending"] = pending } else { removing.append("launch_pending") }
                return try agent(changes, removing: removing)
            }
            for handedOff in both {
                check(ready(try started("idle", ready: true, pending: false), kind, handedOff: handedOff), "\(name) interactive_ready without launch_pending is ready (handed off: \(handedOff))")
                check(ready(try started("idle", ready: true, pending: nil), kind, handedOff: handedOff), "\(name) interactive_ready with no launch_pending field is ready (handed off: \(handedOff))")
                check(!ready(try started("idle", ready: true, pending: true), kind, handedOff: handedOff), "\(name) idle with launch_pending is not ready (handed off: \(handedOff))")
                check(!ready(try started("idle", ready: false, pending: false), kind, handedOff: handedOff), "\(name) idle without interactive_ready is not ready (handed off: \(handedOff))")
                check(!ready(try started("idle", ready: nil, pending: nil), kind, handedOff: handedOff), "\(name) idle with no readiness fields is not ready (handed off: \(handedOff))")
                // Blocked and unknown stay as they were: herdr's readiness alone decides.
                for state in ["blocked", "unknown"] {
                    check(ready(try started(state, ready: true, pending: false), kind, handedOff: handedOff), "\(name) \(state) with interactive_ready is ready as before (handed off: \(handedOff))")
                    check(!ready(try started(state, ready: false, pending: true), kind, handedOff: handedOff), "\(name) \(state) still launching is not ready (handed off: \(handedOff))")
                    check(!ready(try started(state, ready: nil, pending: nil), kind, handedOff: handedOff), "\(name) \(state) with no readiness fields is not ready (handed off: \(handedOff))")
                }
            }
            // Working with launch_pending still set: herdr has not seen it idle.
            for (interactive, pending) in [(false as Any?, true as Any?), (nil, true), (true, true), (false, false), (nil, nil)] {
                let working = try started("working", ready: interactive, pending: pending)
                let fields = "interactive_ready \(interactive.map { "\($0)" } ?? "absent"), launch_pending \(pending.map { "\($0)" } ?? "absent")"
                check(!ready(working, kind, handedOff: false), "\(name) working before the hand-off is not ready (\(fields))")
                check(ready(working, kind, handedOff: true), "\(name) working after the hand-off is ready (\(fields))")
            }
        }

        // Only the row of the launched kind, in the same pane and terminal.
        let claude = try agent(["agent": "claude-code", "agent_status": "working"])
        let idleClaude = try agent([:]), idlePi = try pi("idle")
        for handedOff in both {
            check(ready(idleClaude, .claude, handedOff: handedOff), "the launched Claude row is ready (handed off: \(handedOff))")
            check(!ready(idleClaude, .codex, handedOff: handedOff) && !ready(idleClaude, .pi, handedOff: handedOff), "another kind's row is refused (handed off: \(handedOff))")
            check(!ready(idlePi, .claude, handedOff: handedOff) && !ready(idlePi, .codex, handedOff: handedOff), "Pi's row is not Claude's or Codex's (handed off: \(handedOff))")
            check(!ready(try agent(["agent": "unrecognized"]), .claude, handedOff: handedOff), "an unrecognized agent is refused (handed off: \(handedOff))")
            check(!ready(try agent([:], removing: ["agent"]), .claude, handedOff: handedOff), "a row with no agent is refused (handed off: \(handedOff))")
            for row in [idleClaude, claude] {
                check(!ready(row, .claude, handedOff: handedOff, pane: "w1:p2"), "another pane is refused (handed off: \(handedOff))")
                check(!ready(row, .claude, handedOff: handedOff, terminal: "term_other"), "another terminal in the same pane is refused (handed off: \(handedOff))")
            }
            check(!ready(try pi("working"), .pi, handedOff: handedOff, terminal: "term_other"), "Pi in another terminal is refused (handed off: \(handedOff))")
        }
        check(ready(claude, .claude, handedOff: true) && !ready(claude, .codex, handedOff: true), "a working row after the hand-off is still only its own kind's")
    }

    /// Pi's shim by its absolute path (`launchPi`): typed as `herdr pane run`
    /// types, every word quoted, Enter in the same request.
    static func typedPiShim(client: HerdrClient, transport: LaunchTransport) async throws {
        let shim = "/Users/owned/Library/Application Support/Shepherd/pi/1/bin/pi"
        check(try HerdrClient.commandLine([shim, "--session-dir", "/a b/sessions", "it's"]) == "'\(shim)' '--session-dir' '/a b/sessions' 'it'\\''s'",
              "a command line keeps spaces and quotes inside their words")
        for argv in [[], [""], ["pi", "a\nb"], ["pi", "tab\there"], ["pi", "\u{1b}[200~"]] {
            do { _ = try HerdrClient.commandLine(argv); preconditionFailure("accepted \(argv)") }
            catch { print("PASS: \(argv.debugDescription) is refused before anything is typed") }
        }
        await transport.configure(.object(["type": .string("ok")]))
        try await client.runCommand(paneID: "w1:p1", argv: [shim, "--extension", "/owned/pi-entry.ts"])
        let typed = await transport.lastRequest()!
        check(typed.0 == "pane.send_input" && typed.1["pane_id"]?.stringValue == "w1:p1" && typed.1["keys"]?.arrayValue?.map { $0.stringValue } == ["enter"]
              && typed.1["text"]?.stringValue == "'\(shim)' '--extension' '/owned/pi-entry.ts'", "exact pane.send_input wire params")
        await transport.configure(.object(["type": .string("agent_started")]))
        await rejects("a typed command without herdr's ok rejected") { try await client.runCommand(paneID: "w1:p1", argv: [shim]) }
        let stage = try JSONDecoder().decode(PiStagedLaunch.self, from: Data(#"{"id":"1","sessionID":"s","folder":"/owned/pi/1","manifest":"m","bootstrap":"b","cli":"c","node":"n","entry":"e","resources":"r","arguments":[],"environment":{}}"#.utf8))
        check(stage.shim == "/owned/pi/1/bin/pi", "the staged shim is the stage folder's bin/pi")
    }

    /// The browser check's waits after failed preparations, and its reuse of
    /// process information for unchanged agent panes.
    static func retryAndReuse(agent: AgentSummary, row: JSONValue) throws {
        typealias Preparation = AgentDirectPreparation
        let start = ContinuousClock().now
        let argv = ["claude"], other = ["claude", "--model", "opus"]
        let failure = AgentRuntimeError.rejected("cli-missing")
        check([1, 2, 3, 4, 5, 6, 12].map(Preparation.delay(attempts:)) == [30, 60, 120, 240, 300, 300, 300].map { Duration.seconds($0) },
              "waits 30, 60, 120, 240 s, then 5 minutes")
        let first = Preparation.nextRetry(after: nil, argv: argv, error: failure, message: "failed", now: start)!
        check(first.attempts == 1 && first.notBefore == start + .seconds(30) && first.message == "failed", "first failure waits 30 s and keeps its message")
        check(!Preparation.shouldPrepare(argv, rejected: nil, retry: first, now: start + .seconds(29)), "same argv waits")
        check(Preparation.shouldPrepare(argv, rejected: nil, retry: first, now: start + .seconds(30)), "same argv tried again after the wait")
        check(Preparation.shouldPrepare(other, rejected: nil, retry: first, now: start), "different argv tried at once")
        check(Preparation.isWaiting(first, argv: argv, now: start) && !Preparation.isWaiting(first, argv: other, now: start), "waiting is per argv")
        var retry = first
        for seconds in [60, 120, 240, 300, 300] {
            let at = retry.notBefore
            retry = Preparation.nextRetry(after: retry, argv: argv, error: failure, message: "failed", now: at)!
            check(retry.notBefore == at + .seconds(seconds), "failure \(retry.attempts) waits \(seconds) s")
        }
        let restarted = Preparation.nextRetry(after: retry, argv: other, error: failure, message: "other", now: start)!
        check(restarted.attempts == 1 && restarted.notBefore == start + .seconds(30), "a different argv starts again at 30 s")
        let busy = AgentRuntimeError.rejected("setup-busy")
        check(Preparation.nextRetry(after: nil, argv: argv, error: busy, message: "busy", now: start) == nil, "setup-busy does not wait")
        let expired = Preparation.nextRetry(after: first, argv: argv, error: busy, message: "busy", now: first.notBefore)
        check(expired == first && Preparation.shouldPrepare(argv, rejected: nil, retry: expired, now: first.notBefore), "setup-busy keeps the count and no new wait")
        check(Preparation.nextRetry(after: first, argv: other, error: busy, message: "busy", now: start) == nil, "setup-busy for different argv forgets the old wait")
        let lockFailed = AgentRuntimeError.rejected("runtime-lock-failed")
        let unlocked = Preparation.nextRetry(after: nil, argv: argv, error: lockFailed, message: "lock", now: start)
        check(unlocked?.attempts == 1 && unlocked?.notBefore == start + .seconds(30) && !Preparation.isQuiet(lockFailed),
              "runtime-lock-failed waits 30 s like any other failure")
        check(!Preparation.shouldPrepare(argv, rejected: argv, retry: nil, now: start) && Preparation.isQuiet(AgentRuntimeError.rejected("duplicate-registration")),
              "quiet rejection is remembered per argv as before")
        let registration = Preparation.nextRetry(after: nil, argv: nil, error: HostScriptError(status: 1, message: "transport"), message: "register", now: start)!
        check(Preparation.isWaiting(registration, argv: nil, now: start + .seconds(29)) && !Preparation.isWaiting(registration, argv: nil, now: start + .seconds(30)),
              "a failed registration waits too")

        // Reuse only for an agent pane whose pane and agent.list row are unchanged.
        typealias Reuse = AgentInspectionReuse
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        func summary(_ changes: [String: Any]) throws -> AgentSummary {
            AgentSummary(json: try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new })))!
        }
        let pane = try summary(["revision": 4])
        check(Reuse.canReuse(pane: pane, row: agent, previousPane: pane, previousRow: agent, processAge: .seconds(2)), "unchanged agent pane reuses its processes")
        check(!Reuse.canReuse(pane: pane, row: agent, previousPane: pane, previousRow: agent, processAge: Reuse.maximumAge), "30 s old processes are read again")
        check(!Reuse.canReuse(pane: pane, row: agent, previousPane: pane, previousRow: agent, processAge: nil), "never read is read")
        for (key, value) in [("agent_status", "working" as Any), ("state_change_seq", 4), ("interactive_ready", false), ("terminal_id", "replaced"),
                             ("launch_pending", true), ("agent_session", ["source": "hook", "agent": "claude", "kind": "id", "value": "next"])] {
            check(!Reuse.canReuse(pane: pane, row: try summary([key: value]), previousPane: pane, previousRow: agent, processAge: .seconds(2)), "changed row \(key) is read again")
        }
        check(!Reuse.canReuse(pane: try summary(["revision": 5]), row: agent, previousPane: pane, previousRow: agent, processAge: .seconds(2)), "changed snapshot pane is read again")
        let shell = AgentSummary(json: try json("{\"pane_id\":\"w1:p2\",\"terminal_id\":\"term_shell\",\"revision\":1}"))!
        check(!Reuse.canReuse(pane: shell, row: nil, previousPane: shell, previousRow: nil, processAge: .seconds(1)), "pane with no agent is always read")
        check(!Reuse.canReuse(pane: shell, row: shell, previousPane: shell, previousRow: shell, processAge: .seconds(1)), "row with no agent is always read")
        check(!Reuse.canReuse(pane: pane, row: agent, previousPane: pane, previousRow: nil, processAge: .seconds(1)), "a row that just appeared is read")

        // The basename no longer goes through URL (and getcwd).
        for name in ["claude", "/a/b/claude", "./claude", "../bin/claude", "/a/claude/"] {
            check(PaneProcessInfo.commandName(name) == URL(fileURLWithPath: name).lastPathComponent, "\(name) names the same command")
        }
        check(PaneProcessInfo.commandName("") == "", "empty argv0 names nothing, not the current folder")
        for name in ["claude", "/a/b/claude", "./claude"] {
            let info = try JSONDecoder().decode(PaneProcessInfo.self, from: JSONSerialization.data(withJSONObject: ["pane_id": "w1:p1",
                "foreground_processes": [["pid": 2, "name": "node", "argv0": name, "argv": [name, "--resume"]]]]))
            check(info.agentArguments(for: .claude) == [name, "--resume"] && info.agentArguments(for: .codex) == nil, "\(name) found by argv0")
        }
    }
}
