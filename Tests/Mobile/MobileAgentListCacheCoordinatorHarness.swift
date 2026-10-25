import Foundation
import ShepherdKit

private final class MemorySecrets: MachineSecretStore {
    private(set) var writes: [(String, Data)] = []
    private var values: [String: Data] = [:]
    func saveSecret(_ data: Data, tag: String) throws { writes.append((tag, data)); values[tag] = data }
    func loadSecret(tag: String) throws -> Data? { values[tag] }
    func deleteSecret(tag: String) throws { values.removeValue(forKey: tag) }
}

private actor Gate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrived = true
        let waiters = arrivalWaiters; arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilArrived() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
    func release() { let waiters = releaseWaiters; releaseWaiters.removeAll(); waiters.forEach { $0.resume() } }
}

private actor SequencedEvictionGate {
    private let first = Gate()
    private let second = Gate()
    private var calls = 0

    func evict() async -> Bool {
        calls += 1
        if calls == 1 { await first.wait() }
        else if calls == 2 { await second.wait() }
        return true
    }

    func waitUntilFirstArrived() async { await first.waitUntilArrived() }
    func waitUntilSecondArrived() async { await second.waitUntilArrived() }
    func releaseFirst() async { await first.release() }
    func releaseSecond() async { await second.release() }
}

@main @MainActor struct MobileAgentListCacheCoordinatorHarness {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func pause(_ milliseconds: UInt64 = 20) async { try? await Task.sleep(nanoseconds: milliseconds * 1_000_000) }

    static func machine(_ hostname: String = "a.fixture.invalid", id: UUID = UUID(), paired: Bool = false) -> Machine {
        Machine(id: id, displayName: "Harness", hostname: hostname, port: 2222, username: "fixture", authMethod: .key,
                sessionName: "board", isLocal: false, addressKind: paired ? .tailscaleMagicDNS : nil)
    }

    private static func makeStore(_ machine: Machine, name: String) throws -> (MachineStore, MemorySecrets) {
        let defaults = UserDefaults(suiteName: "SHPHRD-131.behavior.\(name).\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first(where: { $0.contains("SHPHRD") }) ?? "")
        let secrets = MemorySecrets()
        let store = MachineStore(defaults: defaults, localMachine: nil, keychain: secrets)
        try store.addMachine(machine, privateKey: Data("owned".utf8))
        return (store, secrets)
    }

    static func host(_ label: String) -> AgentListCache.SnapshotDTO {
        .init(panes: [.init(paneID: "pane", previousPaneID: nil, tabID: nil, workspaceID: nil, terminalID: "terminal",
                            source: "harness", interactiveReady: true, launchPending: false, screenDetectionSkipped: false,
                            stateChangeSequence: 1, agentName: "fixture", terminalTitle: label, label: label,
                            workingDirectory: "/owned", state: "working", revision: 1)], tabs: [], workspaces: [])
    }

    static func snapshot(_ machine: Machine, label: String, nested: [AgentListCache.NestedGroupDTO] = []) -> AgentListCache.Snapshot {
        .init(identity: .init(machine.connectionIdentity), host: host(label), nestedGroups: nested)
    }

    static func persistedLabel(_ directory: URL, machine: Machine) async -> String? {
        await AgentListCache(directory: directory).load(for: machine.connectionIdentity)?.host.panes.first?.label
    }

    static func publishHost(_ label: String, machine: Machine, store: MachineStore) {
        let monitor = MachineMonitors.shared.monitor(for: machine, in: store)
        monitor.panes = [AgentSummary(label: label)]
        monitor.tabs = []; monitor.workspaces = []; monitor.hasLoaded = true
        MachineMonitors.shared.publish(.host, for: machine, in: store)
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("expected owned harness directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await cachePrecedesLease(root)
        try await nestedBeforeHostSurvivesRecreation(root)
        try await delayedLoadCannotReplacePublication(root)
        try await delayedOldStoreCannotOverwriteNewerState(root)
        try await ordinaryAndPairedABAResumeCaching(root)
        try await processLossDoesNotResurrectRetiredDisk(root)
        try await machineRetirementPurgesHistoricalVariants(root)
        try await failedMachineEvictionKeepsBarrier(root)
        try await lateMachineEvictionAcknowledgementKeepsNewestBarrier(root)
        try await retirementFailureRejectsCredentialReplacement(root)
        try await corruptAndCapacityBoundedJournalFailsClosed(root)
        try await burstCoalescesFinalSnapshot(root)
        try await emptyAndFailedRoundRetention(root)
        print("PASS \(checks) MobileAgentListCache coordinator behavioral checks; actual coordinator, AgentListCache actor, durable journal, and MachineStore with owned fakes")
    }

    static func cachePrecedesLease(_ root: URL) async throws {
        let dir = root.appendingPathComponent("cache-first", isDirectory: true), machine = machine()
        let (store, _) = try makeStore(machine, name: "cache-first")
        let disk = AgentListCache(directory: dir), generation = await disk.generation(for: machine.connectionIdentity)
        check(await disk.store(snapshot(machine, label: "cached"), for: machine.connectionIdentity, generation: generation), "fixture writes cache before Board access")
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir)
        var events: [String] = []
        var published: AgentListCache.Snapshot?
        await MobileBoardLoadCoordinator.run(machine: machine, cache: coordinator, publishCachedSnapshot: {
            published = $0; events.append("cache")
        }, startLease: {
            events.append("lease")
        }, refresh: { events.append("refresh") })
        check(published?.host.panes.first?.label == "cached", "Board receives selected cached snapshot")
        check(events.first == "cache", "cached snapshot is assigned before lease or refresh starts")
        check(events.contains("lease") && events.contains("refresh"), "negative control: live work was actually requested after cache")
    }

    static func nestedBeforeHostSurvivesRecreation(_ root: URL) async throws {
        let dir = root.appendingPathComponent("nested", isDirectory: true), machine = machine()
        let (store, _) = try makeStore(machine, name: "nested")
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir)
        let monitor = MachineMonitors.shared.monitor(for: machine, in: store)
        let nested = HerdrMachine(id: "nested", label: "Nested", target: "fixture@nested.invalid", session: "nested", enabled: true)
        monitor.herdrMachineGroups = [.init(machine: nested, agents: [AgentSummary(label: "nested-first", herdrMachine: nested)], tabs: [], workspaces: [], hasLoaded: true)]
        MachineMonitors.shared.publish(.herdrMachines, for: machine, in: store)
        check(await persistedLabel(dir, machine: machine) == nil, "negative control: nested-before-host is not prematurely persisted without host")
        publishHost("host-after-nested", machine: machine, store: store)
        await coordinator.flush(for: machine)
        let recreated = MobileAgentListCache(machineStore: store, directory: dir)
        let loaded = await recreated.snapshot(for: machine)
        check(loaded?.host.panes.first?.label == "host-after-nested", "first host survives nested-first ordering")
        check(loaded?.nestedGroups.first?.snapshot.panes.first?.label == "nested-first", "nested result is merged into first persisted host snapshot")
    }

    static func delayedLoadCannotReplacePublication(_ root: URL) async throws {
        let dir = root.appendingPathComponent("delayed-load", isDirectory: true), machine = machine()
        let (store, _) = try makeStore(machine, name: "delayed-load")
        let disk = AgentListCache(directory: dir), generation = await disk.generation(for: machine.connectionIdentity)
        check(await disk.store(snapshot(machine, label: "old-disk"), for: machine.connectionIdentity, generation: generation), "fixture writes old disk value")
        let gate = Gate()
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir, testingHooks: .init(load: { _ in
            await gate.wait(); return await AgentListCache(directory: dir).load(for: machine.connectionIdentity)
        }))
        let loading = Task { await coordinator.snapshot(for: machine) }
        await gate.waitUntilArrived()
        publishHost("new-live", machine: machine, store: store)
        await gate.release()
        let result = await loading.value
        check(result?.host.panes.first?.label == "new-live", "delayed disk completion returns newer publication rather than old disk")
        await coordinator.flush(for: machine)
        check(await persistedLabel(dir, machine: machine) == "new-live", "new live state remains durable after delayed load")
    }

    static func delayedOldStoreCannotOverwriteNewerState(_ root: URL) async throws {
        let dir = root.appendingPathComponent("delayed-store", isDirectory: true), machine = machine()
        let (store, _) = try makeStore(machine, name: "delayed-store")
        let gate = Gate(); var storedRevisions: [UInt64] = []
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir, testingHooks: .init(beforeStore: { _, revision in
            if revision == 1 { await gate.wait() }
        }, didStore: { _, revision, stored in if stored { storedRevisions.append(revision) } }))
        publishHost("old-publication", machine: machine, store: store)
        await pause(300)
        await gate.waitUntilArrived()
        publishHost("new-publication", machine: machine, store: store)
        await coordinator.flush(for: machine)
        await gate.release(); await pause(30)
        check(await persistedLabel(dir, machine: machine) == "new-publication", "delayed old writer cannot overwrite newer state")
        check(storedRevisions == [2], "negative control: held old candidate never reaches durable actor after revision changes")
    }

    static func ordinaryAndPairedABAResumeCaching(_ root: URL) async throws {
        let ordinaryDir = root.appendingPathComponent("ordinary-aba", isDirectory: true), id = UUID(), original = machine(id: id)
        let (store, _) = try makeStore(original, name: "ordinary-aba")
        let coordinator = MobileAgentListCache(machineStore: store, directory: ordinaryDir)
        var changed = original; changed.hostname = "b.fixture.invalid"
        try store.updateMachine(changed, replacing: original)
        let currentB = store.machines[0]
        try store.updateMachine(original, replacing: currentB)
        publishHost("fresh-a", machine: original, store: store); await coordinator.flush(for: original)
        let recreated = MobileAgentListCache(machineStore: store, directory: ordinaryDir)
        check(await recreated.snapshot(for: original)?.host.panes.first?.label == "fresh-a", "ordinary A-B-A receives a fresh persistable A generation")

        let pairedDir = root.appendingPathComponent("paired-aba", isDirectory: true), paired = machine(id: UUID(), paired: true)
        let (pairedStore, _) = try makeStore(paired, name: "paired-aba")
        pairedStore.pinHostKeyFingerprint("owned-pin", for: paired)
        let pairedCoordinator = MobileAgentListCache(machineStore: pairedStore, directory: pairedDir)
        try pairedStore.updatePairedAddress(of: paired, hostname: "100.64.0.2", addressKind: .tailscaleIPv4)
        let pairedB = pairedStore.machines[0]
        try pairedStore.updatePairedAddress(of: pairedB, hostname: paired.hostname, addressKind: .tailscaleMagicDNS)
        publishHost("fresh-paired-a", machine: paired, store: pairedStore); await pairedCoordinator.flush(for: paired)
        let pairedRecreated = MobileAgentListCache(machineStore: pairedStore, directory: pairedDir)
        check(await pairedRecreated.snapshot(for: paired)?.host.panes.first?.label == "fresh-paired-a", "paired-address A-B-A resumes with fresh state")
    }

    static func processLossDoesNotResurrectRetiredDisk(_ root: URL) async throws {
        let dir = root.appendingPathComponent("process-loss-edit", isDirectory: true), id = UUID(), original = machine(id: id)
        let (store, _) = try makeStore(original, name: "process-loss-edit")
        let disk = AgentListCache(directory: dir), generation = await disk.generation(for: original.connectionIdentity)
        check(await disk.store(snapshot(original, label: "retired"), for: original.connectionIdentity, generation: generation), "fixture stores old disk before edit")
        let gate = Gate()
        let blockingCoordinator = MobileAgentListCache(machineStore: store, directory: dir, testingHooks: .init(evictIdentity: { _ in await gate.wait(); return true }))
        var changed = original; changed.hostname = "b.fixture.invalid"; try store.updateMachine(changed, replacing: original)
        let b = store.machines[0]; try store.updateMachine(original, replacing: b)
        let recreated = MobileAgentListCache(machineStore: store, directory: dir)
        check(await recreated.snapshot(for: original) == nil, "process recreation denies retired A disk before blocked eviction can run")
        await gate.release()
        _ = blockingCoordinator

        let removeDir = root.appendingPathComponent("process-loss-remove", isDirectory: true), removed = machine(id: UUID())
        let (removeStore, _) = try makeStore(removed, name: "process-loss-remove")
        let removeDisk = AgentListCache(directory: removeDir), removeGeneration = await removeDisk.generation(for: removed.connectionIdentity)
        check(await removeDisk.store(snapshot(removed, label: "removed"), for: removed.connectionIdentity, generation: removeGeneration), "fixture stores old disk before removal")
        let removeGate = Gate()
        let blockingRemovalCoordinator = MobileAgentListCache(machineStore: removeStore, directory: removeDir, testingHooks: .init(evictMachine: { _ in await removeGate.wait(); return true }))
        check(removeStore.removeMachine(removed), "removal commits after durable journal retirement")
        try removeStore.addMachine(removed, privateKey: Data("owned-readd".utf8))
        let removeRecreated = MobileAgentListCache(machineStore: removeStore, directory: removeDir)
        check(await removeRecreated.snapshot(for: removed) == nil, "machine retirement prevents removed disk resurrection after recreation")
        await removeGate.release()
        _ = blockingRemovalCoordinator
    }

    /// This is the original P1 sequence: A and B survive an interrupted
    /// removal, A is freshly re-enabled, then B becomes current. The raw actor
    /// check is a negative control proving B existed before the barrier ran.
    static func machineRetirementPurgesHistoricalVariants(_ root: URL) async throws {
        let dir = root.appendingPathComponent("machine-variants", isDirectory: true), id = UUID(), a = machine("a.fixture.invalid", id: id)
        var b = a; b.hostname = "b.fixture.invalid"
        let (store, _) = try makeStore(a, name: "machine-variants")
        let disk = AgentListCache(directory: dir)
        let aGeneration = await disk.generation(for: a.connectionIdentity)
        check(await disk.store(snapshot(a, label: "pre-removal-a"), for: a.connectionIdentity, generation: aGeneration), "fixture retains historical A before interrupted machine eviction")
        let bGeneration = await disk.generation(for: b.connectionIdentity)
        check(await disk.store(snapshot(b, label: "pre-removal-b"), for: b.connectionIdentity, generation: bGeneration), "negative control: raw cache retains historical B before barrier")

        let gate = Gate()
        let interrupted = MobileAgentListCache(machineStore: store, directory: dir, testingHooks: .init(evictMachine: { _ in
            await gate.wait(); return true
        }))
        check(store.removeMachine(a), "machine removal commits after durable machine retirement")
        try store.addMachine(a, privateKey: Data("owned-readd".utf8))
        let recreated = MobileAgentListCache(machineStore: store, directory: dir)
        publishHost("fresh-a", machine: a, store: store)
        await recreated.flush(for: a)
        check(await AgentListCache(directory: dir).load(for: b.connectionIdentity) == nil, "fresh A waits for all-variant purge before it can clear machine barrier")
        try store.updateMachine(b, replacing: a)
        let currentB = store.machines[0]
        check(await recreated.snapshot(for: currentB) == nil, "historical B cannot resurrect after A re-enable")
        await gate.release()
        _ = interrupted
    }

    static func failedMachineEvictionKeepsBarrier(_ root: URL) async throws {
        let dir = root.appendingPathComponent("failed-machine-eviction", isDirectory: true), removed = machine()
        let (store, _) = try makeStore(removed, name: "failed-machine-eviction")
        let disk = AgentListCache(directory: dir), generation = await disk.generation(for: removed.connectionIdentity)
        check(await disk.store(snapshot(removed, label: "old-machine"), for: removed.connectionIdentity, generation: generation), "fixture stores old machine value before failed eviction")
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir, testingHooks: .init(evictMachine: { _ in false }))
        check(store.removeMachine(removed), "machine removal records barrier before eviction failure")
        try store.addMachine(removed, privateKey: Data("owned-readd".utf8))
        publishHost("unsafe-fresh", machine: removed, store: store)
        await coordinator.flush(for: removed)
        check(await AgentListCache(directory: dir).load(for: removed.connectionIdentity)?.host.panes.first?.label == "old-machine", "failed machine eviction leaves old disk untouched")
        check(await coordinator.snapshot(for: removed) == nil, "failed machine eviction keeps durable barrier and blocks re-enable")
    }

    static func lateMachineEvictionAcknowledgementKeepsNewestBarrier(_ root: URL) async throws {
        let dir = root.appendingPathComponent("late-machine-ack", isDirectory: true), removed = machine()
        let (store, _) = try makeStore(removed, name: "late-machine-ack")
        let gates = SequencedEvictionGate()
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir, testingHooks: .init(evictMachine: { _ in
            await gates.evict()
        }))
        check(store.removeMachine(removed), "first retirement commits")
        await gates.waitUntilFirstArrived()
        try store.addMachine(removed, privateKey: Data("first-readd".utf8))
        publishHost("first-fresh", machine: removed, store: store)
        let firstStore = Task { await coordinator.flush(for: removed) }
        await pause()
        check(store.removeMachine(removed), "second retirement replaces first barrier")
        await gates.waitUntilSecondArrived()
        try store.addMachine(removed, privateKey: Data("second-readd".utf8))
        await gates.releaseFirst()
        await firstStore.value
        check(await coordinator.snapshot(for: removed) == nil, "late first eviction acknowledgement cannot clear newer retirement")
        await gates.releaseSecond()
        publishHost("final-fresh", machine: removed, store: store)
        await coordinator.flush(for: removed)
        check(await persistedLabel(dir, machine: removed) == "final-fresh", "newest retirement clears only after its own eviction acknowledgement")
    }

    static func retirementFailureRejectsCredentialReplacement(_ root: URL) async throws {
        let path = root.appendingPathComponent("journal-is-file")
        try Data("not a directory".utf8).write(to: path)
        let original = machine(); let (store, secrets) = try makeStore(original, name: "retirement-failure")
        _ = MobileAgentListCache(machineStore: store, directory: path)
        var replacement = original; replacement.hostname = "replacement.fixture.invalid"
        do {
            try store.updateMachine(replacement, replacing: original, replacementSecret: Data("replacement".utf8))
            preconditionFailure("unsafe edit unexpectedly committed")
        } catch MachineStore.EditError.cacheInvalidationFailed { checks += 1 }
        check(store.machines[0].connectionIdentity == original.connectionIdentity, "failed journal keeps original connection current")
        check(secrets.writes.count == 1, "failed retirement prevents replacement credential write")
    }

    static func corruptAndCapacityBoundedJournalFailsClosed(_ root: URL) async throws {
        let corruptDir = root.appendingPathComponent("corrupt-journal", isDirectory: true), corruptMachine = machine()
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptDisk = AgentListCache(directory: corruptDir), corruptGeneration = await corruptDisk.generation(for: corruptMachine.connectionIdentity)
        check(await corruptDisk.store(snapshot(corruptMachine, label: "corrupt-old"), for: corruptMachine.connectionIdentity, generation: corruptGeneration), "fixture stores old cache before corrupt journal")
        try Data("{not-json".utf8).write(to: corruptDir.appendingPathComponent("agent-list-cache-retired-v1.json"))
        let (corruptStore, corruptSecrets) = try makeStore(corruptMachine, name: "corrupt-journal")
        let corruptCoordinator = MobileAgentListCache(machineStore: corruptStore, directory: corruptDir)
        var corruptReplacement = corruptMachine; corruptReplacement.hostname = "replacement.fixture.invalid"
        do {
            try corruptStore.updateMachine(corruptReplacement, replacing: corruptMachine, replacementSecret: Data("replacement".utf8))
            preconditionFailure("corrupt journal unexpectedly allowed unsafe edit")
        } catch MachineStore.EditError.cacheInvalidationFailed { checks += 1 }
        check(corruptSecrets.writes.count == 1, "corrupt journal rejects replacement credential write")
        check(await corruptCoordinator.snapshot(for: corruptMachine) == nil, "corrupt journal fails closed rather than re-enabling stale disk")

        let oversizedDir = root.appendingPathComponent("oversized-journal", isDirectory: true), oversizedMachine = machine()
        try FileManager.default.createDirectory(at: oversizedDir, withIntermediateDirectories: true)
        let oversizedDisk = AgentListCache(directory: oversizedDir), oversizedGeneration = await oversizedDisk.generation(for: oversizedMachine.connectionIdentity)
        check(await oversizedDisk.store(snapshot(oversizedMachine, label: "oversized-old"), for: oversizedMachine.connectionIdentity, generation: oversizedGeneration), "fixture stores old cache before oversized journal")
        try Data(repeating: 0x78, count: 64 * 1024 + 1).write(to: oversizedDir.appendingPathComponent("agent-list-cache-retired-v1.json"))
        let (oversizedStore, oversizedSecrets) = try makeStore(oversizedMachine, name: "oversized-journal")
        let oversizedCoordinator = MobileAgentListCache(machineStore: oversizedStore, directory: oversizedDir)
        var oversizedReplacement = oversizedMachine; oversizedReplacement.hostname = "replacement.fixture.invalid"
        do {
            try oversizedStore.updateMachine(oversizedReplacement, replacing: oversizedMachine, replacementSecret: Data("replacement".utf8))
            preconditionFailure("oversized journal unexpectedly allowed unsafe edit")
        } catch MachineStore.EditError.cacheInvalidationFailed { checks += 1 }
        check(oversizedSecrets.writes.count == 1, "oversized journal rejects replacement credential write before mutation")
        check(await oversizedCoordinator.snapshot(for: oversizedMachine) == nil, "oversized journal is rejected before decode and blocks stale re-enable")

        let capacityDir = root.appendingPathComponent("capacity-journal", isDirectory: true), id = UUID(), current = machine("current.fixture.invalid", id: id)
        let (capacityStore, capacitySecrets) = try makeStore(current, name: "capacity-journal")
        let capacityDisk = AgentListCache(directory: capacityDir), capacityGeneration = await capacityDisk.generation(for: current.connectionIdentity)
        check(await capacityDisk.store(snapshot(current, label: "capacity-old"), for: current.connectionIdentity, generation: capacityGeneration), "fixture stores old cache before full journal")
        try writeFullMachineRetirementJournal(directory: capacityDir, machineID: id)
        let capacityCoordinator = MobileAgentListCache(machineStore: capacityStore, directory: capacityDir)
        var capacityReplacement = current; capacityReplacement.hostname = "replacement.fixture.invalid"
        do {
            try capacityStore.updateMachine(capacityReplacement, replacing: current, replacementSecret: Data("replacement".utf8))
            preconditionFailure("full journal unexpectedly allowed unsafe edit")
        } catch MachineStore.EditError.cacheInvalidationFailed { checks += 1 }
        check(capacitySecrets.writes.count == 1, "full journal rejects replacement credential write")
        check(await capacityCoordinator.snapshot(for: current) == nil, "full journal's machine barrier blocks stale re-enable")
        publishHost("capacity-fresh", machine: current, store: capacityStore)
        await capacityCoordinator.flush(for: current)
        check(await persistedLabel(capacityDir, machine: current) == "capacity-fresh", "successful all-variant purge permits fresh storage")
        try capacityStore.updateMachine(capacityReplacement, replacing: current, replacementSecret: Data("replacement".utf8))
        check(capacitySecrets.writes.count == 2, "successful purge reclaims bounded retirement capacity safely")
    }

    /// A syntactically valid v2 journal at its exact identity cap. All entries
    /// share the retired machine, so only a successful machine eviction may
    /// reclaim them; a random cap cleanup would make this fixture unsafe.
    static func writeFullMachineRetirementJournal(directory: URL, machineID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identities: [[String: Any]] = (1...64).map { index in
            [
                "identity": [
                    "machineID": machineID.uuidString,
                    "hostname": "historical-\(index).fixture.invalid",
                    "port": 2222,
                    "username": "fixture",
                    "sessionName": "board",
                    "authMethod": "key",
                    "credentialReferenceDigest": "digest-\(index)",
                    "isLocal": false,
                ],
                "incarnation": index,
            ]
        }
        let journal: [String: Any] = [
            "schemaVersion": 2,
            "nextIncarnation": 65,
            "identities": identities,
            "machines": [[
                "machineID": machineID.uuidString,
                "incarnation": 65,
                "identityIncarnationThrough": 64,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("agent-list-cache-retired-v1.json"), options: .withoutOverwriting)
    }

    static func burstCoalescesFinalSnapshot(_ root: URL) async throws {
        let dir = root.appendingPathComponent("burst", isDirectory: true), machine = machine()
        let (store, _) = try makeStore(machine, name: "burst")
        var writes = 0
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir, testingHooks: .init(didStore: { _, _, stored in if stored { writes += 1 } }))
        for index in 0..<8 { publishHost("burst-\(index)", machine: machine, store: store) }
        await pause(350)
        check(writes == 1, "burst coalesces eight publications into one durable write")
        check(await persistedLabel(dir, machine: machine) == "burst-7", "coalesced write persists final burst snapshot")
        publishHost("flush-final", machine: machine, store: store); await coordinator.flush(for: machine)
        let flushedLabel = await persistedLabel(dir, machine: machine)
        check(writes == 2 && flushedLabel == "flush-final", "flush persists final pending state without debounce delay")
    }

    static func emptyAndFailedRoundRetention(_ root: URL) async throws {
        let dir = root.appendingPathComponent("empty-retention", isDirectory: true), machine = machine()
        let (store, _) = try makeStore(machine, name: "empty-retention")
        let coordinator = MobileAgentListCache(machineStore: store, directory: dir)
        publishHost("nonempty", machine: machine, store: store); await coordinator.flush(for: machine)
        let monitor = MachineMonitors.shared.monitor(for: machine, in: store)
        monitor.panes = []; monitor.tabs = []; monitor.workspaces = []; monitor.hasLoaded = true
        MachineMonitors.shared.publish(.host, for: machine, in: store); await coordinator.flush(for: machine)
        check(await persistedLabel(dir, machine: machine) == nil, "successful empty host replaces prior nonempty cached rows")
        // Failed monitor rounds deliberately do not publish. The last successful empty snapshot remains cache state.
        monitor.hasLoaded = false
        await coordinator.flush(for: machine)
        let recreated = MobileAgentListCache(machineStore: store, directory: dir)
        check(await recreated.snapshot(for: machine)?.host.panes.isEmpty == true, "error/no-publication retains successful empty snapshot rather than resurrecting rows")
    }
}
