import Foundation

/// The number on the Dock icon: how many agents are waiting for the
/// person's input (herdr's `blocked`) on the machines watched — the panes
/// on each machine's own herdr and on its herdr machines together. The pane
/// the person is looking at counts too: it is still waiting. Only the
/// count: what the machines' monitors last saw is the caller's to gather.
public nonisolated enum NotificationBadge {
    /// What one machine's monitor last saw.
    public struct MachineAgents: Sendable {
        public init(machineID: UUID, panes: [AgentSummary], isFailing: Bool, herdrMachines: [HerdrMachineAgents]) {
            self.machineID = machineID
            self.panes = panes
            self.isFailing = isFailing
            self.herdrMachines = herdrMachines
        }

        public var machineID: UUID
        /// The panes of the machine's own herdr.
        public var panes: [AgentSummary]
        /// Whether its connection is failing: what it last listed may be
        /// long out of date, and none of it is counted, its herdr
        /// machines' included.
        public var isFailing: Bool
        public var herdrMachines: [HerdrMachineAgents]
    }

    /// One herdr machine's panes, and whether the last attempt to list
    /// them failed — when they aren't counted either.
    public struct HerdrMachineAgents: Sendable {
        public init(panes: [AgentSummary], isFailing: Bool) {
            self.panes = panes
            self.isFailing = isFailing
        }

        public var panes: [AgentSummary]
        public var isFailing: Bool
    }

    /// Agents waiting for input on `machines`, leaving out the machines
    /// turned off (`muted`).
    public static func count(_ machines: [MachineAgents], muted: Set<UUID>) -> Int {
        machines.reduce(0) { total, machine in
            guard !muted.contains(machine.machineID), !machine.isFailing else { return total }
            let nested = machine.herdrMachines.filter { !$0.isFailing }.reduce(0) { $0 + waiting($1.panes) }
            return total + waiting(machine.panes) + nested
        }
    }

    private static func waiting(_ panes: [AgentSummary]) -> Int {
        panes.count(where: { $0.hasAgent && $0.state == .blocked })
    }
}
