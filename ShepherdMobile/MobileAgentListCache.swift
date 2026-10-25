import Foundation
import ShepherdKit

/// iOS-only composition for the display-only Board cache. This is deliberately
/// main-actor isolated: monitor publication, cache hydration, invalidation and
/// write scheduling reconcile one per-connection state machine rather than
/// relying on storage actor arrival order.
@MainActor
final class MobileAgentListCache {
    private static let debounceNanoseconds: UInt64 = 250_000_000

    private struct IdentityState {
        var generation: UInt64?
        var snapshot: AgentListCache.Snapshot?
        /// A nested round can finish before the host's first successful
        /// snapshot. It is retained and folded into that first host record.
        var pendingNestedGroups: [AgentListCache.NestedGroupDTO]?
        /// Every load/publication/invalidation advances this revision. A
        /// suspended load or delayed writer may only act on its own revision.
        var revision: UInt64 = 0
        var writeTask: Task<Void, Never>?
        var evictionTask: Task<Bool, Never>?
    }

    private let machineStore: MachineStore
    private let cache: AgentListCache
    private let retired: RetiredCacheIdentities
    private var states: [Machine.ConnectionIdentity: IdentityState] = [:]
    /// A machine-wide removal can be followed by a newly added variant not
    /// present when it was removed. That variant must still wait for the old
    /// record eviction before it gets any generation or clears the tombstone.
    private var machineEvictions: [UUID: Task<Bool, Never>] = [:]

    init(machineStore: MachineStore, directory: URL) {
        self.machineStore = machineStore
        self.cache = AgentListCache(directory: directory)
        self.retired = RetiredCacheIdentities(directory: directory)
        machineStore.connectionWillInvalidate = { [weak self] identity in
            self?.invalidate(identity) ?? false
        }
        machineStore.machineWillRemove = { [weak self] machineID in
            self?.invalidate(machineID: machineID) ?? false
        }
        MachineMonitors.shared.observePublication = { [weak self] machine, scope in
            self?.recordPublication(for: machine, scope: scope)
        }
    }

    /// Loads exactly the selected Board's matching display snapshot. A durable
    /// retirement tombstone intentionally denies a disk read until a fresh live
    /// publication has successfully replaced it.
    func snapshot(for machine: Machine) async -> AgentListCache.Snapshot? {
        let identity = machine.connectionIdentity
        guard machineStore.isCurrentConnection(machine), !retired.contains(identity) else { return nil }
        var state = states[identity] ?? IdentityState()
        if let snapshot = state.snapshot { return snapshot }
        let revision = state.revision
        states[identity] = state

        let generation = await generation(for: identity, revision: revision)
        guard generation != nil,
              machineStore.isCurrentConnection(machine),
              !retired.contains(identity) else { return nil }
        let loaded = await cache.load(for: identity)
        guard machineStore.isCurrentConnection(machine),
              !retired.contains(identity) else { return nil }
        state = states[identity] ?? IdentityState()
        // A live publication that won this race is authoritative. Returning
        // it also avoids forcing a deliberate stale-frame flicker.
        guard state.revision == revision else { return state.snapshot }
        if let loaded { state.snapshot = loaded }
        states[identity] = state
        return loaded
    }

    /// Writes every pending final candidate before a Board disappears or the
    /// app backgrounds. Failed writes retain the in-memory latest value and,
    /// for retired identities, their durable tombstone.
    func flush(for machine: Machine? = nil) async {
        let identities = machine.map { [$0.connectionIdentity] } ?? Array(states.keys)
        for identity in identities {
            guard var state = states[identity] else { continue }
            state.writeTask?.cancel()
            state.writeTask = nil
            let revision = state.revision
            states[identity] = state
            await storeCurrent(identity: identity, revision: revision)
        }
    }

    private func invalidate(_ identity: Machine.ConnectionIdentity) -> Bool {
        // This synchronous atomic tombstone is deliberately before the
        // MachineStore commit. If it cannot be recorded, returning false keeps
        // the connection edit from claiming an invalidation it did not make.
        guard retired.retire(identity) else { return false }
        var state = states[identity] ?? IdentityState()
        state.revision &+= 1
        state.generation = nil
        state.snapshot = nil
        state.pendingNestedGroups = nil
        state.writeTask?.cancel()
        state.writeTask = nil
        state.evictionTask = Task { [cache] in await cache.evict(identity) }
        states[identity] = state
        return true
    }

    private func invalidate(machineID: UUID) -> Bool {
        guard retired.retire(machineID: machineID) else { return false }
        let matching = states.keys.filter { $0.machineID == machineID }
        for identity in matching {
            var state = states[identity] ?? IdentityState()
            state.revision &+= 1
            state.generation = nil
            state.snapshot = nil
            state.pendingNestedGroups = nil
            state.writeTask?.cancel()
            state.writeTask = nil
            states[identity] = state
        }
        // All later generations wait for this same actor operation, including
        // an A -> B -> A return that happens before an old eviction completes.
        let eviction = Task { [cache] in await cache.evict(machineID: machineID) }
        machineEvictions[machineID] = eviction
        for identity in matching {
            states[identity]?.evictionTask = eviction
        }
        return true
    }

    private func recordPublication(for machine: Machine, scope: MachineMonitor.SnapshotPublication) {
        let identity = machine.connectionIdentity
        guard machineStore.isCurrentConnection(machine) else { return }
        var state = states[identity] ?? IdentityState()
        let monitor = MachineMonitors.shared.monitor(for: machine, in: machineStore)

        switch scope {
        case .host:
            let host = Self.snapshot(panes: monitor.panes, tabs: monitor.tabs, workspaces: monitor.workspaces)
            let nested = state.snapshot?.nestedGroups ?? state.pendingNestedGroups ?? []
            state.snapshot = AgentListCache.Snapshot(identity: .init(identity), host: host, nestedGroups: nested)
            state.pendingNestedGroups = nil
        case .herdrMachines:
            let previous = Dictionary(uniqueKeysWithValues: (state.snapshot?.nestedGroups ?? state.pendingNestedGroups ?? [])
                .map { ($0.machine.id, $0) })
            let groups = monitor.herdrMachineGroups.compactMap { group -> AgentListCache.NestedGroupDTO? in
                if group.error == nil, group.hasLoaded {
                    return .init(machine: Self.machine(group.machine), snapshot: Self.snapshot(
                        panes: group.agents, tabs: group.tabs, workspaces: group.workspaces
                    ))
                }
                return previous[group.machine.id]
            }
            // Keep a completed nested result even without a host. It will be
            // merged into the first successful host snapshot rather than lost.
            guard let host = state.snapshot?.host ?? (monitor.hasLoaded
                ? Self.snapshot(panes: monitor.panes, tabs: monitor.tabs, workspaces: monitor.workspaces)
                : nil) else {
                state.pendingNestedGroups = groups
                state.revision &+= 1
                states[identity] = state
                return
            }
            state.snapshot = AgentListCache.Snapshot(identity: .init(identity), host: host, nestedGroups: groups)
            state.pendingNestedGroups = nil
        }

        state.revision &+= 1
        let revision = state.revision
        state.writeTask?.cancel()
        state.writeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.debounceNanoseconds) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.storeCurrent(identity: identity, revision: revision)
        }
        states[identity] = state
    }

    private func generation(for identity: Machine.ConnectionIdentity, revision: UInt64) async -> UInt64? {
        if let generation = states[identity]?.generation { return generation }
        if let eviction = machineEvictions[identity.machineID] {
            _ = await eviction.value
            guard states[identity]?.revision == revision else { return nil }
            machineEvictions.removeValue(forKey: identity.machineID)
        }
        if let eviction = states[identity]?.evictionTask {
            _ = await eviction.value
            guard states[identity]?.revision == revision else { return nil }
            states[identity]?.evictionTask = nil
        }
        let generation = await cache.generation(for: identity)
        guard generation != .max, states[identity]?.revision == revision else { return nil }
        states[identity]?.generation = generation
        return generation
    }

    private func storeCurrent(identity: Machine.ConnectionIdentity, revision: UInt64) async {
        guard var state = states[identity], state.revision == revision,
              let snapshot = state.snapshot else { return }
        let generation = await generation(for: identity, revision: revision)
        guard let generation,
              machineStore.isCurrentConnectionIdentity(identity),
              states[identity]?.revision == revision,
              states[identity]?.generation == generation else { return }
        // The revision check immediately precedes the actor message. Since
        // this main actor does not suspend between the check and call, an older
        // candidate cannot be enqueued after a newer publication.
        let stored = await cache.store(snapshot, for: identity, generation: generation)
        guard stored, states[identity]?.revision == revision else { return }
        // Retirements stay durable until the fresh live snapshot is durably
        // stored. A failed tombstone clear is fail-closed: cache reads remain
        // blocked rather than reusing any retired data after recreation.
        _ = retired.restore(identity)
        state = states[identity] ?? state
        if state.revision == revision { state.writeTask = nil; states[identity] = state }
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

/// A tiny, app-owned journal for identities retired before MachineStore commits.
/// It is separate from the cache envelope so an interrupted cache actor task
/// cannot make an edit/removal reusable after process recreation. Corrupt or
/// unreadable journal bytes are never erased and fail closed.
@MainActor
private final class RetiredCacheIdentities {
    private struct Journal: Codable {
        var schemaVersion = 1
        var identities: Set<AgentListCache.ConnectionFingerprint> = []
        var machineIDs: Set<UUID> = []
    }

    private enum State { case loaded(Journal), unavailable }
    private let directory: URL
    private let fileURL: URL
    private let fileManager: FileManager
    private var state: State

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("agent-list-cache-retired-v1.json", isDirectory: false)
        self.fileManager = fileManager
        if !fileManager.fileExists(atPath: fileURL.path) {
            state = .loaded(Journal())
        } else if let data = try? Data(contentsOf: fileURL), let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.schemaVersion == 1 {
            state = .loaded(journal)
        } else {
            state = .unavailable
        }
    }

    func contains(_ identity: Machine.ConnectionIdentity) -> Bool {
        guard case .loaded(let journal) = state else { return true }
        let fingerprint = AgentListCache.ConnectionFingerprint(identity)
        return journal.identities.contains(fingerprint) || journal.machineIDs.contains(identity.machineID)
    }

    func retire(_ identity: Machine.ConnectionIdentity) -> Bool {
        update { $0.identities.insert(AgentListCache.ConnectionFingerprint(identity)) }
    }

    func retire(machineID: UUID) -> Bool {
        update { $0.machineIDs.insert(machineID) }
    }

    /// A new, successfully stored live snapshot is the only evidence allowed
    /// to clear a retirement. It never clears unrelated retired variants.
    func restore(_ identity: Machine.ConnectionIdentity) -> Bool {
        update {
            $0.identities.remove(AgentListCache.ConnectionFingerprint(identity))
            $0.machineIDs.remove(identity.machineID)
        }
    }

    private func update(_ mutate: (inout Journal) -> Void) -> Bool {
        guard case .loaded(var journal) = state else { return false }
        mutate(&journal)
        guard persist(journal) else { return false }
        state = .loaded(journal)
        return true
    }

    private func persist(_ journal: Journal) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(journal)
            let temporary = directory.appendingPathComponent(".agent-list-cache-retired-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }
}
