import Foundation

/// Abstraction over "however we're currently talking to herdr.sock on a remote
/// host". Kept separate from `HerdrClient` so the SSH implementation can be
/// swapped in once the Citadel/swift-nio-ssh package dependency is wired up,
/// without the rest of the app depending on that package directly.
protocol HerdrTransport: Actor {
    func connect() async throws
    func disconnect() async
    func send(method: String, params: JSONValue) async throws -> JSONValue
    /// Long-lived event stream opened after `events.subscribe` is acknowledged.
    func events() -> AsyncStream<JSONValue>
    /// If `connect()` just pinned a host key for the first time (no fingerprint
    /// was known going in), returns that fingerprint so the caller can persist
    /// it. Returns nil once a host already has one pinned, or for transports
    /// that don't have host keys at all (default below).
    func newlyPinnedHostKeyFingerprint() async -> String?
    /// Runs the herdr CLI on the host with `arguments` and returns what it
    /// wrote to stdout, or throws `HerdrCommandError` when it fails. Some of
    /// herdr exists only in its CLI — the machines saved in it, and every
    /// request to one of them (see `HerdrMachine`) — and this is the way to
    /// it.
    func runHerdr(_ arguments: [String]) async throws -> Data
    /// Runs `script` with `sh` on the host and returns what it wrote to
    /// stdout, or throws `HostScriptError` when it fails. For work on the
    /// host that isn't herdr's: setting its agents up for Shepherd, for one
    /// (see `AgentSkillSetup`).
    func runScript(_ script: String) async throws -> Data
}

extension HerdrTransport {
    func newlyPinnedHostKeyFingerprint() async -> String? { nil }
}

/// A script run with `HerdrTransport.runScript` exited with a failure. Its
/// message is what the script wrote to stderr.
nonisolated struct HostScriptError: Error, LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(localized: "The command exited with status \(status).")
        }
        return trimmed
    }
}

/// In-memory fake used while the real SSH transport isn't buildable yet
/// (see SSHHerdrTransport.swift) and for SwiftUI previews. Returns a fixed
/// set of agents and emits one synthetic state change so the status board
/// has something to render end-to-end.
actor StubHerdrTransport: HerdrTransport {
    private var continuation: AsyncStream<JSONValue>.Continuation?

    func connect() async throws {}
    func disconnect() async {}

    func send(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "pane.list":
            return .object(["panes": .array(Self.samplePanes)])
        case "session.snapshot":
            return .object(["snapshot": .object([
                "panes": .array(Self.samplePanes),
                "tabs": .array(Self.sampleTabs),
                "layouts": .array(Self.sampleLayouts),
                "workspaces": .array(Self.sampleWorkspaces)
            ])])
        case "events.subscribe":
            return .object([:])
        case "events.wait":
            // The real server holds an `events.wait` request open until the
            // pane reaches the requested status or `timeout_ms` passes, and
            // callers pace themselves on that: they long-poll again as soon
            // as one returns. Nothing ever changes here, so sit out the
            // timeout and then report it the way herdr does — an error with
            // code "timeout", which `HerdrClient.waitForPaneStatus` reads as
            // "no change". Answering straight away instead would turn every
            // such caller into a busy loop. `Task.sleep` throws on
            // cancellation, so an abandoned wait ends at once rather than
            // running out its timeout.
            let timeoutMs = max(0, params["timeout_ms"]?.intValue ?? Self.defaultWaitTimeoutMs)
            try await Task.sleep(for: .milliseconds(timeoutMs))
            throw HerdrErrorPayload(code: "timeout", message: "Timed out waiting for the event")
        default:
            return .object([:])
        }
    }

    /// No saved machines: the board shows its flat list, as it does for any
    /// host with none.
    func runHerdr(_ arguments: [String]) async throws -> Data {
        if arguments == ["machine", "list", "--json"] {
            return Data("[]".utf8)
        }
        throw HerdrCommandError(status: 127, message: "herdr isn't available in previews")
    }

    func runScript(_ script: String) async throws -> Data {
        throw HostScriptError(status: 127, message: "Scripts don't run in previews")
    }

    func events() -> AsyncStream<JSONValue> {
        AsyncStream { continuation in
            self.continuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(3))
                continuation.yield(.object([
                    "type": .string("pane.agent_status_changed"),
                    "pane_id": .string("w1:p2"),
                    "state": .string("done")
                ]))
            }
        }
    }

    /// Used when an `events.wait` request carries no `timeout_ms` of its own;
    /// matches the timeout `HerdrClient.waitForPaneStatus` asks for by default.
    private static let defaultWaitTimeoutMs = 25_000

    private static let samplePanes: [JSONValue] = [
        sampleAgent(paneID: "w1:p1", tabID: "w1:t1", agent: "claude-code", source: "custom:cli", title: "Refactor login flow", status: "working", revision: 42),
        sampleAgent(paneID: "w1:p2", tabID: "w1:t2", agent: "codex", source: "custom:cli", title: "Fix flaky test", status: "blocked", revision: 17),
        sampleAgent(paneID: "w2:p1", tabID: "w2:t1", agent: "docs-bot", source: "custom:docs", title: "Update README", status: "idle", revision: 3),
        // A pane with no agent in it: herdr leaves "agent" out and reports
        // the status as "unknown".
        .object([
            "pane_id": .string("w1:p4"),
            "tab_id": .string("w1:t1"),
            "workspace_id": .string("w1"),
            "terminal_id": .string("term_w1_p4"),
            "terminal_title_stripped": .string("npm run dev"),
            "agent_status": .string("unknown"),
            "cwd": .string("/Users/preview/Projects/web"),
            "revision": .number(8)
        ])
    ]

    /// The workspaces of `session.snapshot`: a web app, and its docs.
    private static let sampleWorkspaces: [JSONValue] = [
        .object(["workspace_id": .string("w1"), "label": .string("web"), "number": .number(1)]),
        .object(["workspace_id": .string("w2"), "label": .string("docs"), "number": .number(2)])
    ]

    /// The tabs of `session.snapshot`: the login work and its dev server
    /// side by side in one tab, the other two agents in a tab each.
    private static let sampleTabs: [JSONValue] = [
        .object(["tab_id": .string("w1:t1"), "workspace_id": .string("w1"), "label": .string("Login"), "number": .number(1)]),
        .object(["tab_id": .string("w1:t2"), "workspace_id": .string("w1"), "label": .string("2"), "number": .number(2)]),
        .object(["tab_id": .string("w2:t1"), "workspace_id": .string("w2"), "label": .string("Docs"), "number": .number(1)])
    ]

    private static let sampleLayouts: [JSONValue] = [
        sampleLayout(tabID: "w1:t1", focusedPaneID: "w1:p1", panes: [("w1:p1", 0, 0, 120), ("w1:p4", 120, 0, 80)]),
        sampleLayout(tabID: "w1:t2", focusedPaneID: "w1:p2", panes: [("w1:p2", 0, 0, 200)]),
        sampleLayout(tabID: "w2:t1", focusedPaneID: "w2:p1", panes: [("w2:p1", 0, 0, 200)])
    ]

    /// One tab's entry in `session.snapshot`'s `layouts`, on a 200×50 cell
    /// area with every pane its full height.
    private static func sampleLayout(tabID: String, focusedPaneID: String, panes: [(id: String, x: Int, y: Int, width: Int)]) -> JSONValue {
        .object([
            "tab_id": .string(tabID),
            "focused_pane_id": .string(focusedPaneID),
            "area": .object(["x": .number(0), "y": .number(0), "width": .number(200), "height": .number(50)]),
            "panes": .array(panes.map { pane in
                .object([
                    "pane_id": .string(pane.id),
                    "rect": .object([
                        "x": .number(Double(pane.x)),
                        "y": .number(Double(pane.y)),
                        "width": .number(Double(pane.width)),
                        "height": .number(50)
                    ])
                ])
            })
        ])
    }

    /// One `pane.list` entry for a pane with an agent, in the shape herdr
    /// really sends — the fields `AgentSummary.init(json:)` reads, under the
    /// names it reads them by (the status is "agent_status", and the source
    /// sits inside "agent_session"). An entry that only resembles the real
    /// thing parses without complaint and shows up with every agent
    /// "Unknown".
    private static func sampleAgent(paneID: String, tabID: String, agent: String, source: String, title: String, status: String, revision: Int) -> JSONValue {
        .object([
            "pane_id": .string(paneID),
            "tab_id": .string(tabID),
            "workspace_id": .string(String(tabID.prefix { $0 != ":" })),
            "terminal_id": .string("term_\(paneID.replacingOccurrences(of: ":", with: "_"))"),
            "agent": .string(agent),
            "terminal_title_stripped": .string(title),
            "agent_status": .string(status),
            "agent_session": .object(["source": .string(source), "agent": .string(agent)]),
            "revision": .number(Double(revision))
        ])
    }
}
