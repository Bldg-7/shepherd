import Foundation

/// The `events.subscribe` request a machine's monitor keeps open (see
/// `MachineMonitor`): every change herdr reports to its workspaces, tabs,
/// panes and layouts, and the agent status of the panes it names.
///
/// Confirmed against herdr 0.9.0 and 0.9.1 (2026-10-16): herdr acknowledges
/// the request at once with `{"id":…,"result":{"type":"subscription_started"}}`
/// and then keeps the connection open, writing one event per line. The
/// lifecycle events come for every workspace, tab and pane there is, the
/// ones that open later included. The status events don't: herdr only
/// reports a status change for a pane named when subscribing, so the panes
/// with an agent in them are named one by one, and a pane that gets one
/// later takes a new subscription (herdr says when it does, with the
/// lifecycle event `pane_agent_detected`).
nonisolated struct HerdrChangeSubscription: Equatable, Sendable {
    /// Every lifecycle event that changes what the board lists: what is
    /// open, what it is called, and how a tab is split. Focus and metadata
    /// events are left out, since the board shows neither.
    static let lifecycleEvents = [
        "workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed",
        "workspace.moved", "workspace.reordered",
        "tab.created", "tab.closed", "tab.renamed", "tab.moved",
        "pane.created", "pane.closed", "pane.updated", "pane.moved", "pane.exited",
        "pane.agent_detected", "layout.updated",
    ]

    /// The event a pane's agent status changing is reported as.
    static let statusEvent = "pane.agent_status_changed"

    /// The panes whose agent status is subscribed to, in order and each
    /// once, so that two subscriptions to the same panes are equal.
    let statusPaneIDs: [String]

    init(statusOf paneIDs: Set<String>) {
        statusPaneIDs = paneIDs.sorted()
    }

    /// The request's `params`.
    var params: JSONValue {
        let lifecycle = Self.lifecycleEvents.map { JSONValue.object(["type": .string($0)]) }
        let statuses = statusPaneIDs.map { JSONValue.object(["type": .string(Self.statusEvent), "pane_id": .string($0)]) }
        return .object(["subscriptions": .array(lifecycle + statuses)])
    }
}

/// One line herdr writes on an `events.subscribe` connection, as far as
/// keeping up with it goes. The events themselves are not read: each only
/// says that something changed, and what it changed to is read from a
/// snapshot (see `MachineMonitor`).
///
/// The shapes, as herdr 0.9.0 and 0.9.1 send them:
/// - the acknowledgement, `{"id":"req_1","result":{"type":"subscription_started"}}`;
/// - a lifecycle event, with an underscore in its name:
///   `{"event":"pane_updated","data":{"type":"pane_updated","pane":{…}}}`;
/// - a status event, with a dot:
///   `{"event":"pane.agent_status_changed","data":{"pane_id":…,"agent_status":…}}`;
/// - an error, after which herdr closes the connection: `pane_not_found`
///   for a named pane that doesn't exist (its id is not the request's but
///   `<request id>:sub:<n>:probe`), and from herdr 0.9.2 on `events_lost`
///   for a subscriber that fell too far behind.
nonisolated enum HerdrStreamLine: Equatable, Sendable {
    /// herdr took the subscription.
    case started
    /// Something changed; the event's name.
    case change(String)
    /// herdr gave up on the subscription, or never took it.
    case failure(code: String?, message: String)
    /// Not a line this knows: not JSON, or neither an event, an error nor
    /// the acknowledgement.
    case unrecognized

    init(_ line: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            self = .unrecognized
            return
        }
        self.init(json: json)
    }

    init(json: JSONValue) {
        if let error = json["error"] {
            self = .failure(code: error["code"]?.stringValue, message: error["message"]?.stringValue ?? "")
        } else if json["result"]?["type"]?.stringValue == "subscription_started" {
            self = .started
        } else if let event = json["event"]?.stringValue, !event.isEmpty {
            self = .change(event)
        } else {
            self = .unrecognized
        }
    }

    /// Throws unless `first`, the first line on a subscription's
    /// connection, is herdr's acknowledgement: herdr's own error as a
    /// `HerdrErrorPayload`, or `HerdrSubscriptionError.noAcknowledgement`
    /// for a connection that closed first (nil) or began with anything else.
    static func checkAcknowledgement(_ first: Data?) throws {
        guard let first else { throw HerdrSubscriptionError.noAcknowledgement }
        switch HerdrStreamLine(first) {
        case .started:
            return
        case .failure(let code, let message):
            throw HerdrErrorPayload(code: code, message: message)
        case .change, .unrecognized:
            throw HerdrSubscriptionError.noAcknowledgement
        }
    }
}

/// An `events.subscribe` connection that herdr has acknowledged.
nonisolated struct HerdrSubscriptionLines: Sendable {
    /// Every line herdr writes on it from then on, without the newline. It
    /// ends when herdr closes the connection, and throws when the
    /// connection fails; ending the iteration early — cancelling the task
    /// that iterates it — closes the connection.
    let lines: AsyncThrowingStream<Data, any Error>
    /// Closes the connection, which herdr takes for the subscriber having
    /// gone. Safe to call more than once, and from anywhere.
    let close: @Sendable () -> Void
}

/// Why a subscription couldn't be had or kept. None of these is shown to
/// the person: a monitor that can't subscribe goes on without (see
/// `MachineMonitor`).
nonisolated enum HerdrSubscriptionError: Error {
    /// The transport can't keep a connection open for a subscription.
    case unsupported
    /// The connection closed, or began with something else, before herdr
    /// acknowledged the subscription.
    case noAcknowledgement
    /// A line ran on past `HerdrLineBuffer.lineLimit` without ending.
    case lineTooLong
    /// herdr didn't acknowledge the subscription in time.
    case acknowledgementTimedOut
}

/// Cuts what arrives on a connection into herdr's lines, however the bytes
/// were split up on the way: a line may come in pieces, and one piece may
/// hold several lines.
nonisolated struct HerdrLineBuffer: Sendable {
    /// A line longer than this is not waited out: the connection is taken
    /// to be broken instead. herdr's lines on a subscription are one event
    /// each, a few kilobytes at the most.
    static let lineLimit = 1 * 1024 * 1024

    private var pending: [UInt8] = []

    init() {}

    /// Takes `bytes` and returns the lines they complete, without their
    /// newlines; the rest is kept for the next call. Blank lines are
    /// skipped — herdr never sends one. Throws
    /// `HerdrSubscriptionError.lineTooLong` once what is kept grows past
    /// `lineLimit`.
    mutating func append<Bytes: Sequence>(_ bytes: Bytes) throws -> [Data] where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var lines: [Data] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            if newline > start {
                lines.append(Data(pending[start..<newline]))
            }
            start = newline + 1
        }
        pending.removeSubrange(pending.startIndex..<start)
        guard pending.count <= Self.lineLimit else {
            throw HerdrSubscriptionError.lineTooLong
        }
        return lines
    }
}
