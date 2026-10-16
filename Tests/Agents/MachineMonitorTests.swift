import Foundation

/// `MachineMonitor` with the real `HerdrClient` over a fake transport: the
/// subscription and what it reads when, doing without one, reconnecting,
/// the herdr machines, and starting and stopping for a board. Times are
/// shortened (see `timing`); nothing leaves the process.
@main struct MachineMonitorTests {
    static func main() async {
        // Line by line, so that what passed before a failure is not lost
        // with the buffer.
        setvbuf(stdout, nil, _IOLBF, 0)
        await subscriptionPath()
        await burstOfChanges()
        await changeDuringRead()
        await agentStartedResubscribes()
        await paneGoneWhileSubscribing()
        await subscriptionEndingFallsBackAfterThree()
        await unsupportedWithBoardLongPolls()
        await unsupportedWatchedOnlyPolls()
        await unacknowledgedFallsBack()
        await refusedFallsBack()
        await refreshDoesNotReconnect()
        await permanentFailureWaitsForRetry()
        await passingFailureRetriesByItself()
        await herdrMachinesArePolled()
        await boardLeaseAndStopDelay()
        await connectedOncePerConnection()
        await snapshotTimeoutReconnects()
        await boardComingToFailingMachineRetriesAtOnce()
    }

    // MARK: Helpers

    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        print("PASS: " + name)
    }

    static func eventually(_ name: String, seconds: Double = 3, _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if await condition() {
                print("PASS: " + name)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        print("FAIL: " + name); preconditionFailure(name)
    }

    static func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func timing() -> MachineMonitor.Timing {
        var timing = MachineMonitor.Timing()
        timing.refresh.gather = .milliseconds(20)
        timing.refresh.minimumInterval = .milliseconds(100)
        timing.refresh.idleRefresh = .milliseconds(800)
        timing.acknowledgementTimeout = .milliseconds(300)
        timing.snapshotTimeout = .milliseconds(600)
        timing.herdrMachineInterval = .milliseconds(250)
        timing.firstReconnectDelay = .milliseconds(100)
        timing.maximumReconnectDelay = .milliseconds(400)
        timing.longPollTimeoutMs = 400
        timing.minimumLongPollRound = .milliseconds(50)
        timing.noAgentRound = .milliseconds(200)
        timing.stopDelay = .milliseconds(300)
        return timing
    }

    final class Fixture {
        let fake: FakeHerdr
        let listener = Listener()
        var clients = 0
        var monitor: MachineMonitor!
        var board: Task<Void, Never>?

        init(_ fake: FakeHerdr = FakeHerdr(), timing: MachineMonitor.Timing = MachineMonitorTests.timing(), pollInterval: Duration = .milliseconds(150)) {
            self.fake = fake
            monitor = MachineMonitor(
                makeClient: { [unowned self] in
                    clients += 1
                    return HerdrClient(transport: fake)
                },
                pinHostKey: { _ in },
                pollInterval: pollInterval,
                listener: listener,
                isPermanentFailure: { $0 is PermanentTestFailure },
                timing: timing
            )
        }

        func showOnBoard() {
            let monitor = monitor!
            board = Task { await monitor.holdForBoard() }
        }

        func leaveBoard() {
            board?.cancel()
            board = nil
        }

        func finish() async {
            leaveBoard()
            monitor.isWatched = false
            await MachineMonitorTests.eventually("cleanup: the monitor stops once nobody wants it") { !monitor.isActive }
        }

        func title(of paneID: String) -> String? {
            monitor.panes.first { $0.paneID == paneID }?.terminalTitle
        }
    }

    // MARK: With a subscription

    static func subscriptionPath() async {
        let fixture = Fixture()
        let fake = fixture.fake, monitor = fixture.monitor!
        fixture.showOnBoard()
        await eventually("subscription: the first snapshot comes") { monitor.hasLoaded }
        check(monitor.panes.map(\.paneID) == ["w1:p1", "w1:p2"] && monitor.loadError == nil, "subscription: panes listed")
        await eventually("subscription: opened again for the agent pane") { await fake.subscriptions.count == 2 }
        let subscriptions = await fake.subscriptions
        check(subscriptions[0].paneIDs == [] && subscriptions[0].lifecycleCount == 17, "subscription: the first one before anything is known, lifecycle only")
        check(subscriptions[1].paneIDs == ["w1:p1"] && subscriptions[1].lifecycleCount == 17, "subscription: then with the agent pane's status")
        await eventually("subscription: the old one closed once the new one is acknowledged") { await fake.subscriptions[0].closed }
        check(await fake.subscriptions[1].closed == false, "subscription: the new one stays open")
        await pause(150)
        let settled = await fake.snapshotTimes.count
        check(settled == 2, "subscription: a snapshot after each acknowledgement, no more (\(settled))")
        await pause(400)
        check(await fake.snapshotTimes.count == settled, "subscription: nothing read while nothing changes")

        await fake.setTitle("w1:p1", "renamed")
        let emitted = ContinuousClock.now
        await fake.emit(#"{"event":"pane_updated","data":{"type":"pane_updated","pane":{}}}"#)
        await eventually("subscription: a new terminal title shows after its event") { fixture.title(of: "w1:p1") == "renamed" }
        check(ContinuousClock.now - emitted < .milliseconds(400), "subscription: within a gather and a read")
        check(fixture.clients == 1 && fixture.listener.connections == 1 && monitor.snapshotCount >= 3, "subscription: one connection, told of once")
        check(fixture.listener.observed.allSatisfy { $0.herdrMachine == nil } && fixture.listener.observed.count == monitor.snapshotCount,
              "subscription: every snapshot passed on to the notifications")

        await fake.setTitle("w1:p1", "unannounced")
        let before = await fake.snapshotTimes.count
        await eventually("subscription: read again when nothing has changed for a while", seconds: 2) { await fake.snapshotTimes.count > before }
        let times = await fake.snapshotTimes
        check(times[times.count - 1] - times[times.count - 2] >= .milliseconds(750), "subscription: only after the idle refresh interval")
        await eventually("subscription: which brings a change herdr reported no event for") { fixture.title(of: "w1:p1") == "unannounced" }
        await fixture.finish()
    }

    static func burstOfChanges() async {
        let fixture = Fixture()
        let fake = fixture.fake
        fixture.showOnBoard()
        await eventually("burst: subscribed") { await fake.isSubscribedForTheAgent }
        await pause(150)
        let start = await fake.snapshotTimes.count
        for index in 0..<60 {
            await fake.setTitle("w1:p1", "title \(index)")
            await fake.emit(#"{"event":"pane_updated","data":{}}"#)
            await pause(5)
        }
        await pause(300)
        let times = await fake.snapshotTimes
        let reads = Array(times[start...])
        let gaps = zip(reads.dropFirst(), reads).map { $0 - $1 }
        check(!reads.isEmpty && reads.count <= 6, "burst: 60 changes in ~0.4 s cost a handful of snapshots (\(reads.count))")
        check(gaps.allSatisfy { $0 >= .milliseconds(95) }, "burst: snapshots at least the minimum interval apart")
        await eventually("burst: the last title shows") { fixture.title(of: "w1:p1") == "title 59" }
        await fixture.finish()
    }

    static func changeDuringRead() async {
        let fixture = Fixture()
        let fake = fixture.fake
        fixture.showOnBoard()
        await eventually("during a read: subscribed") { await fake.isSubscribedForTheAgent }
        await pause(150)
        await fake.setSnapshotDelay(.milliseconds(200))
        await fake.emit(#"{"event":"tab_renamed","data":{}}"#)
        await eventually("during a read: a read starts") { await fake.snapshotTimes.count == 3 }
        await pause(50)
        await fake.setTitle("w1:p1", "late")
        await fake.emit(#"{"event":"pane_updated","data":{}}"#)
        await eventually("during a read: read again afterwards") { await fake.snapshotTimes.count == 4 }
        await eventually("during a read: the change made during the read shows") { fixture.title(of: "w1:p1") == "late" }
        await pause(400)
        check(await fake.snapshotTimes.count == 4, "during a read: and then nothing more")
        await fixture.finish()
    }

    static func agentStartedResubscribes() async {
        let fixture = Fixture()
        let fake = fixture.fake
        fixture.showOnBoard()
        await eventually("new agent: subscribed") { await fake.isSubscribedForTheAgent }
        await pause(150)
        await fake.addAgent("w1:p2")
        await fake.emit(#"{"event":"pane_agent_detected","data":{"type":"pane_agent_detected","pane_id":"w1:p2"}}"#)
        await eventually("new agent: subscribed again with its status") { await fake.subscriptions.count == 3 }
        check(await fake.subscriptions[2].paneIDs == ["w1:p1", "w1:p2"], "new agent: both agent panes named")
        await eventually("new agent: the old subscription closed") { await fake.subscriptions[1].closed }
        await eventually("new agent: and a snapshot read after the new one, for the moment in between") { await fake.snapshotTimes.count == 4 }
        await fixture.finish()
    }

    static func paneGoneWhileSubscribing() async {
        let fake = FakeHerdr(panes: ["w1:p1", "w1:p3"], agents: ["w1:p1", "w1:p3"])
        await fake.closeWhenSubscribed("w1:p3")
        let fixture = Fixture(fake)
        fixture.showOnBoard()
        await eventually("pane gone: subscribed again without it") { await fake.subscriptions.count == 2 }
        let attempts = await fake.attempts
        check(attempts == [[], ["w1:p1", "w1:p3"], ["w1:p1"]], "pane gone: refused with pane_not_found, snapshot read, subscribed with the panes there are (\(attempts))")
        let latest = await fake.subscriptions[1].paneIDs
        check(latest == ["w1:p1"], "pane gone: still subscribed")
        check(await fake.waits == 0, "pane gone: not long-polling")
        await eventually("pane gone: the pane is gone from the list") { fixture.monitor.panes.map(\.paneID) == ["w1:p1"] }
        await fixture.finish()
    }

    static func subscriptionEndingFallsBackAfterThree() async {
        let fixture = Fixture()
        let fake = fixture.fake
        fixture.showOnBoard()
        await eventually("ending: subscribed") { await fake.isSubscribedForTheAgent }
        await pause(150)
        await fake.endLatest(with: #"{"id":"req_1","error":{"code":"events_lost","message":"event subscription fell behind retained history; resubscribe and resync with session.snapshot"}}"#)
        await eventually("ending: events_lost subscribes again") { await fake.subscriptions.count == 3 }
        await eventually("ending: and reads a snapshot") { await fake.snapshotTimes.count == 3 }
        await pause(150)
        await fake.endLatest()
        await eventually("ending: herdr closing it subscribes again") { await fake.subscriptions.count == 4 }
        await pause(150)
        check(await fake.waits == 0, "ending: twice in a minute is still kept up by subscription")
        await fake.endLatest()
        await eventually("ending: the third time within a minute long-polls instead") { await fake.waits > 0 }
        await pause(200)
        check(await fake.subscriptions.count == 4, "ending: and doesn't subscribe again on this connection")
        await fixture.finish()
    }

    // MARK: Without one

    static func unsupportedWithBoardLongPolls() async {
        let fake = FakeHerdr(mode: .unsupported)
        let fixture = Fixture(fake)
        fixture.showOnBoard()
        await eventually("unsupported: listed anyway") { fixture.monitor.hasLoaded }
        await eventually("unsupported, board: long-polls per agent pane and status") { await fake.waits == 3 }
        await fake.setTitle("w1:p2", "shell title")
        await eventually("unsupported, board: a long-poll round ending reads again") { fixture.title(of: "w1:p2") == "shell title" }
        let reads = await fake.snapshotTimes.count
        fixture.monitor.refreshNow()
        await eventually("unsupported, board: a refresh cuts the wait short") { await fake.snapshotTimes.count > reads }
        check(fixture.clients == 1, "unsupported, board: on the same connection")
        await fixture.finish()
    }

    static func unsupportedWatchedOnlyPolls() async {
        let fake = FakeHerdr(mode: .unsupported)
        let fixture = Fixture(fake)
        fixture.monitor.isWatched = true
        await eventually("unsupported, notifications only: polled") { await fake.snapshotTimes.count >= 4 }
        let times = await fake.snapshotTimes
        check(zip(times.dropFirst(), times).allSatisfy { $0 - $1 >= .milliseconds(140) }, "unsupported, notifications only: every poll interval")
        check(await fake.waits == 0, "unsupported, notifications only: no long-polls")
        fixture.showOnBoard()
        await eventually("unsupported: a board coming long-polls instead") { await fake.waits > 0 }
        await fixture.finish()
    }

    static func unacknowledgedFallsBack() async {
        let fake = FakeHerdr(mode: .neverAcknowledge)
        let fixture = Fixture(fake)
        let start = ContinuousClock.now
        fixture.showOnBoard()
        await eventually("unacknowledged: listed once the acknowledgement times out") { fixture.monitor.hasLoaded }
        check(ContinuousClock.now - start >= .milliseconds(280), "unacknowledged: not before the timeout")
        await eventually("unacknowledged: long-polls instead") { await fake.waits > 0 }
        await fixture.finish()
    }

    static func refusedFallsBack() async {
        let fake = FakeHerdr(mode: .refuse("invalid_request"))
        let fixture = Fixture(fake)
        fixture.showOnBoard()
        await eventually("refused: long-polls instead, at once") { await fake.waits > 0 }
        check(fixture.monitor.loadError == nil && fixture.clients == 1, "refused: not a connection failure")
        await fixture.finish()
    }

    // MARK: Connecting

    static func refreshDoesNotReconnect() async {
        let fake = FakeHerdr(herdrMachines: ["gpu"])
        let fixture = Fixture(fake)
        fixture.showOnBoard()
        await eventually("refresh: subscribed and the herdr machines read") {
            let machineReads = await fake.herdrMachineSnapshots.count
            return await fake.isSubscribedForTheAgent && machineReads >= 1
        }
        await pause(150)
        let reads = await fake.snapshotTimes.count
        let machineReads = await fake.herdrMachineSnapshots.count
        fixture.monitor.refreshNow()
        await eventually("refresh: the host read again at once") { await fake.snapshotTimes.count == reads + 1 }
        await eventually("refresh: the herdr machines too") { await fake.herdrMachineSnapshots.count > machineReads }
        let connects = await fake.connects, disconnects = await fake.disconnects
        check(connects == 1 && fixture.clients == 1 && disconnects == 0, "refresh: over the same connection")
        await fixture.finish()
    }

    static func permanentFailureWaitsForRetry() async {
        let fake = FakeHerdr()
        await fake.failConnecting(with: PermanentTestFailure())
        let fixture = Fixture(fake)
        fixture.showOnBoard()
        await eventually("permanent: shown") { fixture.monitor.loadError != nil }
        check(!fixture.monitor.isRetrying, "permanent: not trying again by itself")
        await pause(500)
        check(await fake.connects == 1, "permanent: no further attempt")
        await fake.failConnecting(with: nil)
        fixture.monitor.retry()
        await eventually("permanent: Retry connects again") { fixture.monitor.hasLoaded }
        let connects = await fake.connects
        check(fixture.monitor.loadError == nil && connects == 2, "permanent: and the failure is gone")
        await fixture.finish()
    }

    static func passingFailureRetriesByItself() async {
        let fake = FakeHerdr()
        await fake.failConnecting(with: PassingTestFailure())
        let fixture = Fixture(fake)
        fixture.showOnBoard()
        await eventually("passing: shown, trying again") { fixture.monitor.loadError != nil && fixture.monitor.isRetrying }
        await eventually("passing: tried again, waiting longer each time") { await fake.connects >= 3 }
        let attempts = await fake.connectTimes
        check(attempts[2] - attempts[1] > attempts[1] - attempts[0], "passing: backing off")
        await fake.failConnecting(with: nil)
        await eventually("passing: back by itself") { fixture.monitor.hasLoaded && fixture.monitor.loadError == nil }
        await fixture.finish()
    }

    static func herdrMachinesArePolled() async {
        let fake = FakeHerdr(herdrMachines: ["slow", "gpu", "down"])
        await fake.setMachineDelay("slow", .milliseconds(120))
        await fake.setMachineFailure("down")
        let fixture = Fixture(fake)
        fixture.monitor.isWatched = true
        await eventually("herdr machines: grouped") { fixture.monitor.herdrMachineGroups.count == 3 }
        let groups = fixture.monitor.herdrMachineGroups
        check(groups.map(\.id) == ["slow", "gpu", "down"], "herdr machines: in herdr's order")
        check(groups[0].hasLoaded && groups[0].agents.first?.terminalID == "term-slow"
              && groups[1].hasLoaded && groups[1].agents.first?.terminalID == "term-gpu", "herdr machines: each machine's own panes, however long each took")
        check(!groups[2].hasLoaded && groups[2].error != nil, "herdr machines: one that fails shows its error")
        await eventually("herdr machines: read again and again") { await fake.herdrMachineSnapshots.count >= 9 }
        let times = await fake.herdrMachineSnapshots.filter { $0.machine == "gpu" }.map(\.at)
        check(zip(times.dropFirst(), times).allSatisfy { $0 - $1 >= .milliseconds(240) }, "herdr machines: every interval")
        check(fixture.listener.observed.contains { $0.herdrMachine == "gpu" } && !fixture.listener.observed.contains { $0.herdrMachine == "down" },
              "herdr machines: those listed passed on to the notifications")
        await fixture.finish()
    }

    static func boardLeaseAndStopDelay() async {
        let fixture = Fixture()
        let fake = fixture.fake, monitor = fixture.monitor!
        fixture.showOnBoard()
        await eventually("lease: running for the board") { monitor.hasLoaded }
        fixture.leaveBoard()
        await pause(100)
        let disconnects = await fake.disconnects
        check(monitor.isActive && monitor.hasLoaded && disconnects == 0, "lease: still running just after the board leaves")
        fixture.showOnBoard()
        await pause(400)
        let connects = await fake.connects
        check(connects == 1 && monitor.hasLoaded, "lease: a board back within the delay keeps the connection")
        fixture.leaveBoard()
        await eventually("lease: stops once the delay has passed with nobody") { !monitor.isActive }
        check(!monitor.hasLoaded && monitor.panes.isEmpty, "lease: and forgets what it knew")
        await eventually("lease: its connection closed") {
            let subscriptions = await fake.subscriptions
            return await fake.disconnects >= 1 && subscriptions.allSatisfy(\.closed)
        }
        monitor.isWatched = true
        await eventually("lease: watched, it runs again") { monitor.hasLoaded }
        check(await fake.connects == 2, "lease: over a new connection")
        await fixture.finish()
    }

    static func connectedOncePerConnection() async {
        let fixture = Fixture()
        let fake = fixture.fake
        fixture.showOnBoard()
        await eventually("connections: subscribed") { await fake.isSubscribedForTheAgent }
        await pause(150)
        await fake.failSnapshots(1)
        await fake.emit(#"{"event":"pane_closed","data":{}}"#)
        await eventually("connections: a failed snapshot is shown") { fixture.monitor.loadError != nil }
        await eventually("connections: reconnected") {
            let connects = await fake.connects
            return connects == 2 && fixture.monitor.loadError == nil
        }
        check(fixture.listener.connections == 2 && fixture.clients == 2, "connections: told of each connection once")
        await fixture.finish()
    }

    static func snapshotTimeoutReconnects() async {
        let fixture = Fixture()
        let fake = fixture.fake
        fixture.showOnBoard()
        await eventually("timeout: subscribed") { await fake.isSubscribedForTheAgent }
        await fake.hangSnapshots(true)
        fixture.monitor.refreshNow()
        await eventually("timeout: a snapshot that doesn't come back is a failure") {
            fixture.monitor.loadError == MachineMonitor.SnapshotTimedOut().errorDescription
        }
        check(await fake.disconnects >= 1, "timeout: the connection is closed")
        await fake.hangSnapshots(false)
        await eventually("timeout: and made anew") {
            let connects = await fake.connects
            return connects >= 2 && fixture.monitor.loadError == nil
        }
        await fixture.finish()
    }

    static func boardComingToFailingMachineRetriesAtOnce() async {
        var slow = timing()
        slow.firstReconnectDelay = .seconds(5)
        let fake = FakeHerdr()
        await fake.failConnecting(with: PassingTestFailure())
        let fixture = Fixture(fake, timing: slow)
        fixture.monitor.isWatched = true
        await eventually("board comes: the watched machine is failing") { fixture.monitor.loadError != nil }
        check(await fake.connects == 1, "board comes: and waiting to reconnect")
        await fake.failConnecting(with: nil)
        fixture.showOnBoard()
        await eventually("board comes: tries again at once", seconds: 1) { fixture.monitor.hasLoaded }
        await fixture.finish()
    }
}

nonisolated struct PermanentTestFailure: Error {}

final class Listener: MachineMonitorListener {
    var connections = 0
    var observed: [(herdrMachine: String?, panes: Int)] = []

    func connected(_ client: HerdrClient) {
        connections += 1
    }

    func observe(panes: [AgentSummary], tabs: [TabSummary]?, workspaces: [WorkspaceSummary]?, on herdrMachine: HerdrMachine?) {
        observed.append((herdrMachine?.id, panes.count))
    }
}
