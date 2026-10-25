import Foundation
import ShepherdKit

/// iOS-only composition for the display-only Board cache. This owns the
/// application-support cache instance, its writer leases, and the monitor
/// publication bridge; ShepherdKit itself never creates disk storage.
final class MobileAgentListCache {
    private let machineStore: MachineStore
    private let cache: AgentListCache
    private var generations: [Machine.ConnectionIdentity: UInt64] = [:]
    private var snapshots: [Machine.ConnectionIdentity: AgentListCache.Snapshot] = [:]
    /// Invalidating this synchronous guard before MachineStore commits keeps a
    /// publication already queued on the main actor from writing an old scope.
    private var invalidated = Set<Machine.ConnectionIdentity>()

    init(machineStore: MachineStore, directory: URL) {
        self.machineStore = machineStore
        self.cache = AgentListCache(directory: directory)
        machineStore.connectionWillInvalidate = { [weak self] identity in
            self?.invalidate(identity)
        }
        machineStore.machineWillRemove = { [weak self] machineID in
            self?.invalidate(machineID: machineID)
        }
        MachineMonitors.shared.observePublication = { [weak self] machine, scope in
            self?.recordPublication(for: machine, scope: scope)
        }
    }

    /// Loads exactly the Board's current connection before its network result
    /// arrives. Starting a Board refresh never enumerates saved Machines.
    func snapshot(for machine: Machine) async -> AgentListCache.Snapshot? {
        let identity = machine.connectionIdentity
        guard machineStore.isCurrentConnection(machine), !invalidated.contains(identity) else { return nil }
        let generation = await cache.generation(for: identity)
        guard generation != .max,
              machineStore.isCurrentConnection(machine), !invalidated.contains(identity) else { return nil }
        generations[identity] = generation
        let snapshot = await cache.load(for: identity)
        guard machineStore.isCurrentConnection(machine), !invalidated.contains(identity) else { return nil }
        if let snapshot { snapshots[identity] = snapshot }
        return snapshot
    }

    private func invalidate(_ identity: Machine.ConnectionIdentity) {
        invalidated.insert(identity)
        generations.removeValue(forKey: identity)
        snapshots.removeValue(forKey: identity)
        Task { await cache.evict(identity) }
    }

    private func invalidate(machineID: UUID) {
        let identities = Set(generations.keys).union(snapshots.keys).filter { $0.machineID == machineID }
        invalidated.formUnion(identities)
        generations = generations.filter { $0.key.machineID != machineID }
        snapshots = snapshots.filter { $0.key.machineID != machineID }
        Task { await cache.evict(machineID: machineID) }
    }

    private func recordPublication(for machine: Machine, scope: MachineMonitor.SnapshotPublication) {
        let identity = machine.connectionIdentity
        guard machineStore.isCurrentConnection(machine), !invalidated.contains(identity) else { return }
        let monitor = MachineMonitors.shared.monitor(for: machine, in: machineStore)
        let current = snapshots[identity]
        let next: AgentListCache.Snapshot?
        switch scope {
        case .host:
            let host = Self.snapshot(panes: monitor.panes, tabs: monitor.tabs, workspaces: monitor.workspaces)
            next = (current ?? AgentListCache.Snapshot(
                identity: .init(identity), host: host, nestedGroups: []
            )).replacing(host: host)
        case .herdrMachines:
            // A completed round is authoritative about enabled groups. A
            // failed group retains only its prior display DTO, never an empty
            // stand-in; an authoritative empty round becomes [].
            guard let host = current?.host ?? (monitor.hasLoaded
                ? Self.snapshot(panes: monitor.panes, tabs: monitor.tabs, workspaces: monitor.workspaces)
                : nil) else { return }
            let previous = Dictionary(uniqueKeysWithValues: (current?.nestedGroups ?? []).map { ($0.machine.id, $0) })
            let groups = monitor.herdrMachineGroups.compactMap { group -> AgentListCache.NestedGroupDTO? in
                if group.error == nil, group.hasLoaded {
                    return .init(machine: Self.machine(group.machine), snapshot: Self.snapshot(
                        panes: group.agents, tabs: group.tabs, workspaces: group.workspaces
                    ))
                }
                return previous[group.machine.id]
            }
            next = (current ?? AgentListCache.Snapshot(
                identity: .init(identity), host: host, nestedGroups: []
            )).replacing(nestedGroups: groups)
        }
        guard let next else { return }
        snapshots[identity] = next
        Task { [weak self] in
            guard let self else { return }
            let generation: UInt64
            if let existing = self.generations[identity] {
                generation = existing
            } else {
                generation = await self.cache.generation(for: identity)
                guard generation != .max else { return }
                self.generations[identity] = generation
            }
            guard self.machineStore.isCurrentConnection(machine),
                  !self.invalidated.contains(identity),
                  self.generations[identity] == generation else { return }
            _ = await self.cache.store(next, for: identity, generation: generation)
        }
    }

    private static func machine(_ machine: HerdrMachine) -> AgentListCache.HerdrMachineDTO {
        .init(id: machine.id, label: machine.label, target: machine.target, session: machine.session, enabled: machine.enabled)
    }

    private static func snapshot(panes: [AgentSummary], tabs: [TabSummary]?, workspaces: [WorkspaceSummary]?) -> AgentListCache.SnapshotDTO {
        .init(
            panes: panes.map { pane in
                .init(paneID: pane.paneID, previousPaneID: pane.previousPaneID, tabID: pane.tabID,
                      workspaceID: pane.workspaceID, terminalID: pane.terminalID,
                      herdrMachine: pane.herdrMachine.map(machine), source: pane.source,
                      interactiveReady: pane.interactiveReady, launchPending: pane.launchPending,
                      screenDetectionSkipped: pane.screenDetectionSkipped,
                      stateChangeSequence: pane.stateChangeSequence, agentName: pane.agentName,
                      terminalTitle: pane.terminalTitle, label: pane.label,
                      workingDirectory: pane.workingDirectory, state: pane.state.rawValue,
                      revision: pane.revision)
            },
            tabs: tabs?.map { tab in
                .init(tabID: tab.tabID, workspaceID: tab.workspaceID, label: tab.label,
                      focusedPaneID: tab.focusedPaneID, paneIDs: tab.panes.map(\.paneID),
                      placements: tab.placements.map {
                          .init(paneID: $0.paneID, x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                      })
            },
            workspaces: workspaces?.map { .init(workspaceID: $0.workspaceID, label: $0.label) }
        )
    }
}
