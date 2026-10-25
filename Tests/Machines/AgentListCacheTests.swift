import Foundation

@main struct AgentListCacheTests {
    static var checks = 0

    static func check(_ condition: Bool, _ name: String) {
        precondition(condition, name)
        checks += 1
    }

    static func identity(hostname: String = "cache.example", tag: String = "synthetic-keychain-reference",
                         machineID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> Machine.ConnectionIdentity {
        var machine = Machine(id: machineID, displayName: "Cache fixture",
                              hostname: hostname, port: 2222, username: "fixture", authMethod: .key,
                              sessionName: "board", isLocal: false, addressKind: .tailscaleMagicDNS)
        machine.keychainTag = tag
        return machine.connectionIdentity
    }

    static let nestedMachine = AgentListCache.HerdrMachineDTO(id: "remote-1", label: "Remote", target: "fixture@remote.invalid", session: "nested", enabled: true)

    static func host(_ label: String = "Agent") -> AgentListCache.SnapshotDTO {
        AgentListCache.SnapshotDTO(
            panes: [AgentListCache.AgentDTO(paneID: "p1", previousPaneID: "p0", tabID: "t1", workspaceID: "w1",
                                             terminalID: "term-1", source: "herdr:fixture", interactiveReady: true,
                                             launchPending: false, screenDetectionSkipped: false, stateChangeSequence: 4,
                                             agentName: "fixture-agent", terminalTitle: "Fixture", label: label,
                                             workingDirectory: "/owned/fixture", state: "working", revision: 7)],
            tabs: [AgentListCache.TabDTO(tabID: "t1", workspaceID: "w1", label: "One", focusedPaneID: "p1", paneIDs: ["p1"],
                                         placements: [AgentListCache.PanePlacementDTO(paneID: "p1", x: 0, y: 0, width: 1, height: 1)])],
            workspaces: [AgentListCache.WorkspaceDTO(workspaceID: "w1", label: "Workspace")]
        )
    }

    static func snapshot(_ identity: Machine.ConnectionIdentity, host: AgentListCache.SnapshotDTO? = nil,
                         nestedGroups: [AgentListCache.NestedGroupDTO] = []) -> AgentListCache.Snapshot {
        AgentListCache.Snapshot(identity: .init(identity), savedAt: 1_700_000_000, host: host ?? self.host(), nestedGroups: nestedGroups)
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("expected owned test directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        try await restartRoundTripAndAllowlist(root.appendingPathComponent("roundtrip", isDirectory: true))
        try await emptyFailureAndPartialRetention(root.appendingPathComponent("merge", isDirectory: true))
        try await identityInvalidation(root.appendingPathComponent("identity", isDirectory: true))
        try await issuedIdentityInvalidation(root.appendingPathComponent("issued-identity", isDirectory: true))
        try await boundedGenerationLeases(root.appendingPathComponent("leases", isDirectory: true))
        try await boundsCorruptionAndAtomicFailure(root.appendingPathComponent("failure", isDirectory: true))
        print("PASS \(checks) agent-list cache storage checks; owned temporary storage only")
    }

    static func restartRoundTripAndAllowlist(_ directory: URL) async throws {
        let connection = identity()
        let cache = AgentListCache(directory: directory)
        let value = snapshot(connection)
        let generation = await cache.generation(for: connection)
        check(await cache.store(value, for: connection, generation: generation), "stores valid display snapshot")

        let restarted = AgentListCache(directory: directory)
        check(await restarted.load(for: connection) == value, "restart loads exact snapshot before any network work")
        let encoded = try String(contentsOf: directory.appendingPathComponent(AgentListCache.fileName), encoding: .utf8)
        for forbidden in ["sessionReference", "conversation", "output", "transcript", "keychainTag", "synthetic-keychain-reference"] {
            check(!encoded.localizedCaseInsensitiveContains(forbidden), "encoded cache excludes \(forbidden)")
        }
        check(encoded.contains("credentialReferenceDigest"), "identity retains only a credential-reference digest")
    }

    static func emptyFailureAndPartialRetention(_ directory: URL) async throws {
        let connection = identity()
        let cache = AgentListCache(directory: directory)
        let oldNested = AgentListCache.NestedGroupDTO(machine: nestedMachine, snapshot: host("Nested old"))
        let old = snapshot(connection, nestedGroups: [oldNested])
        let generation = await cache.generation(for: connection)
        check(await cache.store(old, for: connection, generation: generation), "stores non-empty host and nested result")

        // A live successful empty host replaces the old host; a failed nested
        // group remains in the owner-assembled immutable next snapshot.
        let emptyHost = AgentListCache.SnapshotDTO(panes: [], tabs: [], workspaces: [])
        let afterHostSuccess = old.replacing(host: emptyHost, savedAt: 1_700_000_001)
        check(await cache.store(afterHostSuccess, for: connection, generation: generation), "stores authoritative empty host")
        check(await cache.load(for: connection)?.host.panes.isEmpty == true, "genuine empty host replaces previous rows")
        let retainedOnNestedFailure = afterHostSuccess.replacing(nestedGroups: [oldNested], savedAt: 1_700_000_002)
        check(await cache.store(retainedOnNestedFailure, for: connection, generation: generation), "stores partial round with retained failed nested group")
        check(await cache.load(for: connection)?.nestedGroups == [oldNested], "nested failure never becomes an empty group")

        // There is no storage write for a host failure, so the last successful
        // snapshot remains available for the next Board entry.
        check(await cache.load(for: connection) == retainedOnNestedFailure, "failed host attempt retains prior successful cache")
    }

    static func identityInvalidation(_ directory: URL) async throws {
        let oldIdentity = identity()
        let cache = AgentListCache(directory: directory)
        let oldGeneration = await cache.generation(for: oldIdentity)
        check(await cache.store(snapshot(oldIdentity), for: oldIdentity, generation: oldGeneration), "stores old identity")
        check(await cache.evict(oldIdentity), "identity edit evicts old cache")
        check(await cache.load(for: oldIdentity) == nil, "eviction removes old identity")
        check(!(await cache.store(snapshot(oldIdentity), for: oldIdentity, generation: oldGeneration)), "late old identity writer is rejected")

        let editedIdentity = identity(hostname: "changed.example")
        let editedGeneration = await cache.generation(for: editedIdentity)
        check(await cache.store(snapshot(editedIdentity), for: editedIdentity, generation: editedGeneration), "new identity can store independently")
        let oldAfterEdit = await cache.load(for: oldIdentity)
        let currentAfterEdit = await cache.load(for: editedIdentity)
        check(oldAfterEdit == nil && currentAfterEdit != nil, "stale cache cannot become current edited pane")
        check(await cache.prune(keeping: []), "prune evicts identities no longer current")
        check(await cache.load(for: editedIdentity) == nil, "prune removes stale edited identity")
        let reloadedGeneration = await cache.generation(for: editedIdentity)
        check(await cache.store(snapshot(editedIdentity), for: editedIdentity, generation: reloadedGeneration), "current identity can store after prune")
        check(await cache.evict(machineID: editedIdentity.machineID), "machine removal evicts all remaining variants")
        check(await cache.load(for: editedIdentity) == nil, "removed machine has no cache")
    }

    static func issuedIdentityInvalidation(_ directory: URL) async throws {
        let removed = identity(hostname: "removed.example")
        let other = identity(hostname: "retained.example", machineID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let cache = AgentListCache(directory: directory)

        let removalGeneration = await cache.generation(for: removed)
        let otherGeneration = await cache.generation(for: other)
        check(!(await cache.store(snapshot(other), for: other, generation: otherGeneration + 1)), "unknown generation is rejected")
        check(await cache.evict(machineID: removed.machineID), "machine removal succeeds with only in-flight identities")
        check(!(await cache.store(snapshot(removed), for: removed, generation: removalGeneration)), "machine removal rejects a writer issued before its first store")
        check(await cache.store(snapshot(other), for: other, generation: otherGeneration), "machine removal leaves an unrelated issued identity valid")
        let readdedRemovalGeneration = await cache.generation(for: removed)
        check(readdedRemovalGeneration != removalGeneration, "re-adding an identity receives a new generation")
        check(await cache.store(snapshot(removed), for: removed, generation: readdedRemovalGeneration), "re-added identity can store with its new generation")

        let pruneOnly = identity(hostname: "pruned-before-store.example", machineID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let pruneGeneration = await cache.generation(for: pruneOnly)
        check(await cache.prune(keeping: [other]), "prune succeeds with an in-flight identity")
        check(!(await cache.store(snapshot(pruneOnly), for: pruneOnly, generation: pruneGeneration)), "prune rejects a writer issued before its first store")
        check(await cache.load(for: other) != nil, "prune retains the kept identity")
        let readdedPruneGeneration = await cache.generation(for: pruneOnly)
        check(readdedPruneGeneration != pruneGeneration, "prune re-add receives a new generation")
        check(await cache.store(snapshot(pruneOnly), for: pruneOnly, generation: readdedPruneGeneration), "pruned identity can store with its new generation")

        let variantsMachineID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let variantOne = identity(hostname: "variant-one.example", machineID: variantsMachineID)
        let variantTwo = identity(hostname: "variant-two.example", tag: "different-keychain-reference", machineID: variantsMachineID)
        let variantOneGeneration = await cache.generation(for: variantOne)
        let variantTwoGeneration = await cache.generation(for: variantTwo)
        check(await cache.evict(machineID: variantOne.machineID), "machine removal invalidates every issued connection variant")
        check(!(await cache.store(snapshot(variantOne), for: variantOne, generation: variantOneGeneration)), "first issued variant is rejected after machine removal")
        check(!(await cache.store(snapshot(variantTwo), for: variantTwo, generation: variantTwoGeneration)), "second issued variant is rejected after machine removal")

        let stored = identity(hostname: "stored-before-removal.example", machineID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        let storedGeneration = await cache.generation(for: stored)
        check(await cache.store(snapshot(stored), for: stored, generation: storedGeneration), "stores identity before machine removal")
        check(await cache.evict(machineID: stored.machineID), "machine removal evicts an existing stored identity")
        check(!(await cache.store(snapshot(stored), for: stored, generation: storedGeneration)), "machine removal rejects an old stored identity writer")
    }

    static func boundedGenerationLeases(_ directory: URL) async throws {
        let cache = AgentListCache(directory: directory)
        for index in 0..<64 {
            let identity = identity(hostname: "lease-\(index).example")
            check(await cache.generation(for: identity) != .max, "issues generation lease \(index)")
        }
        let overflow = identity(hostname: "lease-overflow.example")
        check(await cache.generation(for: overflow) == .max, "generation lease table fails closed at its record bound")
        check(!(await cache.store(snapshot(overflow), for: overflow, generation: .max)), "unissued exhaustion sentinel is rejected")
        check(await cache.prune(keeping: []), "prune releases invalidated generation leases")
        let replacementGeneration = await cache.generation(for: overflow)
        check(replacementGeneration != .max, "pruned lease capacity can be reused without reusing a token")
        check(await cache.store(snapshot(overflow), for: overflow, generation: replacementGeneration), "replacement lease stores successfully")
    }

    static func boundsCorruptionAndAtomicFailure(_ directory: URL) async throws {
        let connection = identity()
        let oversized = String(repeating: "x", count: 4_097)
        let bounded = AgentListCache(directory: directory.appendingPathComponent("bounds", isDirectory: true))
        let badHost = host(oversized)
        let generation = await bounded.generation(for: connection)
        check(!(await bounded.store(snapshot(connection, host: badHost), for: connection, generation: generation)), "oversized strings are rejected before persistence")

        let corruptDirectory = directory.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFile = corruptDirectory.appendingPathComponent(AgentListCache.fileName)
        let corruptData = Data("not cache json".utf8)
        try corruptData.write(to: corruptFile)
        let corrupt = AgentListCache(directory: corruptDirectory)
        check(await corrupt.load(for: connection) == nil, "corrupt file is ignored")
        check(!(await corrupt.store(snapshot(connection), for: connection, generation: await corrupt.generation(for: connection))), "corrupt file is not overwritten")
        check(try Data(contentsOf: corruptFile) == corruptData, "corrupt bytes are preserved for recovery")

        let versionDirectory = directory.appendingPathComponent("version", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        let versionFile = versionDirectory.appendingPathComponent(AgentListCache.fileName)
        let unknownVersion = Data(#"{"schemaVersion":999,"snapshots":[]}"#.utf8)
        try unknownVersion.write(to: versionFile)
        let versionMismatch = AgentListCache(directory: versionDirectory)
        check(await versionMismatch.load(for: connection) == nil, "unknown schema version is rejected")
        check(try Data(contentsOf: versionFile) == unknownVersion, "unknown schema bytes are preserved")

        let oversizedDirectory = directory.appendingPathComponent("oversized-file", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedDirectory, withIntermediateDirectories: true)
        let oversizedFile = oversizedDirectory.appendingPathComponent(AgentListCache.fileName)
        try Data(repeating: 0, count: 2 * 1024 * 1024 + 1).write(to: oversizedFile)
        let oversizedFileCache = AgentListCache(directory: oversizedDirectory)
        check(await oversizedFileCache.load(for: connection) == nil, "oversized file is rejected before decode")

        let atomicDirectory = directory.appendingPathComponent("atomic", isDirectory: true)
        let atomic = AgentListCache(directory: atomicDirectory)
        let atomicGeneration = await atomic.generation(for: connection)
        let original = snapshot(connection)
        check(await atomic.store(original, for: connection, generation: atomicGeneration), "creates prior valid cache before write failure")
        let cacheFile = atomicDirectory.appendingPathComponent(AgentListCache.fileName)
        let priorBytes = try Data(contentsOf: cacheFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: atomicDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: atomicDirectory.path) }
        check(!(await atomic.store(original.replacing(host: host("new")), for: connection, generation: atomicGeneration)), "atomic write failure is reported")
        check(try Data(contentsOf: cacheFile) == priorBytes, "atomic write failure leaves prior file intact")
    }
}
