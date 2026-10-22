import Foundation
import Observation
#if canImport(Citadel)
import Citadel
#endif

/// Where a monitor passes on what it sees, besides keeping it for the
/// board: the notifications (`NotificationFeed`).
@MainActor public protocol MachineMonitorListener: AnyObject {
    /// A new connection, which the snapshots from now on come over.
    func connected(_ client: HerdrClient)
    /// A snapshot of the machine's own herdr (`herdrMachine` nil), or of one
    /// of its herdr machines.
    func observe(panes: [AgentSummary], tabs: [TabSummary]?, workspaces: [WorkspaceSummary]?, on herdrMachine: HerdrMachine?)
}

/// One machine's herdr, kept up to date over one connection for everyone
/// who wants to know it: the board, while it shows the machine, and the
/// notifications, while they watch it. `MachineMonitors` keeps one per
/// machine and has it run while either wants it.
///
/// It keeps up by subscribing to herdr's events (`events.subscribe`, see
/// `HerdrChangeSubscription`) and reading a snapshot (`session.snapshot`)
/// whenever one says something changed — paced by `HerdrRefreshSchedule`,
/// and every 25 s when nothing does. The events are only a sign: what the
/// board shows and the notifications go by always comes from a snapshot. A
/// herdr that won't take the subscription, or keeps dropping it, is kept up
/// with the way it was before there was one, for the rest of that
/// connection (see `keepUpToDateByPolling`). The herdr machines the host's
/// herdr has (`HerdrMachine`) can only be reached through its CLI, which
/// can't subscribe, so they are read every `Timing.herdrMachineInterval`.
///
/// A connection that fails is made again after a while, longer each time
/// it keeps failing — except after a failure no further attempt can get
/// past (`isPermanentFailure`), when it waits for the person to press
/// Retry (`retry`).
@MainActor @Observable
public final class MachineMonitor {
    /// One herdr machine's part of the board.
    public nonisolated struct HerdrMachineGroup: Identifiable, Equatable, Sendable {
        public let machine: HerdrMachine
        public var agents: [AgentSummary] = []
        /// Its tabs and workspaces, as for the host's (see
        /// `MachineMonitor.tabs` and `workspaces`).
        public var tabs: [TabSummary]?
        public var workspaces: [WorkspaceSummary]?
        /// Why the last attempt to list its panes failed. The panes from
        /// before the failure stay listed under it: a machine dropping off
        /// for a moment shouldn't empty its group.
        public var error: String?
        public var hasLoaded = false
        public var id: String { machine.id }
    }

    /// How long things take. Tests shorten them.
    public nonisolated struct Timing: Sendable {
        public var refresh = HerdrRefreshSchedule.Timing()
        /// How long herdr has to acknowledge a subscription before the
        /// connection does without one.
        public var acknowledgementTimeout: Duration = .seconds(5)
        /// How long a snapshot may take before the connection is taken for
        /// dead and made anew. A subscription that has been quiet for a long
        /// time says nothing about whether its SSH connection is still
        /// there; the snapshot read in between is what finds out.
        public var snapshotTimeout: Duration = .seconds(15)
        /// How often the panes on herdr machines are read. Each read is a
        /// herdr CLI run that opens an SSH connection of its own to the
        /// machine, so they are not read any more often than this.
        public var herdrMachineInterval: Duration = .seconds(5)
        /// How long a failed connection is left alone before the first new
        /// attempt. What usually breaks one — herdr not started yet, the
        /// machine asleep, the network gone — takes seconds to pass, and over
        /// SSH every attempt is a full handshake, so retrying any faster
        /// would only add load without recovering any sooner.
        public var firstReconnectDelay: Duration = .seconds(5)
        /// Where the wait between attempts stops growing. Each attempt that
        /// fails doubles it: a machine that has been unreachable for a minute
        /// is more likely switched off than about to answer. A minute still
        /// brings the board back by itself soon after the machine returns;
        /// anyone who doesn't want to wait has the Retry button.
        public var maximumReconnectDelay: Duration = .seconds(60)
        /// Without a subscription: how long herdr is asked to hold one
        /// `events.wait` open (see `waitForAnyPaneChange`).
        public var longPollTimeoutMs = 25_000
        /// Without a subscription: the shortest time between two snapshots
        /// while long-polling, so that a transport that answers
        /// `events.wait` without waiting can't turn the loop into a busy
        /// loop of requests.
        public var minimumLongPollRound: Duration = .seconds(1)
        /// Without a subscription: how long a long-poll round lasts on a
        /// machine with no agent to wait on.
        public var noAgentRound: Duration = .seconds(5)
        /// How long a monitor nobody wants any more keeps running, so that
        /// the board and the notifications handing a machine over to each
        /// other — the board leaving it as the window closes, say — don't
        /// cost a new connection.
        public var stopDelay: Duration = .seconds(1)

        public init() {}
    }

    // MARK: What it knows

    /// The host's panes, with their agents, from the last snapshot.
    public private(set) var panes: [AgentSummary] = []
    /// The host's tabs, or nil while its herdr hasn't reported any — before
    /// the first snapshot, or for good from a herdr too old to.
    public private(set) var tabs: [TabSummary]?
    /// The host's workspaces, which its rows are listed under, or nil as
    /// for `tabs`.
    public private(set) var workspaces: [WorkspaceSummary]?
    /// Whether `panes` is a list herdr reported rather than the empty one
    /// this starts out with. An empty list says nothing by itself: it is
    /// what a machine with no panes looks like, and also what a machine not
    /// heard from yet looks like.
    public private(set) var hasLoaded = false
    /// Why the last connection failed, until one gets through again. What
    /// was known before stays: the board keeps showing it under the error.
    public private(set) var loadError: String?
    /// Whether it will try again by itself after `loadError`, or has
    /// stopped until the person presses Retry (see `isPermanentFailure`).
    public private(set) var isRetrying = false
    /// The herdr machines saved on the host (see `HerdrMachine`), each with
    /// what was last heard from it. Empty while the host has none.
    public private(set) var herdrMachineGroups: [HerdrMachineGroup] = []
    /// Every herdr machine saved on the host, the disabled ones included,
    /// as last listed; nil until the host's herdr has listed them once over
    /// this connection — before that, and for good from a herdr older than
    /// 0.9.0, which has no saved machines.
    public private(set) var savedHerdrMachines: [HerdrMachine]?
    /// Why the host's herdr machines couldn't be listed the last time they
    /// were asked for, or nil once they were.
    public private(set) var herdrMachineListError: String?
    /// Whether the host's herdr is known to be older than 0.9.0: it turned
    /// listing herdr machines down as a command it doesn't know (see
    /// `herdrMachineListFailure`). False while that isn't known, and once
    /// the list comes back.
    public private(set) var herdrPredatesSavedMachines = false
    /// How many snapshots of the host's herdr have come since it started,
    /// and how many rounds over its herdr machines: what the board goes by
    /// to bring its selection up to date with each. Nought for none yet.
    public private(set) var snapshotCount = 0
    public private(set) var herdrMachineRoundCount = 0

    // MARK: How it connects

    private let makeClient: () throws -> HerdrClient?
    private let pinHostKey: (String) -> Void
    private let pollInterval: Duration
    private let listener: (any MachineMonitorListener)?
    private let isPermanent: (any Error) -> Bool
    public let timing: Timing

    @ObservationIgnored private var boardLeases = 0
    /// Whether the notifications want the machine watched.
    @ObservationIgnored public var isWatched = false {
        didSet {
            guard isWatched != oldValue else { return }
            updateRunning()
        }
    }
    @ObservationIgnored private var run: Task<Void, Never>?
    /// Tells one run from the one that replaced it, so that a run that has
    /// been cancelled doesn't take its successor for itself.
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var isWaitingToReconnect = false
    @ObservationIgnored private var isStoppedOnFailure = false
    @ObservationIgnored private var reconnectDelay: Duration
    private let reconnectAlarm = Alarm()

    /// - `makeClient` returns the client for one connection attempt, or nil
    ///   when there is nothing to connect to any more (the machine was
    ///   removed or edited), which ends the run. Each attempt gets a client
    ///   and transport of its own: what a transport was created with (the
    ///   pinned host key above all) is fixed for its lifetime, and may be out
    ///   of date by the next attempt. It throws when the client can't be put
    ///   together, which counts as a failed attempt like any other.
    /// - `pinHostKey` receives the fingerprint of a host key that a
    ///   connection has just trusted for the first time.
    /// - `pollInterval` is how often the host is read without a
    ///   subscription while no board shows it.
    public init(
        makeClient: @escaping () throws -> HerdrClient?,
        pinHostKey: @escaping (String) -> Void,
        pollInterval: Duration,
        listener: (any MachineMonitorListener)?,
        isPermanentFailure: @escaping (any Error) -> Bool = MachineMonitor.isPermanentFailure,
        timing: Timing = Timing()
    ) {
        self.makeClient = makeClient
        self.pinHostKey = pinHostKey
        self.pollInterval = pollInterval
        self.listener = listener
        self.isPermanent = isPermanentFailure
        self.timing = timing
        self.reconnectDelay = timing.firstReconnectDelay
    }

    // MARK: Who wants it

    /// Whether a board or the notifications want it, or it is still
    /// running.
    public var isActive: Bool {
        isWanted || run != nil
    }

    private var isWanted: Bool {
        boardLeases > 0 || isWatched
    }

    /// Whether a board shows the machine.
    public var isShownOnBoard: Bool {
        boardLeases > 0
    }

    /// Keeps it running for a board, for as long as the calling task — the
    /// board's — runs. Returns once that has been cancelled.
    ///
    /// A board coming to a machine whose connection is failing tries again
    /// at once, as a board used to when it had a connection of its own: the
    /// person is looking now, and the failure may well have passed.
    public func holdForBoard() async {
        // SwiftUI can cancel a task before its body has run at all.
        guard !Task.isCancelled else { return }
        boardLeases += 1
        if boardLeases == 1 {
            if isWaitingToReconnect || isStoppedOnFailure {
                retry()
            }
            session?.boardChanged()
        }
        updateRunning()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        boardLeases -= 1
        if boardLeases == 0 {
            session?.boardChanged()
        }
        updateRunning()
    }

    private func updateRunning() {
        if isWanted {
            stopTask?.cancel()
            stopTask = nil
            if run == nil && !isStoppedOnFailure {
                start()
            }
        } else if stopTask == nil {
            stopTask = Task {
                guard (try? await Task.sleep(for: timing.stopDelay)) != nil else { return }
                stopTask = nil
                if !isWanted {
                    stop()
                }
            }
        }
    }

    private func start() {
        runID += 1
        let id = runID
        reconnectDelay = timing.firstReconnectDelay
        run = Task {
            await keepConnected()
            if runID == id {
                run = nil
            }
        }
    }

    /// Closes the connection, and forgets what it knew: started again, it
    /// starts out loading, as for a machine not looked at before.
    private func stop() {
        cancelRun()
        isStoppedOnFailure = false
        panes = []
        tabs = nil
        workspaces = nil
        hasLoaded = false
        loadError = nil
        isRetrying = false
        herdrMachineGroups = []
        savedHerdrMachines = nil
        herdrMachineListError = nil
        herdrPredatesSavedMachines = false
        snapshotCount = 0
        herdrMachineRoundCount = 0
    }

    /// Whether herdr machines can be added to the host and removed from it
    /// now: its herdr listed them the last time it was asked.
    public var canManageHerdrMachines: Bool {
        savedHerdrMachines != nil && herdrMachineListError == nil
    }

    /// Why herdr machines can't be added or removed now, or nil when they
    /// can — or when it isn't known yet.
    public var herdrMachineManagementBlocker: String? {
        if let herdrMachineListError { return herdrMachineListError }
        return savedHerdrMachines == nil ? String(localized: "Loading…", bundle: .shepherdKit) : nil
    }

    private func cancelRun() {
        run?.cancel()
        run = nil
        runID += 1
        session?.end()
        session = nil
        isWaitingToReconnect = false
    }

    /// Starts over with a new connection straight away: whether it was
    /// waiting to reconnect, or had stopped after a failure no attempt of
    /// its own could get past. What it knew stays until the new connection
    /// brings something; the failure doesn't, since it says nothing about
    /// the new attempt.
    public func retry() {
        cancelRun()
        isStoppedOnFailure = false
        loadError = nil
        if isWanted {
            start()
        }
    }

    /// Reads everything again now, over the connection there is — after a
    /// change made from the board, so that it shows at once. While waiting
    /// to reconnect, reconnects now instead.
    public func refreshNow() {
        if let session {
            session.refreshWanted()
        } else if isWaitingToReconnect {
            reconnectAlarm.ring()
        }
    }

    // MARK: Connecting

    /// Connects, keeps up to date for as long as the connection works, and
    /// after a failure starts over with a new connection instead of giving
    /// up — `firstReconnectDelay` after a connection that had kept working
    /// for a while, twice as long after every attempt that didn't, up to
    /// `maximumReconnectDelay`. Reading one snapshot isn't enough to count
    /// as working: a connection that reads one and then fails the same way
    /// on every attempt would otherwise be retried at the shortest delay
    /// for good. Ends when cancelled, when there is nothing to connect to
    /// any more, or after a failure `isPermanentFailure` says no further
    /// attempt can get past.
    private func keepConnected() async {
        while !Task.isCancelled {
            // What ended this attempt. Nil means it was not a failure but the
            // task being cancelled.
            let failure: (any Error)?
            do {
                guard let client = try makeClient() else { return }
                // Cancellation doesn't reach into every await of a
                // connection: Citadel's NIO-backed ones (EventLoopFuture.get())
                // don't check for it, so a cancelled run would leave its SSH
                // connection open for as long as they last. Closing the
                // connection — which closes every channel on it — is what
                // ends them, so onCancel does that straight away.
                //
                // That same disconnect makes whatever this is awaiting fail
                // (or, for awaits that can't be interrupted, return late),
                // and by then what it knows belongs to whichever run replaced
                // this one. So every await below is followed by a
                // cancellation check before anything is touched, and a
                // failure that arrives after cancellation is dropped rather
                // than reported — it was caused by leaving, not by the
                // machine.
                failure = await withTaskCancellationHandler {
                    var reported: (any Error)?
                    do {
                        try await client.connect()
                        try Task.checkCancellation()
                        if let newFingerprint = await client.newlyPinnedHostKeyFingerprint() {
                            try Task.checkCancellation()
                            pinHostKey(newFingerprint)
                        }
                        listener?.connected(client)
                        try await keepUpToDate(over: client)
                    } catch {
                        if !Task.isCancelled {
                            report(error)
                            reported = error
                        }
                    }
                    // Keeping up only ends by failing or by being cancelled,
                    // and either way this connection has no further use.
                    // onCancel alone doesn't cover it: when cancellation
                    // lands while connect() is still in flight there is
                    // nothing for it to close yet, and the connection that
                    // connect() then goes on to establish would stay open
                    // with no one left to close it.
                    await client.disconnect()
                    return reported
                } onCancel: {
                    Task { await client.disconnect() }
                }
            } catch {
                // There is no client, so nothing was connected and nothing
                // needs closing. Nothing has been awaited since the loop
                // last saw the task alive, either.
                report(error)
                failure = error
            }
            guard let failure else { return }
            if isPermanent(failure) {
                isStoppedOnFailure = true
                return
            }
            isWaitingToReconnect = true
            do {
                try await reconnectAlarm.wait(until: .now + reconnectDelay)
            } catch {
                return
            }
            isWaitingToReconnect = false
            reconnectDelay = min(reconnectDelay * 2, timing.maximumReconnectDelay)
        }
    }

    private func report(_ error: any Error) {
        loadError = connectionFailureDescription(error)
        isRetrying = !isPermanent(error)
        // With no rows there is no last known list worth keeping, and "No
        // Panes" would go on claiming something about a machine that can't
        // be reached. The next attempt starts from "Loading panes…" instead.
        if panes.isEmpty && hasLoaded {
            hasLoaded = false
        }
    }

    /// Keeps up to date over `client` until that fails; only ever ends by
    /// throwing.
    private func keepUpToDate(over client: HerdrClient) async throws {
        let session = Session(client: client, timing: timing.refresh)
        self.session = session
        defer {
            session.end()
            if self.session === session {
                self.session = nil
            }
        }
        session.herdrMachines = Task {
            await keepHerdrMachinesUpToDate(session)
        }
        try await keepUpToDateBySubscription(session)
        try await keepUpToDateByPolling(session)
    }

    /// Shows a snapshot of the host's herdr, and passes it on.
    private func show(_ snapshot: HerdrSnapshot, in session: Session) {
        if loadError != nil {
            loadError = nil
        }
        if !hasLoaded {
            hasLoaded = true
        }
        if panes != snapshot.panes {
            panes = snapshot.panes
        }
        if tabs != snapshot.tabs {
            tabs = snapshot.tabs
        }
        if workspaces != snapshot.workspaces {
            workspaces = snapshot.workspaces
        }
        snapshotCount += 1
        listener?.observe(panes: snapshot.panes, tabs: snapshot.tabs, workspaces: snapshot.workspaces, on: nil)
        // A second snapshot over the same connection: it has kept working
        // for a whole round, so whatever goes wrong from here on is a new
        // outage, not more of the one the delay had grown for.
        session.snapshotsRead += 1
        if session.snapshotsRead > 1 {
            reconnectDelay = timing.firstReconnectDelay
        }
    }

    /// Reads a snapshot, giving up after `snapshotTimeout`.
    private func readSnapshot(_ session: Session) async throws -> HerdrSnapshot {
        let client = session.client
        return try await withTimeout(timing.snapshotTimeout, error: SnapshotTimedOut()) {
            try await client.snapshot()
        }
    }

    // MARK: With a subscription

    private enum SubscriptionOutcome {
        case started
        /// One of the panes named is gone.
        case paneGone
        /// No subscription to be had on this connection.
        case unusable
    }

    /// Keeps up with the subscription for as long as there is one to be had
    /// (see `HerdrRefreshSchedule` for when a snapshot is read). Returns
    /// when there isn't: herdr turned it down with anything but a pane being
    /// gone, didn't acknowledge it within `acknowledgementTimeout`, or it
    /// failed too often — and the rest of the connection does without.
    /// Throws when a snapshot can't be read, which ends the connection.
    ///
    /// herdr's documentation has the subscription opened before the
    /// snapshot it is to keep up to date is read, so that nothing happens
    /// unseen in between; and since only the panes named in it report their
    /// status, it is opened again whenever the panes with an agent change —
    /// the new one before the old one is closed, and followed by a snapshot,
    /// to cover the moment in between.
    private func keepUpToDateBySubscription(_ session: Session) async throws {
        // The panes with an agent as last known, from an earlier
        // connection: a guess, which the first snapshot corrects.
        var agentPanes = Self.agentPanes(panes)
        // Set while the panes to subscribe for are known to be out of date:
        // after one of them turned out to be gone, until the next snapshot.
        var awaitingPanes = false
        while true {
            try Task.checkCancellation()
            if session.subscriptionEnded {
                session.subscriptionEnded = false
                if session.schedule.subscriptionFailed(at: .now) {
                    return
                }
            }
            if !awaitingPanes, HerdrRefreshSchedule.needsSubscription(subscribed: session.subscribedPanes, agentPanes: agentPanes) {
                switch try await subscribe(session, to: agentPanes) {
                case .started:
                    session.schedule.snapshotWanted(at: .now)
                case .paneGone:
                    // It closed between the snapshot and the subscription:
                    // read which panes there are now, and try with those.
                    if session.schedule.subscriptionFailed(at: .now) {
                        return
                    }
                    awaitingPanes = true
                    session.schedule.snapshotWanted(at: .now)
                case .unusable:
                    return
                }
            }
            let due = session.schedule.nextSnapshot(now: .now)
            if due > .now {
                try await session.alarm.wait(until: due)
                continue
            }
            session.schedule.snapshotStarted(at: .now)
            let snapshot = try await readSnapshot(session)
            try Task.checkCancellation()
            session.schedule.snapshotFinished(at: .now)
            show(snapshot, in: session)
            agentPanes = Self.agentPanes(snapshot.panes)
            awaitingPanes = false
        }
    }

    private static func agentPanes(_ panes: [AgentSummary]) -> Set<String> {
        Set(panes.filter(\.hasAgent).map(\.paneID))
    }

    private func subscribe(_ session: Session, to paneIDs: Set<String>) async throws -> SubscriptionOutcome {
        let client = session.client
        let subscription: HerdrSubscriptionLines
        do {
            subscription = try await withTimeout(timing.acknowledgementTimeout, error: HerdrSubscriptionError.acknowledgementTimedOut, discard: { $0.close() }) {
                try await client.subscribeToChanges(statusOf: paneIDs)
            }
        } catch let error as HerdrErrorPayload where error.code == "pane_not_found" {
            try Task.checkCancellation()
            return .paneGone
        } catch {
            try Task.checkCancellation()
            return .unusable
        }
        guard !Task.isCancelled else {
            subscription.close()
            throw CancellationError()
        }
        session.open(subscription, for: paneIDs)
        return .started
    }

    // MARK: Without a subscription

    /// Keeps up the way it was done before there was a subscription. While
    /// a board shows the machine: a long-poll per pane and status it could
    /// change to (`waitForAnyPaneChange`), and a snapshot as soon as one
    /// ends, or every 25 s. While only the notifications watch it: a
    /// snapshot every `pollInterval`. Only ever ends by throwing.
    private func keepUpToDateByPolling(_ session: Session) async throws {
        session.closeSubscription()
        while true {
            let roundStart = ContinuousClock.now
            let snapshot = try await readSnapshot(session)
            try Task.checkCancellation()
            show(snapshot, in: session)
            if isShownOnBoard {
                try await waitForAnyPaneChange(session, panes: snapshot.panes)
                let remaining = timing.minimumLongPollRound - (ContinuousClock.now - roundStart)
                if remaining > .zero {
                    try await session.alarm.wait(until: .now + remaining)
                }
            } else {
                try await session.alarm.wait(until: .now + pollInterval)
            }
        }
    }

    /// `waitForAnyPaneChange`, cut short by the alarm: a refresh asked for,
    /// or a board coming or going.
    private func waitForAnyPaneChange(_ session: Session, panes: [AgentSummary]) async throws {
        let outcome = WaitOutcome()
        let client = session.client
        let timing = self.timing
        let wait = Task {
            do {
                try await Self.waitForAnyPaneChange(client: client, panes: panes, timing: timing)
            } catch {
                outcome.error = error
            }
            if !Task.isCancelled {
                session.alarm.ring()
            }
        }
        defer { wait.cancel() }
        try await session.alarm.wait(until: .now + .seconds(24 * 3600))
        if let error = outcome.error, !(error is CancellationError) {
            throw error
        }
    }

    /// Returns when something on the board may have changed — or, failing
    /// that, when it has been long enough that the list is worth reading
    /// again anyway. Throws when the connection fails, when herdr answers a
    /// wait with an error that isn't about the pane having gone, or when the
    /// task is cancelled.
    ///
    /// herdr's `events.wait` holds a request until one pane reaches one
    /// status, so noticing a change of status takes a concurrent wait per
    /// pane for every status it could move to (`awaitedStatuses`). Whichever
    /// way a pane goes — into `blocked` or `done`, or back out of them when
    /// it is given something new to do — one of its waits matches, and the
    /// first wait to end, by matching or by timing out, ends the round.
    ///
    /// A status the pane already has is not waited for. herdr answers such a
    /// wait at once instead of holding it, so every round would end
    /// immediately, and the loop would read the list again at its floor for
    /// as long as the board was open.
    ///
    /// Nor is a pane with no agent in it: it has no status to change. An
    /// agent starting in one shows up the way a pane opening does, when the
    /// round ends.
    private static func waitForAnyPaneChange(client: HerdrClient, panes: [AgentSummary], timing: Timing) async throws {
        let agents = panes.filter(\.hasAgent)
        guard !agents.isEmpty else {
            try await Task.sleep(for: timing.noAgentRound)
            return
        }
        // Never empty: there are more statuses to wait for than the one a
        // pane can have, so every pane brings at least one wait.
        let waits = agents.flatMap { agent in
            awaitedStatuses
                .filter { $0 != agent.state }
                .map { (paneID: agent.paneID, status: $0) }
        }
        let timeoutMs = timing.longPollTimeoutMs
        try await withThrowingTaskGroup(of: Void.self) { group in
            for wait in waits {
                group.addTask {
                    do {
                        _ = try await client.waitForPaneStatus(paneID: wait.paneID, status: wait.status, timeoutMs: timeoutMs)
                    } catch let error as HerdrErrorPayload where error.code == "pane_not_found" {
                        // The pane closed while being waited on, or between
                        // the list and the wait. That is exactly the kind of
                        // change the list has to be read again for, so it
                        // ends the round like a match would.
                        //
                        // No other error herdr answers a wait with is taken
                        // for a change. One that herdr gives every time (a
                        // version that turns the match down, say) comes
                        // back at once, and treated as a change it would
                        // have the loop reading the list at its floor with
                        // nothing on screen to say anything is wrong.
                        // Thrown, it ends the connection and is shown.
                    }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// The statuses a pane is watched for moving into: every one that says
    /// something about an agent. herdr 0.9.1's `events.wait` takes any of
    /// its five agent statuses in a match (see
    /// `HerdrClient.waitForPaneStatus`), so leaving `unknown` out is a
    /// choice rather than a limit. It is what herdr reports when it doesn't
    /// recognise what runs in a pane; a pane drifting into it is nothing
    /// that has to be shown at once, and not worth a further long-poll per
    /// pane.
    private static let awaitedStatuses: [AgentState] = [.idle, .working, .blocked, .done]

    // MARK: herdr machines

    /// Reads the host's herdr machines and every one's panes and tabs, every
    /// `herdrMachineInterval`, for as long as the connection lasts. The list
    /// of machines is read again each time, so one added or removed in
    /// herdr appears or goes without anything restarting. A host whose herdr
    /// has no saved machines gives no groups, and the board stays a flat
    /// list. One that can't list them — too old to know about them, or with
    /// its CLI out of reach — is asked again less and less often, and its
    /// groups keep what they last showed meanwhile; if the connection itself
    /// is what failed, reading the host's snapshot finds that out.
    private func keepHerdrMachinesUpToDate(_ session: Session) async {
        var failureDelay = timing.herdrMachineInterval
        while !Task.isCancelled {
            let delay: Duration
            let listed: [HerdrMachine]?
            do {
                listed = try await session.client.listAllHerdrMachines()
            } catch {
                guard !Task.isCancelled else { return }
                // Kept with its reason rather than dropped: it is what the
                // menus that add and remove herdr machines are greyed out
                // for, and what the new tab launcher says in their place.
                let reason = Self.herdrMachineListFailure(error)
                if herdrMachineListError != reason {
                    herdrMachineListError = reason
                }
                // Kept through other failures: they don't make herdr newer.
                if Self.isUnknownMachineCommand(error), !herdrPredatesSavedMachines {
                    herdrPredatesSavedMachines = true
                }
                listed = nil
            }
            if let listed {
                guard !Task.isCancelled else { return }
                if savedHerdrMachines != listed {
                    savedHerdrMachines = listed
                }
                if herdrMachineListError != nil {
                    herdrMachineListError = nil
                }
                if herdrPredatesSavedMachines {
                    herdrPredatesSavedMachines = false
                }
                let machines = listed.filter(\.enabled)
                let groups = await Self.fetchSnapshots(on: machines, previous: herdrMachineGroups, client: session.client)
                guard !Task.isCancelled else { return }
                show(groups)
                failureDelay = timing.herdrMachineInterval
                delay = timing.herdrMachineInterval
            } else {
                guard !Task.isCancelled else { return }
                delay = failureDelay
                failureDelay = min(failureDelay * 2, timing.maximumReconnectDelay)
            }
            do {
                try await session.herdrMachineAlarm.wait(until: .now + delay)
            } catch {
                return
            }
        }
    }

    /// Shows a round over the herdr machines, and passes on the machines
    /// listed this time. One that couldn't be reached still has the panes it
    /// last listed, which say nothing new.
    private func show(_ groups: [HerdrMachineGroup]) {
        if groups != herdrMachineGroups {
            herdrMachineGroups = groups
        }
        herdrMachineRoundCount += 1
        for group in groups where group.error == nil && group.hasLoaded {
            listener?.observe(panes: group.agents, tabs: group.tabs, workspaces: group.workspaces, on: group.machine)
        }
    }

    /// One round over the machines: all of them at once, each on its own, so
    /// one that is slow or down neither holds up nor hides the others. A
    /// machine that fails keeps the panes and tabs it last listed, under its
    /// error.
    public static func fetchSnapshots(
        on machines: [HerdrMachine],
        previous: [HerdrMachineGroup],
        client: HerdrClient
    ) async -> [HerdrMachineGroup] {
        let results = await withTaskGroup(of: (Int, HerdrSnapshot?, String?).self) { group in
            for (index, machine) in machines.enumerated() {
                group.addTask {
                    // The snapshot is taken into a constant of its own before
                    // the tuple is made. With `return (index, try await …,
                    // nil)` here and `return (index, nil, …)` in the catch,
                    // Swift 6.3 and 6.4 drop the store of `index` in an -O
                    // build (swiftlang/swift#92698), and the result lands in
                    // the wrong place or out of bounds — the crash of 0.3.3
                    // (SHPHRD-54).
                    do {
                        let snapshot = try await client.snapshot(on: machine)
                        return (index, snapshot, nil)
                    } catch {
                        return (index, nil, connectionFailureDescription(error))
                    }
                }
            }
            var results = [(snapshot: HerdrSnapshot?, error: String?)](repeating: (nil, nil), count: machines.count)
            for await (index, snapshot, error) in group {
                results[index] = (snapshot, error)
            }
            return results
        }
        return zip(machines, results).map { machine, result in
            let last = previous.first { $0.id == machine.id }
            if let snapshot = result.snapshot {
                return HerdrMachineGroup(
                    machine: machine,
                    agents: snapshot.panes,
                    tabs: snapshot.tabs,
                    workspaces: snapshot.workspaces,
                    error: nil,
                    hasLoaded: true
                )
            }
            return HerdrMachineGroup(
                machine: machine,
                agents: last?.agents ?? [],
                tabs: last?.tabs,
                workspaces: last?.workspaces,
                error: result.error,
                hasLoaded: last?.hasLoaded ?? false
            )
        }
    }

    // MARK: Failures

    /// Whether a failed connection attempt is one that another attempt
    /// cannot get past: it would fail the same way every time, until the
    /// person changes something. This is the one place that decides it, and
    /// a monitor stops reconnecting on its own when the answer is yes.
    ///
    /// The cost of getting it wrong is not symmetric. Retrying a failure
    /// that will not pass means presenting the same rejected credential to
    /// sshd over and over for as long as the machine is watched, which is
    /// what fail2ban, sshd's own per-source penalties and account lockouts
    /// exist to punish. Stopping at a failure that would have passed only
    /// costs a press of Retry. Even so the list is short and specific, and
    /// everything not on it — a refused or lost connection, a timeout, herdr
    /// not running, a Keychain that can't be read right now — is retried:
    /// - the stored key is not one this app can use (`OpenSSHKeyError`);
    /// - the server's host key is not the one pinned for this machine
    ///   (`HostKeyValidationError`): either it was reinstalled or someone is
    ///   in the middle, and neither changes by asking again;
    /// - the server turned the credential down, or doesn't offer the kind of
    ///   authentication this machine is set up for (Citadel's
    ///   `SSHClientError`, except for its one case that isn't about
    ///   authentication), or — for a Mac paired by QR code — turned the
    ///   device's key down (`PairedConnectionError.accessRemoved`).
    ///
    /// All of these come from the SSH transport, so a build without Citadel
    /// has no such failure.
    public nonisolated static func isPermanentFailure(_ error: any Error) -> Bool {
        #if canImport(Citadel)
        switch error {
        case is OpenSSHKeyError, is HostKeyValidationError, PairedConnectionError.accessRemoved:
            return true
        case SSHClientError.allAuthenticationOptionsFailed,
             SSHClientError.unsupportedPasswordAuthentication,
             SSHClientError.unsupportedPrivateKeyAuthentication,
             SSHClientError.unsupportedHostBasedAuthentication:
            return true
        default:
            return false
        }
        #else
        return false
        #endif
    }

    /// What to say for a host whose herdr couldn't list its herdr machines.
    /// A herdr older than 0.9.0, which brought saved machines, turns the
    /// `machine` command down as one it doesn't know (exit status 2,
    /// "unknown command: machine" — herdr 0.9.1's own check for commands it
    /// doesn't have, src/main.rs), and that is said in so many words.
    public nonisolated static func herdrMachineListFailure(_ error: any Error) -> String {
        if isUnknownMachineCommand(error) {
            return String(localized: "This machine's herdr is older than 0.9.0, the first to save machines. Update herdr to add machines to it.", bundle: .shepherdKit)
        }
        return connectionFailureDescription(error)
    }

    /// Whether `error` is herdr turning `machine` down as a command it
    /// doesn't know, which a herdr older than 0.9.0 does.
    nonisolated static func isUnknownMachineCommand(_ error: any Error) -> Bool {
        (error as? HerdrCommandError)?.message.contains("unknown command: machine") == true
    }

    /// A snapshot that didn't come back within `snapshotTimeout`.
    public nonisolated struct SnapshotTimedOut: Error, LocalizedError {
        public var errorDescription: String? {
            String(localized: "The machine didn't answer in time.", bundle: .shepherdKit)
        }
    }
}

/// What one connection is up to.
@MainActor
private final class Session {
    let client: HerdrClient
    var schedule: HerdrRefreshSchedule
    /// Wakes the loop keeping the host up to date: something changed, a
    /// refresh is wanted, the subscription ended, a board came or went.
    let alarm = Alarm()
    /// Wakes the loop over the herdr machines, for a refresh.
    let herdrMachineAlarm = Alarm()
    var herdrMachines: Task<Void, Never>?
    /// The panes whose status the open subscription reports, or nil while
    /// none is open.
    private(set) var subscribedPanes: Set<String>?
    /// Set when the open subscription has ended, by herdr or by failing.
    var subscriptionEnded = false
    var snapshotsRead = 0
    private var subscription: HerdrSubscriptionLines?
    private var reader: Task<Void, Never>?
    private var generation = 0

    init(client: HerdrClient, timing: HerdrRefreshSchedule.Timing) {
        self.client = client
        self.schedule = HerdrRefreshSchedule(timing: timing)
    }

    /// Takes `new`, just acknowledged, for the subscription, and closes the
    /// one it replaces.
    func open(_ new: HerdrSubscriptionLines, for paneIDs: Set<String>) {
        let replaced = (subscription: subscription, reader: reader)
        generation += 1
        let mine = generation
        subscription = new
        subscribedPanes = paneIDs
        subscriptionEnded = false
        reader = Task {
            do {
                reading: for try await line in new.lines {
                    switch HerdrStreamLine(line) {
                    case .change:
                        schedule.changed(at: .now)
                        alarm.ring()
                    case .failure:
                        // herdr closes the connection after an error
                        // (`events_lost`, say): the subscription is over.
                        break reading
                    case .started, .unrecognized:
                        continue
                    }
                }
            } catch {}
            guard !Task.isCancelled, mine == generation else { return }
            new.close()
            subscribedPanes = nil
            subscriptionEnded = true
            alarm.ring()
        }
        replaced.reader?.cancel()
        replaced.subscription?.close()
    }

    func closeSubscription() {
        reader?.cancel()
        reader = nil
        subscription?.close()
        subscription = nil
        subscribedPanes = nil
    }

    func refreshWanted() {
        schedule.snapshotWanted(at: .now)
        alarm.ring()
        herdrMachineAlarm.ring()
    }

    /// Without a subscription, what is waited for depends on whether a
    /// board shows the machine (see `MachineMonitor.keepUpToDateByPolling`).
    func boardChanged() {
        alarm.ring()
    }

    func end() {
        closeSubscription()
        herdrMachines?.cancel()
        herdrMachines = nil
    }
}

/// Something a loop waits on until a deadline, unless it is rung first.
@MainActor
private final class Alarm {
    private var sleeper: Task<Void, Never>?
    private var isRung = false

    /// Waits until `deadline`, or until `ring` — returning at once if it has
    /// been rung since the last wait. Throws `CancellationError` once the
    /// calling task has been cancelled.
    func wait(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        if isRung {
            isRung = false
            return
        }
        let sleeper = Task<Void, Never> {
            try? await Task.sleep(until: deadline)
        }
        self.sleeper = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        if self.sleeper == sleeper {
            self.sleeper = nil
        }
        isRung = false
        try Task.checkCancellation()
    }

    func ring() {
        isRung = true
        sleeper?.cancel()
    }
}

/// How a wait run in a task of its own ended.
@MainActor
private final class WaitOutcome {
    var error: (any Error)?
}

/// Runs `operation`, giving up on it after `timeout` by throwing
/// `timeoutError`. Unlike a task group, which waits for every task it
/// started, this doesn't wait for an operation that doesn't notice being
/// cancelled (Citadel's channel opening doesn't): it is cancelled and left
/// to end on its own, and what it comes back with after all is handed to
/// `discard`.
@MainActor
private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    error timeoutError: any Error,
    discard: @escaping @Sendable (T) -> Void = { _ in },
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = Race<T>()
    let work = Task {
        do {
            let value = try await operation()
            if !race.finish(.success(value)) {
                discard(value)
            }
        } catch {
            race.finish(.failure(error))
        }
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        race.finish(.failure(timeoutError))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
        }
    } onCancel: {
        Task { @MainActor in race.finish(.failure(CancellationError())) }
    }
}

/// The first of several outcomes, handed to whoever waits for it.
@MainActor
private final class Race<T: Sendable> {
    private var continuation: CheckedContinuation<T, any Error>?
    private var outcome: Result<T, any Error>?

    func begin(_ continuation: CheckedContinuation<T, any Error>) {
        if let outcome {
            continuation.resume(with: outcome)
        } else {
            self.continuation = continuation
        }
    }

    /// Returns whether `result` was the first.
    @discardableResult
    func finish(_ result: Result<T, any Error>) -> Bool {
        guard outcome == nil else { return false }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
        return true
    }
}
