import Foundation

/// When a machine's monitor reads herdr's snapshot again, and when it gives
/// up on its subscription for the rest of a connection (see
/// `MachineMonitor`). Only the rules: the times are handed in, so that they
/// can be tried out without waiting for any of them.
///
/// The events of a subscription are only taken for a sign that something
/// changed. What changed is read from a snapshot, so that the board and the
/// notifications always see herdr as one consistent whole, however many
/// events came, in whatever order, or whether any went missing on the way.
/// So:
/// - A change is given `gather` for more to come with it — a split brings a
///   new pane and a new layout, a new tab both of those as well — before the
///   snapshot is read, once for all of them.
/// - Two snapshots are started at least `minimumInterval` apart, however
///   often things change: an agent that retitles its terminal every few
///   milliseconds costs two snapshots a second, not hundreds.
/// - A change that comes while a snapshot is being read may or may not be in
///   it, so it is read again afterwards.
/// - After `idleRefresh` without any, it is read anyway: some changes come
///   with no event (a pane renamed, a working directory changed), and herdr
///   0.9.1 and older drop events silently when they come too fast.
public nonisolated struct HerdrRefreshSchedule: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public nonisolated struct Timing: Sendable {
        public var gather: Duration = .milliseconds(100)
        public var minimumInterval: Duration = .milliseconds(500)
        /// As long as `events.wait` long-polls were held for before there
        /// was a subscription, which was how soon a change without a status
        /// change showed then; well within the 60 s after which the
        /// notifications take a snapshot for a fresh start
        /// (`AgentEventDeriver.maximumGap`).
        public var idleRefresh: Duration = .seconds(25)
        /// A subscription that fails `failureLimit` times within
        /// `failureWindow` is given up on for the rest of the connection.
        public var failureWindow: Duration = .seconds(60)
        public var failureLimit = 3

        public init() {}
    }

    public let timing: Timing
    /// When the last snapshot was started, and when it came back.
    public private(set) var lastStart: Instant?
    public private(set) var lastFinish: Instant?
    /// When the next snapshot is due for a change or a request it hasn't
    /// been read for yet — before `minimumInterval` has its say.
    public private(set) var pendingDue: Instant?
    /// When the subscription failed lately.
    private var failures: [Instant] = []

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// herdr reported a change at `time`. One from before the last snapshot
    /// was started is in that snapshot already.
    public mutating func changed(at time: Instant) {
        if let lastStart, time < lastStart { return }
        due(time + timing.gather)
    }

    /// A snapshot is wanted as soon as `minimumInterval` allows, without
    /// waiting for more changes: when a subscription has just been opened,
    /// to catch up with whatever happened before it was, or when asked to
    /// refresh.
    public mutating func snapshotWanted(at time: Instant) {
        due(time)
    }

    private mutating func due(_ time: Instant) {
        pendingDue = min(pendingDue ?? time, time)
    }

    /// Reading a snapshot started at `time`: it takes in every change from
    /// before then.
    public mutating func snapshotStarted(at time: Instant) {
        lastStart = time
        pendingDue = nil
    }

    public mutating func snapshotFinished(at time: Instant) {
        lastFinish = time
    }

    /// When the next snapshot is to be started. At or before `now` means
    /// straight away — as for the first one, when none has been read yet.
    public func nextSnapshot(now: Instant) -> Instant {
        if let pendingDue {
            guard let lastStart else { return pendingDue }
            return max(pendingDue, lastStart + timing.minimumInterval)
        }
        guard let lastFinish else { return now }
        return lastFinish + timing.idleRefresh
    }

    /// The subscription failed at `time`: it ended, or a new one couldn't be
    /// opened. Returns whether that is one time too many, and the rest of
    /// the connection is to do without.
    public mutating func subscriptionFailed(at time: Instant) -> Bool {
        failures = failures.filter { time - $0 < timing.failureWindow } + [time]
        return failures.count >= timing.failureLimit
    }

    /// Whether the subscription has to be opened again for the panes with
    /// an agent in them now: herdr only reports the status of the panes
    /// named when subscribing. `subscribed` is nil while none is open.
    public static func needsSubscription(subscribed: Set<String>?, agentPanes: Set<String>) -> Bool {
        subscribed != agentPanes
    }
}
