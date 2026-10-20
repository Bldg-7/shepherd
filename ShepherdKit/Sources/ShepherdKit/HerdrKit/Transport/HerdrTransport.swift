import Foundation

/// Abstraction over however a machine's herdr.sock is reached: this Mac's
/// own socket directly (`LocalHerdrTransport`), or a remote one over SSH
/// (`SSHHerdrTransport`). Kept separate from `HerdrClient` so that the rest
/// of the app doesn't depend on the SSH packages (Citadel, swift-nio-ssh)
/// directly.
public protocol HerdrTransport: Actor {
    func connect() async throws
    func disconnect() async
    func send(method: String, params: JSONValue) async throws -> JSONValue
    /// Sends `events.subscribe` with `params` over a connection of its own,
    /// which herdr keeps open, and returns once herdr has acknowledged it,
    /// with every line herdr writes on it after that. Throws herdr's error
    /// for a subscription it turns down (`HerdrErrorPayload`), and
    /// `HerdrSubscriptionError` for a connection that closes before herdr
    /// acknowledges it. Cancelling the call closes the connection.
    ///
    /// The default throws `HerdrSubscriptionError.unsupported`: a transport
    /// that can't keep a connection open goes without, and its callers keep
    /// up by asking again instead (see `MachineMonitor`).
    func subscribe(params: JSONValue) async throws -> HerdrSubscriptionLines
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
    /// `runScript`, given up on after `timeout` seconds with
    /// `HostScriptTimedOut`. Meant for a script that keeps a deadline of its
    /// own (see `HostStep`), so this is the backstop for a host that stops
    /// answering, not the way the work is ended: on a host over SSH the
    /// script is left to finish by itself.
    func runScript(_ script: String, timeout: TimeInterval) async throws -> Data
}

extension HerdrTransport {
    public func newlyPinnedHostKeyFingerprint() async -> String? { nil }

    public func subscribe(params: JSONValue) async throws -> HerdrSubscriptionLines {
        throw HerdrSubscriptionError.unsupported
    }

    /// Races `runScript` against the clock. The script's own await is
    /// cancelled when the time runs out, and not waited for: an SSH command
    /// stream ends on cancellation, but its channel only closes once the
    /// command has.
    public func runScript(_ script: String, timeout: TimeInterval) async throws -> Data {
        try await raceHostScript(timeout: timeout) { try await self.runScript(script) }
    }
}

/// A script run with `HerdrTransport.runScript(_:timeout:)` that didn't
/// finish in the time it was given.
public nonisolated struct HostScriptTimedOut: Error, LocalizedError {
    public let seconds: Int

    public init(seconds: Int) {
        self.seconds = seconds
    }

    public var errorDescription: String? {
        String(localized: "The host didn't finish within \(seconds) seconds.", bundle: .shepherdKit)
    }
}

/// Runs `operation`, and throws `HostScriptTimedOut` if it hasn't finished
/// after `timeout` seconds, without waiting for it to notice being
/// cancelled.
nonisolated func raceHostScript(timeout: TimeInterval, _ operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
    let race = HostScriptRace()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(timeout))
                race.finish(.failure(HostScriptTimedOut(seconds: Int(timeout.rounded()))))
            }
            race.hold(work: work, timer: timer)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The first outcome of `raceHostScript`, and the tasks to end with it.
private nonisolated final class HostScriptRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var outcome: Result<Data, any Error>?
    private var tasks: [Task<Void, Never>] = []

    func begin(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func hold(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let finished = outcome != nil
        if !finished { tasks = [work, timer] }
        lock.unlock()
        if finished {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}

/// A script run with `HerdrTransport.runScript` exited with a failure. Its
/// message is what the script wrote to stderr.
public nonisolated struct HostScriptError: Error, LocalizedError {
    public let status: Int
    public let message: String

    public var errorDescription: String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(localized: "The command exited with status \(status).", bundle: .shepherdKit)
        }
        return trimmed
    }
}

/// In-memory fake for builds without the SSH packages (see
/// `MachineStore.makeHerdrTransport`) and for SwiftUI previews. Returns a
/// fixed set of agents, so the status board has something to render end to
/// end. It can't subscribe, so whatever uses it keeps up by asking again
/// (see `MachineMonitor`), and nothing it reports ever changes.
public actor StubHerdrTransport: HerdrTransport {
    public func connect() async throws {}
    public func disconnect() async {}

    public func send(method: String, params: JSONValue) async throws -> JSONValue {
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
    public func runHerdr(_ arguments: [String]) async throws -> Data {
        if arguments == ["machine", "list", "--json"] {
            return Data("[]".utf8)
        }
        throw HerdrCommandError(status: 127, message: "herdr isn't available in previews")
    }

    public func runScript(_ script: String) async throws -> Data {
        throw HostScriptError(status: 127, message: "Scripts don't run in previews")
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
