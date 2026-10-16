import Foundation

/// What one machine's connection sees of its herdrs, passed on to the
/// notifications. Each machine's `MachineMonitor` keeps one of these: it
/// says when a connection has been made (`connected`), and hands over every
/// snapshot it brings (`observe`).
///
/// The first snapshot of each herdr on a connection is a baseline only (see
/// `AgentEventDeriver`): what happened while there was none isn't told
/// about after the fact. A change seen later is checked again over the same
/// connection before it is shown.
final class NotificationFeed: MachineMonitorListener {
    private let machine: Machine
    private weak var coordinator: NotificationCoordinator?
    private var client: HerdrClient?
    /// The herdrs seen on the current connection, by herdr machine ID — ""
    /// for the machine's own.
    private var seen: Set<String> = []

    init(machine: Machine, coordinator: NotificationCoordinator? = nil) {
        self.machine = machine
        self.coordinator = coordinator ?? .shared
    }

    /// A new connection, which the snapshots from now on come over.
    func connected(_ client: HerdrClient) {
        self.client = client
        seen = []
    }

    /// A snapshot of the machine's own herdr, or of one of its herdr
    /// machines.
    func observe(panes: [AgentSummary], tabs: [TabSummary]?, workspaces: [WorkspaceSummary]?, on herdrMachine: HerdrMachine?) {
        guard let client, let coordinator else { return }
        let startsRun = seen.insert(herdrMachine?.id ?? "").inserted
        let refetch: @Sendable () async throws -> [AgentObservation]
        if let herdrMachine {
            refetch = {
                let snapshot = try await client.snapshot(on: herdrMachine)
                return AgentObservation.all(panes: snapshot.panes, tabs: snapshot.tabs, workspaces: snapshot.workspaces)
            }
        } else {
            refetch = {
                let snapshot = try await client.snapshot()
                return AgentObservation.all(panes: snapshot.panes, tabs: snapshot.tabs, workspaces: snapshot.workspaces)
            }
        }
        coordinator.ingest(AgentObservation.all(panes: panes, tabs: tabs, workspaces: workspaces),
                           from: machine, on: herdrMachine, startsRun: startsRun, refetch: refetch)
    }
}
