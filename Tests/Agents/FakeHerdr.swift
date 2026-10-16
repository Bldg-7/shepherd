import Foundation

nonisolated struct PassingTestFailure: Error {}

/// A herdr in memory: panes to snapshot, subscriptions to feed events into,
/// long-polls that only ever time out, and herdr machines for its CLI.
actor FakeHerdr: HerdrTransport {
    enum Mode: Sendable {
        case acknowledge
        case unsupported
        case refuse(String)
        case neverAcknowledge
    }

    struct Subscription {
        let paneIDs: [String]
        let lifecycleCount: Int
        var closed = false
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    }

    private var panes: [String]
    private var agents: Set<String>
    private var titles: [String: String] = [:]
    private let mode: Mode
    private let herdrMachines: [String]
    private var machineDelays: [String: Duration] = [:]
    private var failingMachines: Set<String> = []
    private var closesWhenSubscribed: Set<String> = []
    private var snapshotDelay: Duration = .zero
    private var hanging = false
    private var failingSnapshots = 0
    private var connectFailure: (any Error)?

    private(set) var subscriptions: [Subscription] = []
    /// The panes named in every subscription asked for, taken or not.
    private(set) var attempts: [[String]] = []
    private(set) var snapshotTimes: [ContinuousClock.Instant] = []
    private(set) var herdrMachineSnapshots: [(machine: String, at: ContinuousClock.Instant)] = []
    private(set) var waits = 0
    private(set) var connectTimes: [ContinuousClock.Instant] = []
    private(set) var disconnects = 0
    var connects: Int { connectTimes.count }
    /// The second subscription — the one naming the agent pane — taken, and
    /// a snapshot read after each.
    var isSubscribedForTheAgent: Bool { subscriptions.count == 2 && snapshotTimes.count == 2 }

    init(panes: [String] = ["w1:p1", "w1:p2"], agents: Set<String> = ["w1:p1"], mode: Mode = .acknowledge, herdrMachines: [String] = []) {
        self.panes = panes
        self.agents = agents
        self.mode = mode
        self.herdrMachines = herdrMachines
    }

    func setTitle(_ paneID: String, _ title: String) { titles[paneID] = title }
    func addAgent(_ paneID: String) { agents.insert(paneID) }
    func setSnapshotDelay(_ delay: Duration) { snapshotDelay = delay }
    func hangSnapshots(_ hang: Bool) { hanging = hang }
    func failSnapshots(_ count: Int) { failingSnapshots = count }
    func failConnecting(with error: (any Error)?) { connectFailure = error }
    func closeWhenSubscribed(_ paneID: String) { closesWhenSubscribed.insert(paneID) }
    func setMachineDelay(_ id: String, _ delay: Duration) { machineDelays[id] = delay }
    func setMachineFailure(_ id: String) { failingMachines.insert(id) }

    /// Writes `line` on the newest subscription still open.
    func emit(_ line: String) {
        guard let index = subscriptions.lastIndex(where: { !$0.closed }) else { return }
        subscriptions[index].continuation.yield(Data(line.utf8))
    }

    /// Ends the newest subscription still open, after `line` if given.
    func endLatest(with line: String? = nil) {
        guard let index = subscriptions.lastIndex(where: { !$0.closed }) else { return }
        if let line { subscriptions[index].continuation.yield(Data(line.utf8)) }
        subscriptions[index].continuation.finish()
    }

    private func markClosed(_ index: Int) { subscriptions[index].closed = true }

    func connect() async throws {
        connectTimes.append(.now)
        if let connectFailure { throw connectFailure }
    }

    func disconnect() async {
        disconnects += 1
    }

    func send(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "session.snapshot":
            snapshotTimes.append(.now)
            if hanging { try await Task.sleep(for: .seconds(3600)) }
            if snapshotDelay > .zero { try await Task.sleep(for: snapshotDelay) }
            if failingSnapshots > 0 {
                failingSnapshots -= 1
                throw PassingTestFailure()
            }
            return .object(["snapshot": snapshot(paneIDs: panes, terminalPrefix: "term-")])
        case "events.wait":
            waits += 1
            try await Task.sleep(for: .milliseconds(params["timeout_ms"]?.intValue ?? 25_000))
            throw HerdrErrorPayload(code: "timeout", message: "Timed out waiting for the event")
        default:
            return .object([:])
        }
    }

    private func snapshot(paneIDs: [String], terminalPrefix: String) -> JSONValue {
        .object([
            "panes": .array(paneIDs.map { id in
                var pane: [String: JSONValue] = [
                    "pane_id": .string(id), "terminal_id": .string(terminalPrefix + id), "tab_id": .string("w1:t1"),
                    "workspace_id": .string("w1"), "terminal_title_stripped": .string(titles[id] ?? id),
                    "agent_status": .string(agents.contains(id) ? "working" : "unknown"),
                ]
                if agents.contains(id) { pane["agent"] = .string("claude") }
                return .object(pane)
            }),
            "tabs": .array([.object(["tab_id": .string("w1:t1"), "workspace_id": .string("w1"), "label": .string("1"), "number": .number(1)])]),
            "layouts": .array([]),
            "workspaces": .array([.object(["workspace_id": .string("w1"), "label": .string("main"), "number": .number(1)])]),
        ])
    }

    func subscribe(params: JSONValue) async throws -> HerdrSubscriptionLines {
        let rows = params["subscriptions"]?.arrayValue ?? []
        let paneIDs = rows.compactMap { $0["pane_id"]?.stringValue }
        switch mode {
        case .unsupported:
            throw HerdrSubscriptionError.unsupported
        case .refuse(let code):
            throw HerdrErrorPayload(code: code, message: code)
        case .neverAcknowledge:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        case .acknowledge:
            break
        }
        attempts.append(paneIDs)
        let gone = closesWhenSubscribed.intersection(paneIDs)
        if !gone.isEmpty {
            // The pane closes between the snapshot and the subscription.
            closesWhenSubscribed.subtract(gone)
            panes.removeAll { gone.contains($0) }
            agents.subtract(gone)
            throw HerdrErrorPayload(code: "pane_not_found", message: "pane \(gone.sorted()[0]) not found")
        }
        let (lines, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let index = subscriptions.count
        subscriptions.append(Subscription(paneIDs: paneIDs, lifecycleCount: rows.count - paneIDs.count, continuation: continuation))
        continuation.onTermination = { _ in
            Task { await self.markClosed(index) }
        }
        return HerdrSubscriptionLines(lines: lines, close: { continuation.finish() })
    }

    func runHerdr(_ arguments: [String]) async throws -> Data {
        if arguments == ["machine", "list", "--json"] {
            let rows = herdrMachines.map { #"{"id":"\#($0)","label":"\#($0)","target":"\#($0).example","session":"default","enabled":true}"# }
            return Data(("[" + rows.joined(separator: ",") + "]").utf8)
        }
        if arguments.count == 4, arguments[0] == "--machine", Array(arguments[2...]) == ["api", "snapshot"] {
            let id = arguments[1]
            herdrMachineSnapshots.append((id, .now))
            if let delay = machineDelays[id] { try await Task.sleep(for: delay) }
            if failingMachines.contains(id) { throw HerdrCommandError(status: 1, message: "error: machine '\(id)': ssh: connect to host \(id).example: Connection refused") }
            let snapshot = JSONValue.object(["result": .object(["snapshot": .object([
                "panes": .array([.object(["pane_id": .string("w1:p1"), "terminal_id": .string("term-\(id)"), "agent": .string("codex"), "agent_status": .string("idle")])]),
                "tabs": .array([]),
                "workspaces": .array([]),
            ])])])
            return try JSONEncoder().encode(snapshot)
        }
        throw HerdrCommandError(status: 1, message: "unexpected herdr \(arguments)")
    }

    func runScript(_ script: String) async throws -> Data {
        throw HostScriptError(status: 127, message: "no scripts here")
    }
}
