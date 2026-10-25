import CryptoKit
import Foundation

/// Display-only, persistent input for the mobile Board. This never contains a
/// session reference, terminal output, transcripts, or credential material.
///
/// `AgentListCache` has no singleton or application-support default: the iOS
/// composition root must explicitly create it. That keeps macOS unchanged.
public actor AgentListCache {
    public static let schemaVersion = 1
    public static let fileName = "agent-list-cache-v1.json"

    fileprivate static let maximumFileBytes = 2 * 1024 * 1024
    fileprivate static let maximumRecords = 64
    fileprivate static let maximumNestedGroups = 64
    fileprivate static let maximumPanes = 2_000
    fileprivate static let maximumTabs = 512
    fileprivate static let maximumWorkspaces = 512
    fileprivate static let maximumPlacements = 2_000
    fileprivate static let maximumStringLength = 4_096

    /// The non-secret, stable cache key for one exact connection. The raw
    /// Keychain tag is deliberately not Codable and never enters the file.
    public struct ConnectionFingerprint: Codable, Hashable, Sendable {
        public let machineID: UUID
        public let hostname: String
        public let port: Int
        public let username: String
        public let sessionName: String
        public let authMethod: Machine.AuthMethod
        public let credentialReferenceDigest: String
        public let isLocal: Bool
        public let addressKind: Machine.AddressKind?

        public init(_ identity: Machine.ConnectionIdentity) {
            machineID = identity.machineID
            hostname = identity.hostname
            port = identity.port
            username = identity.username
            sessionName = identity.sessionName
            authMethod = identity.authMethod
            credentialReferenceDigest = Data(SHA256.hash(data: Data(identity.keychainTag.utf8))).base64EncodedString()
            isLocal = identity.isLocal
            addressKind = identity.addressKind
        }
    }

    /// The allowed, display-only representation of one saved herdr machine.
    public struct HerdrMachineDTO: Codable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let target: String
        public let session: String
        public let enabled: Bool

        public init(id: String, label: String, target: String, session: String, enabled: Bool) {
            self.id = id
            self.label = label
            self.target = target
            self.session = session
            self.enabled = enabled
        }
    }

    /// The allowed, display-only representation of a Board pane.
    public struct AgentDTO: Codable, Equatable, Sendable {
        public let paneID: String
        public let previousPaneID: String?
        public let tabID: String?
        public let workspaceID: String?
        public let terminalID: String
        public let herdrMachine: HerdrMachineDTO?
        public let source: String?
        public let interactiveReady: Bool?
        public let launchPending: Bool?
        public let screenDetectionSkipped: Bool?
        public let stateChangeSequence: Int?
        public let agentName: String?
        public let terminalTitle: String?
        public let label: String?
        public let workingDirectory: String?
        /// One of the `AgentState` raw values. It is metadata, not output.
        public let state: String
        public let revision: Int

        public init(paneID: String, previousPaneID: String? = nil, tabID: String? = nil, workspaceID: String? = nil,
                    terminalID: String, herdrMachine: HerdrMachineDTO? = nil, source: String? = nil,
                    interactiveReady: Bool? = nil, launchPending: Bool? = nil, screenDetectionSkipped: Bool? = nil,
                    stateChangeSequence: Int? = nil, agentName: String? = nil, terminalTitle: String? = nil,
                    label: String? = nil, workingDirectory: String? = nil, state: String, revision: Int) {
            self.paneID = paneID
            self.previousPaneID = previousPaneID
            self.tabID = tabID
            self.workspaceID = workspaceID
            self.terminalID = terminalID
            self.herdrMachine = herdrMachine
            self.source = source
            self.interactiveReady = interactiveReady
            self.launchPending = launchPending
            self.screenDetectionSkipped = screenDetectionSkipped
            self.stateChangeSequence = stateChangeSequence
            self.agentName = agentName
            self.terminalTitle = terminalTitle
            self.label = label
            self.workingDirectory = workingDirectory
            self.state = state
            self.revision = revision
        }
    }

    public struct PanePlacementDTO: Codable, Equatable, Sendable {
        public let paneID: String
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(paneID: String, x: Double, y: Double, width: Double, height: Double) {
            self.paneID = paneID
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct TabDTO: Codable, Equatable, Sendable {
        public let tabID: String
        public let workspaceID: String?
        public let label: String
        public let focusedPaneID: String?
        public let paneIDs: [String]
        public let placements: [PanePlacementDTO]

        public init(tabID: String, workspaceID: String? = nil, label: String, focusedPaneID: String? = nil,
                    paneIDs: [String], placements: [PanePlacementDTO]) {
            self.tabID = tabID
            self.workspaceID = workspaceID
            self.label = label
            self.focusedPaneID = focusedPaneID
            self.paneIDs = paneIDs
            self.placements = placements
        }
    }

    public struct WorkspaceDTO: Codable, Equatable, Sendable {
        public let workspaceID: String
        public let label: String

        public init(workspaceID: String, label: String) {
            self.workspaceID = workspaceID
            self.label = label
        }
    }

    public struct SnapshotDTO: Codable, Equatable, Sendable {
        public let panes: [AgentDTO]
        /// Nil means the live server did not supply tabs; [] is a successful empty list.
        public let tabs: [TabDTO]?
        /// Nil means the live server did not supply workspaces; [] is successful empty.
        public let workspaces: [WorkspaceDTO]?

        public init(panes: [AgentDTO], tabs: [TabDTO]?, workspaces: [WorkspaceDTO]?) {
            self.panes = panes
            self.tabs = tabs
            self.workspaces = workspaces
        }
    }

    public struct NestedGroupDTO: Codable, Equatable, Sendable {
        public let machine: HerdrMachineDTO
        public let snapshot: SnapshotDTO

        public init(machine: HerdrMachineDTO, snapshot: SnapshotDTO) {
            self.machine = machine
            self.snapshot = snapshot
        }
    }

    /// An immutable complete cache value. A live successful host publication
    /// replaces `host`, and a completed nested round supplies a complete
    /// `nestedGroups` array assembled by its owner: successful groups replace,
    /// failed groups retain their previous DTO, and a genuine empty result is
    /// represented by `[]`. Storage never guesses whether an omission failed.
    public struct Snapshot: Codable, Equatable, Sendable {
        public let identity: ConnectionFingerprint
        public let savedAt: TimeInterval
        public let host: SnapshotDTO
        public let nestedGroups: [NestedGroupDTO]

        public init(identity: ConnectionFingerprint, savedAt: TimeInterval = Date().timeIntervalSince1970,
                    host: SnapshotDTO, nestedGroups: [NestedGroupDTO]) {
            self.identity = identity
            self.savedAt = savedAt
            self.host = host
            self.nestedGroups = nestedGroups
        }

        public func replacing(host: SnapshotDTO, savedAt: TimeInterval = Date().timeIntervalSince1970) -> Self {
            Self(identity: identity, savedAt: savedAt, host: host, nestedGroups: nestedGroups)
        }

        public func replacing(nestedGroups: [NestedGroupDTO], savedAt: TimeInterval = Date().timeIntervalSince1970) -> Self {
            Self(identity: identity, savedAt: savedAt, host: host, nestedGroups: nestedGroups)
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let snapshots: [Snapshot]
    }

    private enum LoadState {
        case notLoaded
        case loaded(Envelope)
        /// Existing unreadable/invalid bytes are intentionally never replaced.
        case unavailable
    }

    private let directory: URL
    private let fileURL: URL
    private let fileManager: FileManager
    private var loadState: LoadState = .notLoaded
    /// Only currently usable leases are retained. Invalidating a lease removes
    /// it; a globally unique replacement token prevents an old lease from
    /// becoming valid again if that identity is later re-added.
    private var generations: [ConnectionFingerprint: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

    /// `directory` must be an app-owned directory. Tests inject an owned
    /// temporary directory; production iOS code must pass Application Support.
    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.fileManager = fileManager
    }

    /// Returns the matching cache value, or nil for absent, malformed,
    /// oversized, version-mismatched, and unreadable data. No bad file is
    /// deleted or rewritten by a failed load.
    public func load(for identity: Machine.ConnectionIdentity) -> Snapshot? {
        guard let envelope = ensureLoaded() else { return nil }
        return envelope.snapshots.first { $0.identity == ConnectionFingerprint(identity) }
    }

    /// An opaque, non-reusable token for one identity. Callers capture this
    /// before async work and pass it to `store`; `evict`/`prune` invalidate old
    /// tokens so late tasks cannot recreate an evicted cache value. If the
    /// bounded lease table or token space is exhausted, this returns `.max`;
    /// `.max` is never issued and `store` rejects it.
    public func generation(for identity: Machine.ConnectionIdentity) -> UInt64 {
        let fingerprint = ConnectionFingerprint(identity)
        if let generation = generations[fingerprint] { return generation }
        guard let generation = issueGeneration() else { return .max }
        generations[fingerprint] = generation
        return generation
    }

    /// Stores a complete immutable value only when it still belongs to the
    /// captured identity generation. Failure preserves both the prior valid
    /// file and the cache's last loaded in-memory envelope.
    @discardableResult
    public func store(_ snapshot: Snapshot, for identity: Machine.ConnectionIdentity, generation: UInt64) -> Bool {
        let fingerprint = ConnectionFingerprint(identity)
        guard snapshot.identity == fingerprint,
              let currentGeneration = generations[fingerprint],
              currentGeneration == generation,
              snapshot.isWithinBounds else { return false }
        guard let current = ensureLoaded() else { return false }

        var snapshots = current.snapshots.filter { $0.identity != fingerprint }
        snapshots.append(snapshot)
        guard snapshots.count <= Self.maximumRecords else { return false }
        let next = Envelope(schemaVersion: Self.schemaVersion, snapshots: snapshots)
        guard write(next) else { return false }
        loadState = .loaded(next)
        return true
    }

    /// Removes every cache value for this exact connection and invalidates its
    /// outstanding writers. This is the operation required before an identity
    /// edit; use `evict(machineID:)` for deletion.
    @discardableResult
    public func evict(_ identity: Machine.ConnectionIdentity) -> Bool {
        let fingerprint = ConnectionFingerprint(identity)
        invalidate(fingerprint)
        return removing { $0.identity == fingerprint }
    }

    /// Removes all saved connection variants for a removed machine and blocks
    /// writers that captured any of their old generations, including variants
    /// that have not reached their first store yet.
    @discardableResult
    public func evict(machineID: UUID) -> Bool {
        invalidate { $0.machineID == machineID }
        guard let current = ensureLoaded() else { return false }
        return persist(current.snapshots.filter { $0.identity.machineID != machineID })
    }

    /// Keeps only current exact identities. This also evicts stale identities
    /// created by connection edits, paired-address changes, or removals,
    /// including issued identities that have not been stored yet.
    @discardableResult
    public func prune(keeping identities: [Machine.ConnectionIdentity]) -> Bool {
        let keep = Set(identities.map(ConnectionFingerprint.init))
        invalidate { !keep.contains($0) }
        guard let current = ensureLoaded() else { return false }
        return persist(current.snapshots.filter { keep.contains($0.identity) })
    }

    private func issueGeneration() -> UInt64? {
        guard generations.count < Self.maximumRecords, nextGeneration < .max else { return nil }
        defer { nextGeneration += 1 }
        return nextGeneration
    }

    private func invalidate(_ fingerprint: ConnectionFingerprint) {
        generations.removeValue(forKey: fingerprint)
    }

    private func invalidate(where shouldInvalidate: (ConnectionFingerprint) -> Bool) {
        for fingerprint in generations.keys.filter(shouldInvalidate) {
            invalidate(fingerprint)
        }
    }

    private func removing(_ shouldRemove: (Snapshot) -> Bool) -> Bool {
        guard let current = ensureLoaded() else { return false }
        return persist(current.snapshots.filter { !shouldRemove($0) })
    }

    private func persist(_ snapshots: [Snapshot]) -> Bool {
        let next = Envelope(schemaVersion: Self.schemaVersion, snapshots: snapshots)
        guard write(next) else { return false }
        loadState = .loaded(next)
        return true
    }

    private func ensureLoaded() -> Envelope? {
        switch loadState {
        case .loaded(let envelope): return envelope
        case .unavailable: return nil
        case .notLoaded: break
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = Envelope(schemaVersion: Self.schemaVersion, snapshots: [])
            loadState = .loaded(empty)
            return empty
        }
        do {
            let data = try readBoundedFile()
            let decoded = try JSONDecoder().decode(Envelope.self, from: data)
            guard decoded.schemaVersion == Self.schemaVersion,
                  decoded.snapshots.count <= Self.maximumRecords,
                  decoded.snapshots.allSatisfy(\.isWithinBounds) else { throw CacheReadError.invalid }
            loadState = .loaded(decoded)
            return decoded
        } catch {
            loadState = .unavailable
            return nil
        }
    }

    /// Reads at most one byte beyond the cache limit, so a hostile file is not
    /// mapped or materialized in full before its size is rejected.
    private func readBoundedFile() throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else { throw CacheReadError.invalid }
        return data
    }

    private func write(_ envelope: Envelope) -> Bool {
        guard envelope.schemaVersion == Self.schemaVersion,
              envelope.snapshots.count <= Self.maximumRecords,
              envelope.snapshots.allSatisfy(\.isWithinBounds) else { return false }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(envelope)
            guard data.count <= Self.maximumFileBytes else { return false }
            let temporary = directory.appendingPathComponent(".agent-list-cache-\(UUID().uuidString).tmp")
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

    private enum CacheReadError: Error { case invalid }
}

private extension AgentListCache.Snapshot {
    nonisolated var isWithinBounds: Bool {
        guard savedAt.isFinite,
              identity.isWithinBounds,
              host.isWithinBounds,
              nestedGroups.count <= AgentListCache.maximumNestedGroups,
              nestedGroups.allSatisfy(\.isWithinBounds) else { return false }
        return true
    }
}

private extension AgentListCache.ConnectionFingerprint {
    nonisolated var isWithinBounds: Bool {
        port > 0 && port <= 65_535 && hostname.isCacheString && username.isCacheString &&
        sessionName.isCacheString && credentialReferenceDigest.isCacheString
    }
}

private extension AgentListCache.HerdrMachineDTO {
    nonisolated var isWithinBounds: Bool {
        id.isCacheString && label.isCacheString && target.isCacheString && session.isCacheString
    }
}

private extension AgentListCache.AgentDTO {
    nonisolated var isWithinBounds: Bool {
        guard paneID.isCacheString, terminalID.isCacheString,
              previousPaneID.isCacheOptionalString, tabID.isCacheOptionalString,
              workspaceID.isCacheOptionalString, source.isCacheOptionalString,
              agentName.isCacheOptionalString, terminalTitle.isCacheOptionalString,
              label.isCacheOptionalString, workingDirectory.isCacheOptionalString,
              ["idle", "working", "blocked", "done", "unknown"].contains(state) else { return false }
        return herdrMachine?.isWithinBounds ?? true
    }
}

private extension AgentListCache.PanePlacementDTO {
    nonisolated var isWithinBounds: Bool {
        paneID.isCacheString && x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}

private extension AgentListCache.TabDTO {
    nonisolated var isWithinBounds: Bool {
        tabID.isCacheString && workspaceID.isCacheOptionalString && label.isCacheString &&
        focusedPaneID.isCacheOptionalString && paneIDs.count <= AgentListCache.maximumPanes &&
        placements.count <= AgentListCache.maximumPlacements && paneIDs.allSatisfy(\.isCacheString) &&
        placements.allSatisfy(\.isWithinBounds)
    }
}

private extension AgentListCache.WorkspaceDTO {
    nonisolated var isWithinBounds: Bool { workspaceID.isCacheString && label.isCacheString }
}

private extension AgentListCache.SnapshotDTO {
    nonisolated var isWithinBounds: Bool {
        panes.count <= AgentListCache.maximumPanes && (tabs?.count ?? 0) <= AgentListCache.maximumTabs &&
        (workspaces?.count ?? 0) <= AgentListCache.maximumWorkspaces && panes.allSatisfy(\.isWithinBounds) &&
        (tabs?.allSatisfy(\.isWithinBounds) ?? true) && (workspaces?.allSatisfy(\.isWithinBounds) ?? true)
    }
}

private extension AgentListCache.NestedGroupDTO {
    nonisolated var isWithinBounds: Bool { machine.isWithinBounds && snapshot.isWithinBounds }
}

private extension String {
    nonisolated var isCacheString: Bool { !isEmpty && count <= AgentListCache.maximumStringLength }
}

private extension Optional where Wrapped == String {
    nonisolated var isCacheOptionalString: Bool { map(\.isCacheString) ?? true }
}
