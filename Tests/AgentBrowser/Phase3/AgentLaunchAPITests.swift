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
    func events() -> AsyncStream<JSONValue> { AsyncStream { $0.finish() } }
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
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: false, mode: .plugin, fresh: true) == .missingInjection, "actual uninjected foreground argv classified missing")
        check(AgentBrowserStatus.inspect(agent: agent, process: nullInfo, prepared: plan, socketConnected: false, mode: .plugin, fresh: true) == .unknown, "null argv classified unknown")
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: false, mode: .global, fresh: true) == .unknown, "global argv is not proof of missing injection")
        check(AgentBrowserStatus.inspect(agent: agent, process: nullInfo, prepared: nil, socketConnected: true, mode: .global, fresh: true) == .connected, "global live socket is actual connection authority")
        check(AgentBrowserStatus.inspect(agent: agent, process: process, prepared: plan, socketConnected: true, mode: .plugin, fresh: false) == .unknown, "stale inspection is never healthy")
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
        print("AGENT LAUNCH API/STATE PASS")
    }
}
