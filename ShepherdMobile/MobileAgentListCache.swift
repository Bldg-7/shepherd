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

    struct TestingHooks {
        var load: (@MainActor (Machine.ConnectionIdentity) async -> AgentListCache.Snapshot?)?
        var beforeStore: (@MainActor (Machine.ConnectionIdentity, UInt64) async -> Void)?
        var evictIdentity: (@MainActor (Machine.ConnectionIdentity) async -> Bool)?
        var evictMachine: (@MainActor (UUID) async -> Bool)?
        var didStore: (@MainActor (Machine.ConnectionIdentity, UInt64, Bool) -> Void)?
    }

    private let machineStore: MachineStore
    private let cache: AgentListCache
    private let retired: RetiredCacheIdentities
    private let testingHooks: TestingHooks?
    private var states: [Machine.ConnectionIdentity: IdentityState] = [:]
    /// A machine-wide removal can be followed by a newly added variant not
    /// present when it was removed. That variant must still wait for the old
    /// record eviction before it gets any generation or clears the tombstone.
    private struct MachineEviction {
        let retirementIncarnation: UInt64
        let task: Task<Bool, Never>
    }

    private var machineEvictions: [UUID: MachineEviction] = [:]

    init(machineStore: MachineStore, directory: URL) {
        self.machineStore = machineStore
        self.cache = AgentListCache(directory: directory)
        self.retired = RetiredCacheIdentities(directory: directory)
        self.testingHooks = nil
        installCallbacks()
    }

    /// Internal harness-only timing seams retain the production coordinator,
    /// journal and storage actor while holding a single operation at a known
    /// suspension point.
    init(machineStore: MachineStore, directory: URL, testingHooks: TestingHooks) {
        self.machineStore = machineStore
        self.cache = AgentListCache(directory: directory)
        self.retired = RetiredCacheIdentities(directory: directory)
        self.testingHooks = testingHooks
        installCallbacks()
    }

    private func installCallbacks() {
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
        let loaded = if let load = testingHooks?.load {
            await load(identity)
        } else {
            await cache.load(for: identity)
        }
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
        let hook = testingHooks?.evictIdentity
        state.evictionTask = Task { [cache] in
            if let hook { return await hook(identity) }
            return await cache.evict(identity)
        }
        states[identity] = state
        return true
    }

    private func invalidate(machineID: UUID) -> Bool {
        guard let retirementIncarnation = retired.retire(machineID: machineID) else { return false }
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
        // A retirement incarnation is carried with the actor operation. A
        // delayed acknowledgement from an earlier removal must never clear a
        // newer machine-wide barrier.
        let eviction = startMachineEviction(machineID: machineID, retirementIncarnation: retirementIncarnation)
        for identity in matching {
            states[identity]?.evictionTask = eviction.task
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
        // The durable machine marker is deliberately independent from exact
        // identities. Re-enabling one connection must first remove every old
        // variant for the machine, including variants that survived a process
        // loss before the original actor eviction could run.
        if let retirementIncarnation = retired.machineRetirement(for: identity.machineID) {
            let eviction = startMachineEviction(machineID: identity.machineID, retirementIncarnation: retirementIncarnation)
            guard await eviction.task.value,
                  states[identity]?.revision == revision,
                  retired.restore(machineID: identity.machineID, retirementIncarnation: retirementIncarnation) else { return nil }
            if machineEvictions[identity.machineID]?.retirementIncarnation == retirementIncarnation {
                machineEvictions.removeValue(forKey: identity.machineID)
            }
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

    private func startMachineEviction(machineID: UUID, retirementIncarnation: UInt64) -> MachineEviction {
        if let existing = machineEvictions[machineID], existing.retirementIncarnation == retirementIncarnation {
            return existing
        }
        let hook = testingHooks?.evictMachine
        let task = Task { [cache] in
            if let hook { return await hook(machineID) }
            return await cache.evict(machineID: machineID)
        }
        let eviction = MachineEviction(retirementIncarnation: retirementIncarnation, task: task)
        machineEvictions[machineID] = eviction
        return eviction
    }

    private func storeCurrent(identity: Machine.ConnectionIdentity, revision: UInt64) async {
        guard var state = states[identity], state.revision == revision,
              let snapshot = state.snapshot else { return }
        let generation = await generation(for: identity, revision: revision)
        guard let generation,
              machineStore.isCurrentConnectionIdentity(identity),
              states[identity]?.revision == revision,
              states[identity]?.generation == generation else { return }
        // The normal path has no suspension between this guard and the actor
        // message. The harness hook deliberately creates one, and the second
        // guard proves a newer publication still prevents an old candidate
        // from being enqueued.
        if let beforeStore = testingHooks?.beforeStore {
            await beforeStore(identity, revision)
            guard states[identity]?.revision == revision,
                  states[identity]?.generation == generation else { return }
        }
        let stored = await cache.store(snapshot, for: identity, generation: generation)
        testingHooks?.didStore?(identity, revision, stored)
        guard stored, states[identity]?.revision == revision else { return }
        // Exact-identity retirement is cleared only by its own fresh durable
        // replacement. It intentionally cannot clear the separate machine
        // barrier, which is released only after a successful all-variant
        // eviction in generation(for:revision:).
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
    private static let schemaVersion = 2
    private static let maximumFileBytes = 64 * 1024
    private static let maximumRetirements = 64
    fileprivate static let maximumStringLength = 1_024

    private struct IdentityRetirement: Codable, Hashable {
        let identity: AgentListCache.ConnectionFingerprint
        let incarnation: UInt64
    }

    private struct MachineRetirement: Codable, Hashable {
        let machineID: UUID
        let incarnation: UInt64
        /// Exact markers no newer than this were present before this
        /// all-variant eviction began, so its successful acknowledgement may
        /// safely reclaim them with the machine marker.
        let identityIncarnationThrough: UInt64
    }

    private struct Journal: Codable {
        var schemaVersion = RetiredCacheIdentities.schemaVersion
        var nextIncarnation: UInt64 = 0
        var identities: Set<IdentityRetirement> = []
        var machines: Set<MachineRetirement> = []
    }

    /// The initial journal format had no incarnation. It is read only within
    /// the same bounded decoder path, then upgraded on the next successful
    /// journal write without ever dropping its barriers.
    private struct LegacyJournal: Codable {
        let schemaVersion: Int
        let identities: Set<AgentListCache.ConnectionFingerprint>
        let machineIDs: Set<UUID>
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
        } else if let data = try? Self.readBoundedFile(at: fileURL), let journal = Self.decode(data) {
            state = .loaded(journal)
        } else {
            state = .unavailable
        }
    }

    func contains(_ identity: Machine.ConnectionIdentity) -> Bool {
        guard case .loaded(let journal) = state else { return true }
        let fingerprint = AgentListCache.ConnectionFingerprint(identity)
        return journal.identities.contains { $0.identity == fingerprint } ||
            journal.machines.contains { $0.machineID == identity.machineID }
    }

    func machineRetirement(for machineID: UUID) -> UInt64? {
        guard case .loaded(let journal) = state else { return nil }
        return journal.machines.first { $0.machineID == machineID }?.incarnation
    }

    func retire(_ identity: Machine.ConnectionIdentity) -> Bool {
        guard case .loaded(var journal) = state,
              let incarnation = Self.nextIncarnation(for: &journal) else { return false }
        let fingerprint = AgentListCache.ConnectionFingerprint(identity)
        journal.identities = Set(journal.identities.filter { $0.identity != fingerprint })
        journal.identities.insert(.init(identity: fingerprint, incarnation: incarnation))
        guard Self.isWithinBounds(journal), persist(journal) else { return false }
        state = .loaded(journal)
        return true
    }

    /// Returns the durable incarnation that an eviction acknowledgement must
    /// match. Repeated removals always get a newer incarnation.
    func retire(machineID: UUID) -> UInt64? {
        guard case .loaded(var journal) = state,
              let incarnation = Self.nextIncarnation(for: &journal) else { return nil }
        journal.machines = Set(journal.machines.filter { $0.machineID != machineID })
        journal.machines.insert(.init(machineID: machineID, incarnation: incarnation,
                                      identityIncarnationThrough: incarnation - 1))
        guard persist(journal) else { return nil }
        state = .loaded(journal)
        return incarnation
    }

    /// A new, successfully stored live snapshot is the only evidence allowed
    /// to clear an exact retirement. It never clears a machine barrier.
    func restore(_ identity: Machine.ConnectionIdentity) -> Bool {
        update { journal in
            let fingerprint = AgentListCache.ConnectionFingerprint(identity)
            journal.identities = Set(journal.identities.filter { $0.identity != fingerprint })
        }
    }

    /// Clears only the exact machine retirement acknowledged by a successful
    /// all-variant cache eviction. A delayed older acknowledgement fails
    /// closed when a later retirement has replaced the marker.
    func restore(machineID: UUID, retirementIncarnation: UInt64) -> Bool {
        guard case .loaded(var journal) = state,
              let retirement = journal.machines.first(where: {
                  $0.machineID == machineID && $0.incarnation == retirementIncarnation
              }) else { return false }
        journal.machines.remove(retirement)
        journal.identities = Set(journal.identities.filter {
            !($0.identity.machineID == machineID && $0.incarnation <= retirement.identityIncarnationThrough)
        })
        guard persist(journal) else { return false }
        state = .loaded(journal)
        return true
    }

    private func update(_ mutate: (inout Journal) -> Void) -> Bool {
        guard case .loaded(var journal) = state else { return false }
        mutate(&journal)
        guard Self.isWithinBounds(journal), persist(journal) else { return false }
        state = .loaded(journal)
        return true
    }

    private func persist(_ journal: Journal) -> Bool {
        guard Self.isWithinBounds(journal) else { return false }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(journal)
            guard data.count <= Self.maximumFileBytes else { return false }
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

    private static func nextIncarnation(for journal: inout Journal) -> UInt64? {
        guard journal.nextIncarnation < .max else { return nil }
        journal.nextIncarnation += 1
        return journal.nextIncarnation
    }

    private static func decode(_ data: Data) -> Journal? {
        let decoder = JSONDecoder()
        if let journal = try? decoder.decode(Journal.self, from: data), isWithinBounds(journal) {
            return journal
        }
        guard let legacy = try? decoder.decode(LegacyJournal.self, from: data), legacy.schemaVersion == 1,
              legacy.identities.count <= maximumRetirements, legacy.machineIDs.count <= maximumRetirements,
              legacy.identities.allSatisfy(isWithinBounds) else { return nil }
        var next: UInt64 = 0
        var identities: Set<IdentityRetirement> = []
        for identity in legacy.identities {
            next += 1
            identities.insert(.init(identity: identity, incarnation: next))
        }
        var machines: Set<MachineRetirement> = []
        for machineID in legacy.machineIDs {
            next += 1
            machines.insert(.init(machineID: machineID, incarnation: next, identityIncarnationThrough: next - 1))
        }
        let journal = Journal(nextIncarnation: next, identities: identities, machines: machines)
        return isWithinBounds(journal) ? journal : nil
    }

    /// Reads at most one byte beyond the cap before JSON decoding, preserving
    /// unreadable bytes and avoiding an unbounded materialization at launch.
    private static func readBoundedFile(at fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw JournalReadError.invalid }
        return data
    }

    private static func isWithinBounds(_ journal: Journal) -> Bool {
        journal.schemaVersion == schemaVersion && journal.identities.count <= maximumRetirements &&
            journal.machines.count <= maximumRetirements &&
            Set(journal.identities.map(\.identity)).count == journal.identities.count &&
            Set(journal.machines.map(\.machineID)).count == journal.machines.count &&
            journal.identities.allSatisfy {
                $0.incarnation > 0 && $0.incarnation <= journal.nextIncarnation && isWithinBounds($0.identity)
            } && journal.machines.allSatisfy {
                $0.incarnation > 0 && $0.incarnation <= journal.nextIncarnation &&
                    $0.identityIncarnationThrough < $0.incarnation
            }
    }

    private static func isWithinBounds(_ identity: AgentListCache.ConnectionFingerprint) -> Bool {
        identity.port > 0 && identity.port <= 65_535 &&
            identity.hostname.isNonemptyJournalString && identity.username.isNonemptyJournalString &&
            identity.sessionName.isJournalString && identity.credentialReferenceDigest.isNonemptyJournalString
    }

    private enum JournalReadError: Error { case invalid }
}

private extension String {
    var isJournalString: Bool { count <= RetiredCacheIdentities.maximumStringLength }
    var isNonemptyJournalString: Bool { !isEmpty && isJournalString }
}
