import Foundation

/// Typed convenience wrapper around a `HerdrTransport`. UI code should talk
/// to this, not to the transport or raw JSON, directly.
public actor HerdrClient {
    private let transport: HerdrTransport

    public init(transport: HerdrTransport) {
        self.transport = transport
    }

    public func connect() async throws {
        try await transport.connect()
    }

    public func disconnect() async {
        await transport.disconnect()
    }

    /// Every pane in the host's herdr — those with an agent in them and
    /// those without alike.
    public func listPanes() async throws -> [AgentSummary] {
        let result = try await transport.send(method: "pane.list", params: .object([:]))
        return try validatedPanes(result["panes"]?.arrayValue)
    }

    /// Set once the host's herdr has turned `session.snapshot` down, so the
    /// requests after that go straight to `pane.list`.
    private var snapshotUnsupported = false

    /// The host's panes, tabs and workspaces, from one `session.snapshot`. A
    /// herdr older than 0.7.2 doesn't have it and answers with an error; from
    /// one of those this falls back to `pane.list`, and has only panes to
    /// give.
    public func snapshot() async throws -> HerdrSnapshot {
        if !snapshotUnsupported {
            do {
                let result = try await transport.send(method: "session.snapshot", params: .object([:]))
                guard let snapshot = result["snapshot"] else { throw SnapshotSchemaError.invalidPaneIdentities }
                _ = try validatedPanes(snapshot["panes"]?.arrayValue)
                return HerdrSnapshot(snapshot: snapshot)
            } catch is HerdrErrorPayload {
                snapshotUnsupported = true
            }
        }
        return HerdrSnapshot(panes: try await listPanes())
    }

    /// The machines saved in herdr on the host, enabled ones only — a
    /// disabled machine is one herdr itself won't talk to.
    public func listHerdrMachines() async throws -> [HerdrMachine] {
        try await listAllHerdrMachines().filter(\.enabled)
    }

    /// Every machine saved in herdr on the host, the disabled ones too:
    /// what a new machine's label must not clash with, since herdr's
    /// `--machine <label>` takes a label shared by two for ambiguous whether
    /// or not one of them is switched off.
    public func listAllHerdrMachines() async throws -> [HerdrMachine] {
        let output = try await transport.runHerdr(["machine", "list", "--json"])
        return try JSONDecoder().decode([HerdrMachine].self, from: output)
    }

    /// The panes, tabs and workspaces on one of the host's herdr machines,
    /// fetched by the host's herdr CLI (`herdr --machine <id> api snapshot`,
    /// which is `session.snapshot`), which carries the request over its own
    /// SSH connection to that machine. The CLI prints the same response the
    /// socket API gives. herdr machines came in herdr 0.9, long after
    /// `session.snapshot`, so there is no older herdr to fall back for.
    public func snapshot(on machine: HerdrMachine) async throws -> HerdrSnapshot {
        let output = try await transport.runHerdr(["--machine", machine.id, "api", "snapshot"])
        let response = try JSONDecoder().decode(JSONValue.self, from: output)
        guard let snapshot = response["result"]?["snapshot"] else { throw SnapshotSchemaError.invalidPaneIdentities }
        _ = try validatedPanes(snapshot["panes"]?.arrayValue)
        return HerdrSnapshot(snapshot: snapshot, on: machine)
    }

    /// Missing/malformed pane identities are not evidence of disappearance.
    /// A browser owner must never reconcile a silently compact-mapped list.
    private func validatedPanes(_ rows: [JSONValue]?) throws -> [AgentSummary] {
        guard let rows else { throw SnapshotSchemaError.invalidPaneIdentities }
        let panes = rows.compactMap { AgentSummary(json: $0) }
        guard panes.count == rows.count, Set(panes.map(\.paneID)).count == panes.count,
              Set(panes.map(\.terminalID)).count == panes.count else { throw SnapshotSchemaError.invalidPaneIdentities }
        return panes
    }

    public enum SnapshotSchemaError: Error, LocalizedError {
        case invalidPaneIdentities
        public var errorDescription: String? { "herdr returned an incomplete pane snapshot; previous browser ownership was retained." }
    }

    /// Gives a tab the name herdr shows for it. herdr takes any name as it
    /// is, an empty one included, so it is up to the caller not to send one.
    public func renameTab(_ tabID: String, to label: String, on machine: HerdrMachine?) async throws {
        try await request(
            method: "tab.rename",
            params: ["tab_id": .string(tabID), "label": .string(label)],
            cli: ["tab", "rename", tabID, label],
            on: machine
        )
    }

    /// Closes a tab, and with it every pane in it and whatever runs there.
    public func closeTab(_ tabID: String, on machine: HerdrMachine?) async throws {
        try await request(method: "tab.close", params: ["tab_id": .string(tabID)], cli: ["tab", "close", tabID], on: machine)
    }

    /// Gives a pane a name of its own, or — with nil — takes it away again,
    /// so that the pane goes back to being called by its terminal's title.
    public func renamePane(_ paneID: String, to label: String?, on machine: HerdrMachine?) async throws {
        try await request(
            method: "pane.rename",
            params: ["pane_id": .string(paneID), "label": label.map(JSONValue.string) ?? .null],
            cli: ["pane", "rename", paneID] + [label ?? "--clear"],
            on: machine
        )
    }

    /// Closes a pane, ending whatever runs in it.
    public func closePane(_ paneID: String, on machine: HerdrMachine?) async throws {
        try await request(method: "pane.close", params: ["pane_id": .string(paneID)], cli: ["pane", "close", paneID], on: machine)
    }

    /// Makes a tab herdr's current one, which herdr takes for the tab having
    /// been looked at: every finished agent in it goes from done to idle.
    /// herdr's own view moves to the tab too, with the same pane in it
    /// focused as before, and stays in whatever mode it was in.
    public func focusTab(_ tabID: String, on machine: HerdrMachine?) async throws {
        try await request(method: "tab.focus", params: ["tab_id": .string(tabID)], cli: ["tab", "focus", tabID], on: machine)
    }

    /// A tab just made, and the one pane it starts out with.
    public nonisolated struct CreatedTab: Sendable {
        public let tab: TabSummary
        public let pane: AgentSummary
    }

    /// Opens a new tab — and with it a new pane — in a workspace, without
    /// moving herdr's own view there. Its working directory is herdr's to
    /// pick: by default it follows the workspace's focused pane. Without a
    /// label herdr numbers the tab.
    public func createTab(inWorkspace workspaceID: String, label: String?, on machine: HerdrMachine?, environment: [String: String] = [:]) async throws -> CreatedTab {
        let result = try await createRequest(
            method: "tab.create",
            params: ["workspace_id": .string(workspaceID), "label": label.map(JSONValue.string) ?? .null, "focus": .bool(false), "env": .object(environment.mapValues(JSONValue.string))],
            cli: ["tab", "create", "--workspace", workspaceID, "--no-focus"] + (label.map { ["--label", $0] } ?? []) + Self.environmentArguments(environment),
            on: machine
        )
        return try Self.createdTab(from: result, on: machine)
    }

    /// Opens a new workspace, which comes with a tab and a pane of its own,
    /// without moving herdr's own view there. No working directory is given,
    /// so it is herdr's to pick — with no pane yet to follow, the home
    /// directory of the machine herdr runs on. Without a label herdr names
    /// the workspace itself.
    public func createWorkspace(label: String?, on machine: HerdrMachine?, environment: [String: String] = [:]) async throws -> CreatedTab {
        let result = try await createRequest(
            method: "workspace.create",
            params: ["label": label.map(JSONValue.string) ?? .null, "focus": .bool(false), "env": .object(environment.mapValues(JSONValue.string))],
            cli: ["workspace", "create", "--no-focus"] + (label.map { ["--label", $0] } ?? []) + Self.environmentArguments(environment),
            on: machine
        )
        return try Self.createdTab(from: result, on: machine)
    }

    private static func environmentArguments(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().flatMap { ["--env", "\($0)=\(environment[$0]!)"] }
    }

    /// Has herdr type the kind's command into the pane's shell. Over the
    /// socket API herdr answers `agent_started` as soon as that is written,
    /// before the agent is ready for input; only the `herdr agent start` CLI
    /// (the way to a herdr machine here) waits for its interactive readiness.
    /// So success is not readiness, nor CLI version or MCP readiness: a launch
    /// waits for the agent itself (`AgentLaunchService`, `AgentLaunchReadiness`).
    public func agentStart(name: String, kind: AgentKind, paneID: String, arguments: [String], timeoutMs: Int = 30_000, on machine: HerdrMachine? = nil) async throws -> AgentStartResult {
        guard (3_001...300_000).contains(timeoutMs) else { throw Self.agentResponseError() }
        let result = try await agentRequest(method: "agent.start", params: [
            "name": .string(name), "kind": .string(kind.rawValue), "pane_id": .string(paneID),
            "args": .array(arguments.map(JSONValue.string)), "timeout_ms": .number(Double(timeoutMs))
        ], cli: ["agent", "start", name, "--kind", kind.rawValue, "--pane", paneID, "--timeout", String(timeoutMs), "--"] + arguments, on: machine, deadlineMs: timeoutMs + 2_000)
        guard result["type"]?.stringValue == "agent_started", let row = result["agent"],
              let agent = AgentSummary(json: row, on: machine), agent.paneID == paneID,
              let values = result["argv"]?.arrayValue, !values.isEmpty, values.allSatisfy({ $0.stringValue != nil }) else { throw Self.agentResponseError() }
        return AgentStartResult(agent: agent, arguments: values.compactMap(\.stringValue))
    }

    /// Types `argv` into the pane's shell and submits it, as `herdr pane run`
    /// does: `pane.send_input` with Enter, one write, bracketed paste and all.
    /// Unlike `agent.start`, whose executable is the kind's bare name for the
    /// shell to look up through whatever PATH its startup files left, the
    /// executable is what `argv[0]` names — an absolute path runs that file.
    /// herdr takes no further part: it names nothing and waits for nothing,
    /// and shows an agent in the pane once it detects one, as it does for
    /// anything the user types.
    public func runCommand(paneID: String, argv: [String]) async throws {
        let line = try Self.commandLine(argv)
        let result = try await agentRequest(method: "pane.send_input",
            params: ["pane_id": .string(paneID), "text": .string(line), "keys": .array([.string("enter")])],
            cli: ["pane", "run", paneID, line], on: nil, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "ok" else { throw Self.agentResponseError() }
    }

    /// `argv` as one line for a POSIX shell: every word in single quotes
    /// (`shellQuoted`), so a path with spaces stays one word. A control
    /// character is refused, as herdr's own `agent.start` refuses it: a
    /// newline would submit the line early.
    public nonisolated static func commandLine(_ argv: [String]) throws -> String {
        guard let first = argv.first, !first.isEmpty,
              !argv.contains(where: { $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }) else {
            throw HerdrErrorPayload(code: "invalid_command", message: "The command is empty or has a control character in it.")
        }
        return argv.map(shellQuoted).joined(separator: " ")
    }

    public func processInfo(paneID: String, on machine: HerdrMachine? = nil) async throws -> PaneProcessInfo {
        let result = try await agentRequest(method: "pane.process_info", params: ["pane_id": .string(paneID)], cli: ["pane", "process-info", "--pane", paneID], on: machine, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "pane_process_info", let value = result["process_info"] else { throw Self.agentResponseError() }
        let info = try JSONDecoder().decode(PaneProcessInfo.self, from: JSONEncoder().encode(value))
        guard info.paneID == paneID else { throw Self.agentResponseError() }
        return info
    }

    /// Session-only Pi state integration (Herdr 0.9.1 integration protocol v9).
    /// This is display/lifecycle evidence, never native browser authorization.
    public func reportPiState(paneID: String, sessionFile: String, state: String, sequence: UInt64) async throws {
        guard ["idle", "working", "blocked"].contains(state), sessionFile.hasPrefix("/"), !sessionFile.utf8.contains(0),
              sequence < 9_007_199_254_740_991 else { throw Self.agentResponseError() }
        let session = try await agentRequest(method: "pane.report_agent_session", params: ["pane_id":.string(paneID), "source":.string("herdr:pi"),
            "agent":.string("pi"),"agent_session_path":.string(sessionFile),"seq":.number(Double(sequence))], cli: [], on: nil, deadlineMs: 2_000)
        guard session["type"]?.stringValue == "ok" else { throw Self.agentResponseError() }
        let result = try await agentRequest(method: "pane.report_agent", params: ["pane_id":.string(paneID), "source":.string("herdr:pi"),
            "agent":.string("pi"),"state":.string(state),"agent_session_path":.string(sessionFile),"seq":.number(Double(sequence + 1))],
            cli: [], on: nil, deadlineMs: 2_000)
        guard result["type"]?.stringValue == "ok" else { throw Self.agentResponseError() }
    }

    /// Supported agent input, never arbitrary shell text or a process-name kill.
    public func agentSendKeys(paneID: String, keys: [String], on machine: HerdrMachine? = nil) async throws {
        let result = try await agentRequest(method: "agent.send_keys", params: ["target": .string(paneID), "keys": .array(keys.map(JSONValue.string))], cli: ["agent", "send-keys", paneID] + keys, on: machine, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "ok" else { throw Self.agentResponseError() }
    }

    // MARK: Driving an agent from afar (docs/mobile-design.md, section 3)

    /// The agent in a pane, as herdr has it now. Throws herdr's
    /// `agent_not_found` for a pane with no agent in it.
    public func agentGet(paneID: String, on machine: HerdrMachine? = nil) async throws -> AgentSummary {
        let result = try await agentRequest(method: "agent.get", params: ["target": .string(paneID)], cli: ["agent", "get", paneID], on: machine, deadlineMs: 5_000)
        return try Self.agent(in: result, paneID: paneID, on: machine)
    }

    /// Waits until the agent is in one of `states`, or `timeoutMs` passes,
    /// and returns the agent as it then is. herdr waits for a state, not a
    /// transition: a pane already in one of `states` matches at once (herdr
    /// 0.9.1, read live). Throws a `HerdrErrorPayload` with the code
    /// "timeout" when the time runs out, and "agent_not_found" when the pane
    /// has gone or has no agent.
    public func agentWait(paneID: String, until states: [AgentState], timeoutMs: Int, on machine: HerdrMachine? = nil) async throws -> AgentSummary {
        let names = states.map(\.rawValue)
        let result = try await agentRequest(
            method: "agent.wait",
            params: ["target": .string(paneID), "until": .array(names.map(JSONValue.string)), "timeout_ms": .number(Double(timeoutMs))],
            cli: ["agent", "wait", paneID, "--timeout", String(timeoutMs)] + names.flatMap { ["--until", $0] },
            on: machine, deadlineMs: timeoutMs + 5_000)
        return try Self.agent(in: result, paneID: paneID, on: machine)
    }

    /// Submits `text` to the agent: the text and then Enter, as one ordered
    /// submission, the pane's bracketed-paste mode honoured. Returns once
    /// both have been written, which says nothing yet about the agent
    /// taking it up. herdr turns the submission down with `agent_blocked`,
    /// before writing anything, while the agent waits at a question or an
    /// approval. The text may be the person's instructions: never log it.
    public func agentPrompt(paneID: String, text: String, on machine: HerdrMachine? = nil) async throws {
        _ = try await agentRequest(method: "agent.prompt", params: ["target": .string(paneID), "text": .string(text)],
                                   cli: ["agent", "prompt", paneID, text], on: machine, deadlineMs: 30_000)
    }

    /// Writes `text` to the pane as it is, with no Enter after it: for
    /// answering, in words, a question the agent put. The text may be the
    /// person's words: never log it.
    public func paneSendText(paneID: String, text: String, on machine: HerdrMachine? = nil) async throws {
        _ = try await agentRequest(method: "pane.send_text", params: ["pane_id": .string(paneID), "text": .string(text)],
                                   cli: ["pane", "send-text", paneID, text], on: machine, deadlineMs: 5_000)
    }

    private static func agent(in result: JSONValue, paneID: String, on machine: HerdrMachine?) throws -> AgentSummary {
        guard let row = result["agent"], let agent = AgentSummary(json: row, on: machine), agent.paneID == paneID else {
            throw agentResponseError()
        }
        return agent
    }

    /// What a pane's terminal shows, as text. `source` picks the screen
    /// (`visible`) or the recent rows of scrollback, with (`recent`) or
    /// without (`recentUnwrapped`) the terminal's soft wrapping: 80 rows
    /// unless `lines` says otherwise, and 1000 at most — `truncated` says
    /// when older rows were left out (herdr 0.9.1, read live). For a pane on
    /// a herdr machine the CLI prints the text itself, with no envelope and
    /// no word on truncation.
    public func readPane(_ paneID: String, source: PaneReadSource = .recent, lines: Int? = nil, on machine: HerdrMachine? = nil) async throws -> PaneRead {
        if let machine {
            var arguments = ["--machine", machine.id, "pane", "read", paneID, "--source", source.cliName, "--format", "text"]
            if let lines { arguments += ["--lines", String(lines)] }
            let output = try await transport.runHerdr(arguments)
            return PaneRead(text: String(decoding: output, as: UTF8.self), truncated: false)
        }
        var params: [String: JSONValue] = ["pane_id": .string(paneID), "source": .string(source.rawValue), "format": .string("text")]
        if let lines { params["lines"] = .number(Double(lines)) }
        let result = try await agentRequest(method: "pane.read", params: params, cli: [], on: nil, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "pane_read", let read = result["read"], read["pane_id"]?.stringValue == paneID,
              let text = read["text"]?.stringValue else { throw Self.agentResponseError() }
        var truncated = false
        if case .bool(let flag) = read["truncated"] { truncated = flag }
        return PaneRead(text: text, truncated: truncated)
    }

    public func visiblePaneANSI(paneID: String) async throws -> String {
        let result = try await agentRequest(method: "pane.read", params: ["pane_id": .string(paneID), "source": .string("visible"), "format": .string("ansi")], cli: [], on: nil, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "pane_read", result["read"]?["pane_id"]?.stringValue == paneID,
              let text = result["read"]?["text"]?.stringValue else { throw Self.agentResponseError() }
        return text
    }

    public func agentList(on machine: HerdrMachine? = nil) async throws -> [AgentSummary] {
        let result = try await agentRequest(method: "agent.list", params: [:], cli: ["agent", "list"], on: machine, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "agent_list", let rows = result["agents"]?.arrayValue else { throw Self.agentResponseError() }
        let agents = rows.compactMap { AgentSummary(json: $0, on: machine) }
        guard agents.count == rows.count, Set(agents.map(\.paneID)).count == agents.count,
              Set(agents.map(\.terminalID)).count == agents.count else { throw Self.agentResponseError() }
        return agents
    }

    /// A finite request for launch/revalidation, apart from the machine
    /// monitors' own reading (see `MachineMonitor`).
    public func launchSnapshot() async throws -> HerdrSnapshot {
        try await withThrowingTaskGroup(of: HerdrSnapshot.self) { group in
            group.addTask { try await self.snapshot() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw HerdrErrorPayload(code: "inspection_timeout", message: "Pane inspection timed out; existing state was retained.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func agentRequest(method: String, params: [String: JSONValue], cli: [String], on machine: HerdrMachine?, deadlineMs: Int) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.createRequest(method: method, params: params, cli: cli, on: machine) }
            group.addTask {
                try await Task.sleep(for: .milliseconds(deadlineMs))
                throw HerdrErrorPayload(code: "agent_request_timeout", message: "Agent request timed out. Inspect this pane before trying again.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func agentResponseError() -> HerdrErrorPayload {
        HerdrErrorPayload(code: "unexpected_agent_response", message: "herdr returned incomplete agent readiness or process information.")
    }

    /// `request`, for one whose answer is wanted: the result as the socket
    /// API gives it, which the CLI prints under "result".
    private func createRequest(method: String, params: [String: JSONValue], cli: [String], on machine: HerdrMachine?) async throws -> JSONValue {
        if let machine {
            let output = try await transport.runHerdr(["--machine", machine.id] + cli)
            let response = try JSONDecoder().decode(JSONValue.self, from: output)
            // The CLI prints herdr's error in the same envelope as the socket
            // API, and exits as if nothing were wrong (herdr 0.9.1, read
            // live), so the envelope is where the error is.
            if let error = response["error"], let message = error["message"]?.stringValue {
                throw HerdrErrorPayload(code: error["code"]?.stringValue, message: message)
            }
            return response["result"] ?? .object([:])
        }
        return try await transport.send(method: method, params: .object(params))
    }

    /// The tab and pane in a `tab.create` or `workspace.create` result.
    private static func createdTab(from result: JSONValue, on machine: HerdrMachine?) throws -> CreatedTab {
        guard let paneJSON = result["root_pane"], let pane = AgentSummary(json: paneJSON, on: machine),
              let tabJSON = result["tab"],
              let tab = TabSummary(tab: tabJSON, layout: nil, panes: [pane.paneID: pane], on: machine) else {
            throw HerdrErrorPayload(code: "unexpected_response", message: String(localized: "herdr's answer didn't name the new tab.", bundle: .shepherdKit))
        }
        return CreatedTab(tab: tab, pane: pane)
    }

    /// A request that changes something in herdr, sent to the host's herdr
    /// over the socket API, or to one of its herdr machines through the
    /// host's herdr CLI, whose `--machine` carries API requests only by way
    /// of its own commands. Throws what herdr answers with when it turns the
    /// request down.
    private func request(method: String, params: [String: JSONValue], cli: [String], on machine: HerdrMachine?) async throws {
        if let machine {
            _ = try await transport.runHerdr(["--machine", machine.id] + cli)
        } else {
            _ = try await transport.send(method: method, params: .object(params))
        }
    }

    public func newlyPinnedHostKeyFingerprint() async -> String? {
        await transport.newlyPinnedHostKeyFingerprint()
    }

    /// Runs `script` with `sh` on the host, not in herdr (see
    /// `HerdrTransport.runScript`).
    public func runScript(_ script: String) async throws -> Data {
        try await transport.runScript(script)
    }

    /// `runScript`, given up on after `timeout` seconds (see
    /// `HerdrTransport.runScript(_:timeout:)`).
    public func runScript(_ script: String, timeout: TimeInterval) async throws -> Data {
        try await transport.runScript(script, timeout: timeout)
    }

    /// Subscribes to every change of herdr's workspaces, tabs, panes and
    /// layouts, and to the agent status of the panes in `paneIDs` (see
    /// `HerdrChangeSubscription`), and returns once herdr has acknowledged
    /// it, with the lines herdr writes from then on. Throws herdr's error for
    /// a subscription it turns down — a `HerdrErrorPayload` with the code
    /// "pane_not_found" when one of the panes is gone — and
    /// `HerdrSubscriptionError` when there's no subscription to be had over
    /// this transport at all.
    public func subscribeToChanges(statusOf paneIDs: Set<String>) async throws -> HerdrSubscriptionLines {
        try await transport.subscribe(params: HerdrChangeSubscription(statusOf: paneIDs).params)
    }

    /// Long-polls for a pane to transition to a specific status — what a
    /// machine's monitor keeps up with in place of a subscription when it
    /// can't have one (see `MachineMonitor`). Confirmed live: `events.wait`
    /// only supports agent-status matches — a broader "pane output changed"
    /// match exists in the request schema but the server rejects it for
    /// `events.wait` with `unsupported_event_wait_match`.
    /// Blocks server—side until the pane reaches `status` or `timeoutMs`
    /// elapses, then the connection ends either way. Returns `true` if it
    /// matched, `false` on a plain timeout.
    ///
    /// `status` can be any `AgentState`: herdr 0.9.1 types the match's
    /// `agent_status` as its `AgentStatus` (idle, working, blocked, done,
    /// unknown — the same five, under the same names), in its source
    /// (src/api/schema/events.rs) and in the schema the installed binary
    /// prints with `herdr api schema --json` alike. A value outside those
    /// would not be held and timed out; the request would be turned down as
    /// a whole ("invalid_request").
    ///
    /// Two cases don't block at all (herdr 0.9.1, from its source and its
    /// own tests), and a caller that long-polls in a loop has to allow for
    /// both or it will spin:
    /// - A pane that is ALREADY in `status` matches at once — this waits for
    ///   a state, not for a transition into it. Asking again straight away
    ///   gets the same immediate answer, so don't wait for a status the pane
    ///   is known to have.
    /// - A pane that doesn't exist, or closes while being waited on, ends
    ///   the wait with a `HerdrErrorPayload` whose code is "pane_not_found".
    ///   That is thrown like any other server error: the server was reached
    ///   and answered, so it says something about the pane, not about the
    ///   connection.
    ///
    /// Any other `HerdrErrorPayload` is not about the pane — the match was
    /// turned down ("unsupported_event_wait_match", "invalid_request"), or
    /// herdr could not look the pane up ("server_unavailable",
    /// "internal_error") — and is as likely to come back on the next wait
    /// as on this one.
    public func waitForPaneStatus(paneID: String, status: AgentState, timeoutMs: Int = 25_000) async throws -> Bool {
        let params: JSONValue = .object([
            "match_event": .object([
                "event": .string("pane_agent_status_changed"),
                "pane_id": .string(paneID),
                "agent_status": .string(status.rawValue)
            ]),
            "timeout_ms": .number(Double(timeoutMs))
        ])
        do {
            _ = try await transport.send(method: "events.wait", params: params)
            return true
        } catch let error as HerdrErrorPayload where error.code == "timeout" {
            return false
        }
    }
}

/// Which of a pane's text `HerdrClient.readPane` reads. The raw value is
/// the socket API's name; the CLI spells the same source with a dash.
public nonisolated enum PaneReadSource: String, Sendable {
    case visible
    case recent
    case recentUnwrapped = "recent_unwrapped"

    var cliName: String { rawValue.replacingOccurrences(of: "_", with: "-") }
}

/// What `HerdrClient.readPane` read.
public nonisolated struct PaneRead: Sendable {
    public let text: String
    /// Whether rows older than `text` were left out.
    public let truncated: Bool
}
