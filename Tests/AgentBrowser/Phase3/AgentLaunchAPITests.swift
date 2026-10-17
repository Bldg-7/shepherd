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
        print("AGENT LAUNCH API/STATE PASS")
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
