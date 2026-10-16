import Foundation

/// Looks at the machines no board is looking at, for the notifications:
/// each over a connection of its own, kept open, with a snapshot of its
/// herdr every few seconds — and of the herdr machines it reaches, as its
/// board would list them. A board long-polls instead and so hears of a
/// change at once; this only polls, which keeps an idle machine down to one
/// request every `interval(for:)`.
///
/// It connects as the board would: with the machine's credential read from
/// the Keychain for every connection, a host key pinned on first use, and
/// the same backing off while a machine can't be reached. A failure no
/// further attempt can get past (`AgentBoardView.isPermanentFailure`) stops
/// it for that machine — knocking on with a rejected credential is what
/// sshd's penalties exist for — until a board gets through to it.
final class MachineWatcher {
    private let store: MachineStore
    private weak var coordinator: NotificationCoordinator?
    private var watches: [Machine.ConnectionIdentity: Task<Void, Never>] = [:]
    /// Machines given up on after a permanent failure.
    private var stopped: Set<Machine.ConnectionIdentity> = []

    private static let firstReconnectDelay: Duration = .seconds(5)
    private static let maximumReconnectDelay: Duration = .seconds(60)
    /// How often the herdr machines are looked at: each look is a herdr CLI
    /// run on the machine that opens an SSH connection of its own, so no
    /// more often than the board does it.
    private static let herdrMachineInterval: Duration = .seconds(5)

    init(store: MachineStore, coordinator: NotificationCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    /// Three seconds for this Mac's own herdr, five for one over SSH.
    static func interval(for machine: Machine) -> Duration {
        machine.isLocal ? .seconds(3) : .seconds(5)
    }

    /// Looks at exactly these machines from now on: starts on the ones it
    /// wasn't looking at, and stops — closing their connections — on the
    /// ones no longer among them.
    func watch(_ machines: [Machine]) {
        let wanted = Set(machines.map(\.connectionIdentity))
        for (identity, task) in watches where !wanted.contains(identity) {
            task.cancel()
            watches[identity] = nil
        }
        for machine in machines {
            let identity = machine.connectionIdentity
            guard watches[identity] == nil, !stopped.contains(identity) else { continue }
            watches[identity] = Task { [weak self] in
                await self?.run(machine)
            }
        }
    }

    /// Someone got through to the machine: whatever stopped this from
    /// trying no longer stands.
    func connectionWorked(_ identity: Machine.ConnectionIdentity) {
        guard stopped.remove(identity) != nil else { return }
        watches[identity] = nil
    }

    private func run(_ machine: Machine) async {
        let identity = machine.connectionIdentity
        let feed = coordinator.map { NotificationFeed(machine: machine, coordinator: $0) }
        var reconnectDelay = Self.firstReconnectDelay
        while !Task.isCancelled {
            let client: HerdrClient
            do {
                guard store.isCurrentConnection(machine) else { return }
                client = HerdrClient(transport: try store.makeHerdrTransport(for: try store.currentMachine(matching: machine)))
            } catch {
                guard (try? await Task.sleep(for: reconnectDelay)) != nil else { return }
                reconnectDelay = min(reconnectDelay * 2, Self.maximumReconnectDelay)
                continue
            }
            // As in `AgentBoardView.keepUpToDate`: closing the connection is
            // what ends an await that cancellation doesn't reach, and nothing
            // is passed on once the task has been cancelled.
            let failure: (any Error)? = await withTaskCancellationHandler {
                do {
                    try await client.connect()
                    try Task.checkCancellation()
                    if let fingerprint = await client.newlyPinnedHostKeyFingerprint() {
                        try Task.checkCancellation()
                        store.pinHostKeyFingerprint(fingerprint, for: machine)
                    }
                    feed?.connected(client)
                    var herdrMachinesDue = ContinuousClock.now
                    var herdrMachinesDelay = Self.herdrMachineInterval
                    while true {
                        let snapshot = try await client.snapshot()
                        try Task.checkCancellation()
                        feed?.observe(snapshot)
                        reconnectDelay = Self.firstReconnectDelay
                        if ContinuousClock.now >= herdrMachinesDue {
                            let listed = await observeHerdrMachines(client: client, feed: feed)
                            try Task.checkCancellation()
                            // A herdr too old to have machines says so every
                            // time; it is asked again less and less often.
                            herdrMachinesDelay = listed ? Self.herdrMachineInterval : min(herdrMachinesDelay * 2, Self.maximumReconnectDelay)
                            herdrMachinesDue = ContinuousClock.now + herdrMachinesDelay
                        }
                        try await Task.sleep(for: Self.interval(for: machine))
                    }
                } catch {
                    await client.disconnect()
                    return Task.isCancelled ? nil : error
                }
            } onCancel: {
                Task { await client.disconnect() }
            }
            guard let failure else { return }
            if AgentBoardView.isPermanentFailure(failure) {
                stopped.insert(identity)
                return
            }
            guard (try? await Task.sleep(for: reconnectDelay)) != nil else { return }
            reconnectDelay = min(reconnectDelay * 2, Self.maximumReconnectDelay)
        }
    }

    /// Takes a snapshot of every herdr machine the machine's herdr has, all
    /// at once, and passes on the ones that came. Returns whether the
    /// machines could be listed at all.
    private func observeHerdrMachines(client: HerdrClient, feed: NotificationFeed?) async -> Bool {
        guard let machines = try? await client.listHerdrMachines() else { return false }
        await withTaskGroup(of: (HerdrMachine, HerdrSnapshot?).self) { group in
            for herdrMachine in machines {
                group.addTask {
                    (herdrMachine, try? await client.snapshot(on: herdrMachine))
                }
            }
            for await (herdrMachine, snapshot) in group {
                guard let snapshot, !Task.isCancelled else { continue }
                feed?.observe(panes: snapshot.panes, tabs: snapshot.tabs, workspaces: snapshot.workspaces, on: herdrMachine)
            }
        }
        return true
    }
}
