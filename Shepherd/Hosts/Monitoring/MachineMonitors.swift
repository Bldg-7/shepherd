import Foundation

/// The app's `MachineMonitor`s: one per machine — per connection identity,
/// so that a machine whose connection settings change gets a new one — for
/// as long as anyone wants it. That is the board while it shows the machine
/// (`holdForBoard`), and the notifications while they watch it (`watch`);
/// the two share the one connection, and a monitor runs while either wants
/// it, stopping a moment after neither does.
///
/// Not observable: the board looks its monitor up while drawing, and
/// observes the monitor itself.
@MainActor
final class MachineMonitors {
    static let shared = MachineMonitors()

    private var monitors: [Machine.ConnectionIdentity: MachineMonitor] = [:]

    private init() {}

    /// The monitor for `machine`: the same one every time, for as long as
    /// it is wanted, or as long as the machine's connection is one of
    /// `store`'s.
    func monitor(for machine: Machine, in store: MachineStore) -> MachineMonitor {
        let identity = machine.connectionIdentity
        if let monitor = monitors[identity] {
            return monitor
        }
        prune(store)
        let monitor = MachineMonitor(
            makeClient: {
                // The machine as the store has it now, not as it was when
                // the monitor was made: a host key pinned by an earlier
                // connection is recorded in the store's copy only, and a
                // transport built from the old one — nothing pinned — would
                // trust whichever key it is shown all over again. A removed
                // or edited connection ends the monitor's run.
                guard store.isCurrentConnection(machine) else { return nil }
                let current = try store.currentMachine(matching: machine)
                return HerdrClient(transport: try store.makeHerdrTransport(for: current))
            },
            pinHostKey: { fingerprint in
                store.pinHostKeyFingerprint(fingerprint, for: machine)
            },
            // When only the notifications watch a machine and its herdr
            // can't subscribe: three seconds for this Mac's own herdr, five
            // for one over SSH.
            pollInterval: machine.isLocal ? .seconds(3) : .seconds(5),
            listener: NotificationFeed(machine: machine)
        )
        monitors[identity] = monitor
        return monitor
    }

    /// Keeps `machine`'s monitor running for a board, for as long as the
    /// calling task — the board's — runs. Returns once that has been
    /// cancelled.
    func holdForBoard(_ machine: Machine, in store: MachineStore) async {
        await monitor(for: machine, in: store).holdForBoard()
    }

    /// Has the notifications watch exactly these machines from now on.
    func watch(_ machines: [Machine], in store: MachineStore) {
        let wanted = Set(machines.map(\.connectionIdentity))
        for (identity, monitor) in monitors where !wanted.contains(identity) {
            monitor.isWatched = false
        }
        for machine in machines {
            monitor(for: machine, in: store).isWatched = true
        }
        prune(store)
    }

    /// Lets go of the monitors of connections that are gone, once nothing
    /// wants them and they have stopped.
    private func prune(_ store: MachineStore) {
        let current = Set(store.allMachines.map(\.connectionIdentity))
        monitors = monitors.filter { identity, monitor in
            current.contains(identity) || monitor.isActive
        }
    }
}
