import Foundation

/// Typed convenience wrapper around a `HerdrTransport`. UI code should talk
/// to this, not to the transport or raw JSON, directly.
actor HerdrClient {
    private let transport: HerdrTransport

    init(transport: HerdrTransport) {
        self.transport = transport
    }

    func connect() async throws {
        try await transport.connect()
    }

    func disconnect() async {
        await transport.disconnect()
    }

    /// Every pane in the host's herdr — those with an agent in them and
    /// those without alike.
    func listPanes() async throws -> [AgentSummary] {
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
    func snapshot() async throws -> HerdrSnapshot {
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
    func listHerdrMachines() async throws -> [HerdrMachine] {
        let output = try await transport.runHerdr(["machine", "list", "--json"])
        return try JSONDecoder().decode([HerdrMachine].self, from: output).filter(\.enabled)
    }

    /// The panes, tabs and workspaces on one of the host's herdr machines,
    /// fetched by the host's herdr CLI (`herdr --machine <id> api snapshot`,
    /// which is `session.snapshot`), which carries the request over its own
    /// SSH connection to that machine. The CLI prints the same response the
    /// socket API gives. herdr machines came in herdr 0.9, long after
    /// `session.snapshot`, so there is no older herdr to fall back for.
    func snapshot(on machine: HerdrMachine) async throws -> HerdrSnapshot {
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

    enum SnapshotSchemaError: Error, LocalizedError {
        case invalidPaneIdentities
        var errorDescription: String? { "herdr returned an incomplete pane snapshot; previous browser ownership was retained." }
    }

    /// Gives a tab the name herdr shows for it. herdr takes any name as it
    /// is, an empty one included, so it is up to the caller not to send one.
    func renameTab(_ tabID: String, to label: String, on machine: HerdrMachine?) async throws {
        try await request(
            method: "tab.rename",
            params: ["tab_id": .string(tabID), "label": .string(label)],
            cli: ["tab", "rename", tabID, label],
            on: machine
        )
    }

    /// Closes a tab, and with it every pane in it and whatever runs there.
    func closeTab(_ tabID: String, on machine: HerdrMachine?) async throws {
        try await request(method: "tab.close", params: ["tab_id": .string(tabID)], cli: ["tab", "close", tabID], on: machine)
    }

    /// Gives a pane a name of its own, or — with nil — takes it away again,
    /// so that the pane goes back to being called by its terminal's title.
    func renamePane(_ paneID: String, to label: String?, on machine: HerdrMachine?) async throws {
        try await request(
            method: "pane.rename",
            params: ["pane_id": .string(paneID), "label": label.map(JSONValue.string) ?? .null],
            cli: ["pane", "rename", paneID] + [label ?? "--clear"],
            on: machine
        )
    }

    /// Closes a pane, ending whatever runs in it.
    func closePane(_ paneID: String, on machine: HerdrMachine?) async throws {
        try await request(method: "pane.close", params: ["pane_id": .string(paneID)], cli: ["pane", "close", paneID], on: machine)
    }

    /// A tab just made, and the one pane it starts out with.
    nonisolated struct CreatedTab: Sendable {
        let tab: TabSummary
        let pane: AgentSummary
    }

    /// Opens a new tab — and with it a new pane — in a workspace, without
    /// moving herdr's own view there. Its working directory is herdr's to
    /// pick: by default it follows the workspace's focused pane. Without a
    /// label herdr numbers the tab.
    func createTab(inWorkspace workspaceID: String, label: String?, on machine: HerdrMachine?, environment: [String: String] = [:]) async throws -> CreatedTab {
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
    func createWorkspace(label: String?, on machine: HerdrMachine?, environment: [String: String] = [:]) async throws -> CreatedTab {
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

    /// Success is herdr's interactive readiness result, not CLI version or MCP readiness.
    func agentStart(name: String, kind: AgentKind, paneID: String, arguments: [String], timeoutMs: Int = 30_000, on machine: HerdrMachine? = nil) async throws -> AgentStartResult {
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

    func processInfo(paneID: String, on machine: HerdrMachine? = nil) async throws -> PaneProcessInfo {
        let result = try await agentRequest(method: "pane.process_info", params: ["pane_id": .string(paneID)], cli: ["pane", "process-info", "--pane", paneID], on: machine, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "pane_process_info", let value = result["process_info"] else { throw Self.agentResponseError() }
        let info = try JSONDecoder().decode(PaneProcessInfo.self, from: JSONEncoder().encode(value))
        guard info.paneID == paneID else { throw Self.agentResponseError() }
        return info
    }

    /// Session-only Pi state integration (Herdr 0.9.1 integration protocol v9).
    /// This is display/lifecycle evidence, never native browser authorization.
    func reportPiState(paneID: String, sessionFile: String, state: String, sequence: UInt64) async throws {
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
    func agentSendKeys(paneID: String, keys: [String]) async throws {
        let result = try await agentRequest(method: "agent.send_keys", params: ["target": .string(paneID), "keys": .array(keys.map(JSONValue.string))], cli: ["agent", "send-keys", paneID] + keys, on: nil, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "ok" else { throw Self.agentResponseError() }
    }

    func visiblePaneANSI(paneID: String) async throws -> String {
        let result = try await agentRequest(method: "pane.read", params: ["pane_id": .string(paneID), "source": .string("visible"), "format": .string("ansi")], cli: [], on: nil, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "pane_read", result["read"]?["pane_id"]?.stringValue == paneID,
              let text = result["read"]?["text"]?.stringValue else { throw Self.agentResponseError() }
        return text
    }

    func agentList(on machine: HerdrMachine? = nil) async throws -> [AgentSummary] {
        let result = try await agentRequest(method: "agent.list", params: [:], cli: ["agent", "list"], on: machine, deadlineMs: 5_000)
        guard result["type"]?.stringValue == "agent_list", let rows = result["agents"]?.arrayValue else { throw Self.agentResponseError() }
        let agents = rows.compactMap { AgentSummary(json: $0, on: machine) }
        guard agents.count == rows.count, Set(agents.map(\.paneID)).count == agents.count,
              Set(agents.map(\.terminalID)).count == agents.count else { throw Self.agentResponseError() }
        return agents
    }

    /// A finite request for launch/revalidation without changing the board's polling.
    func launchSnapshot() async throws -> HerdrSnapshot {
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
            return response["result"] ?? .object([:])
        }
        return try await transport.send(method: method, params: .object(params))
    }

    /// The tab and pane in a `tab.create` or `workspace.create` result.
    private static func createdTab(from result: JSONValue, on machine: HerdrMachine?) throws -> CreatedTab {
        guard let paneJSON = result["root_pane"], let pane = AgentSummary(json: paneJSON, on: machine),
              let tabJSON = result["tab"],
              let tab = TabSummary(tab: tabJSON, layout: nil, panes: [pane.paneID: pane], on: machine) else {
            throw HerdrErrorPayload(code: "unexpected_response", message: String(localized: "herdr's answer didn't name the new tab."))
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

    func newlyPinnedHostKeyFingerprint() async -> String? {
        await transport.newlyPinnedHostKeyFingerprint()
    }

    /// Runs `script` with `sh` on the host, not in herdr (see
    /// `HerdrTransport.runScript`).
    func runScript(_ script: String) async throws -> Data {
        try await transport.runScript(script)
    }

    /// Long-polls for a pane to transition to a specific status (confirmed
    /// live: `events.wait` only supports agent-status matches — a broader
    /// "pane output changed" match exists in the request schema but the
    /// server rejects it for `events.wait` with `unsupported_event_wait_match`).
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
    func waitForPaneStatus(paneID: String, status: AgentState, timeoutMs: Int = 25_000) async throws -> Bool {
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
