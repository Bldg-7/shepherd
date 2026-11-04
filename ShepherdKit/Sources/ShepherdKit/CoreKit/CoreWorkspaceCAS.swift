import Foundation

public nonisolated enum CoreWorkspaceSyncFailure: Error, Equatable, Sendable {
    case staleOperation, subscriptionRequired, busy, refreshRequired, versionExhausted, inconsistentSnapshot
}

/// Pure CAS admission bookkeeping for one origin core's app-owned document.
/// The I/O owner subscribes before reading, serializes these transitions, and
/// passes the actual connection epoch. No timers, retries, terminal actions or
/// focus changes happen here. A connection/core identifier is NOT authority.
public nonisolated struct CoreWorkspaceCAS: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let version: UInt64
        /// A successful read of null is missing. No Snapshot is unavailable.
        public let document: CoreWorkspaceDocument?
    }
    public struct Read: Equatable, Sendable {
        public let epoch: UUID
        fileprivate let nonce: UUID
    }
    public struct Write: Equatable, Sendable {
        public let epoch: UUID
        public let expectedVersion: UInt64
        public let document: CoreWorkspaceDocument
        fileprivate let nonce: UUID

        public func parameters(on: String? = nil) throws -> Data {
            // UInt64 is emitted as an integer, never round-tripped through Any/Double.
            var data = Data("{".utf8)
            if let on {
                data.append(Data("\"on\":".utf8)); data.append(try JSONEncoder().encode(on)); data.append(44)
            }
            data.append(Data("\"name\":\"\(CoreWorkspaceDocument.documentName)\",\"version\":\(expectedVersion),\"value\":".utf8))
            data.append(try document.encoded()); data.append(contentsOf: [0x7d])
            return data
        }
    }
    public enum WriteResult: Equatable, Sendable {
        case acknowledged(version: UInt64)
        case conflict
        /// Timeout/disconnect/cancellation is NOT evidence the write failed.
        case uncertain
    }
    public let originCoreID: String
    public private(set) var epoch: UUID
    public private(set) var snapshot: Snapshot?
    public private(set) var refreshRequired = true
    public private(set) var lastWriteResult: WriteResult?
    private var minimumKnownVersion: UInt64 = 0
    private var subscribed = false
    private var reading: Read?
    private var writing: Write?

    public init(originCoreID: String, epoch: UUID) throws {
        guard !originCoreID.isEmpty else { throw CoreWorkspaceFailure.invalidReference }
        self.originCoreID = originCoreID; self.epoch = epoch
    }
    public var canWrite: Bool { subscribed && !refreshRequired && snapshot != nil && reading == nil && writing == nil }

    /// Call on reconnect/disconnect before accepting new I/O. Cached layout is
    /// retained read-only; pending tokens and subscription proof are retired.
    public mutating func reconnect(epoch: UUID) {
        if writing != nil { lastWriteResult = .uncertain }
        self.epoch = epoch; subscribed = false; refreshRequired = true; reading = nil; writing = nil
    }
    public mutating func didSubscribe(coreID: String, epoch: UUID) throws {
        guard coreID == originCoreID, epoch == self.epoch else { throw CoreWorkspaceSyncFailure.staleOperation }
        subscribed = true
        try invalidate(epoch: epoch)
    }
    /// A doc event, missed event, or relevant remote reconnect invalidates a
    /// pending read too. A delayed old snapshot cannot erase a newer event.
    public mutating func invalidate(epoch: UUID, minimumVersion: UInt64? = nil) throws {
        guard epoch == self.epoch else { throw CoreWorkspaceSyncFailure.staleOperation }
        if let minimumVersion { minimumKnownVersion = max(minimumKnownVersion, minimumVersion) }
        refreshRequired = true; reading = nil
    }
    public mutating func beginRead() throws -> Read {
        guard subscribed else { throw CoreWorkspaceSyncFailure.subscriptionRequired }
        guard reading == nil && writing == nil else { throw CoreWorkspaceSyncFailure.busy }
        let token = Read(epoch: epoch, nonce: UUID()); reading = token
        return token
    }
    public mutating func accept(_ token: Read, version: UInt64, document: CoreWorkspaceDocument?) throws {
        guard token == reading, token.epoch == epoch else { throw CoreWorkspaceSyncFailure.staleOperation }
        reading = nil; refreshRequired = true
        guard version >= minimumKnownVersion else { throw CoreWorkspaceSyncFailure.inconsistentSnapshot }
        if let snapshot, version < snapshot.version || (version == snapshot.version && document != snapshot.document) {
            throw CoreWorkspaceSyncFailure.inconsistentSnapshot
        }
        snapshot = Snapshot(version: version, document: document); minimumKnownVersion = version; refreshRequired = false
    }
    public mutating func readFailed(_ token: Read) throws {
        guard token == reading, token.epoch == epoch else { throw CoreWorkspaceSyncFailure.staleOperation }
        reading = nil; refreshRequired = true // Never translate failure into an empty/missing document.
    }
    public mutating func beginWrite(_ document: CoreWorkspaceDocument) throws -> Write {
        guard canWrite, let snapshot else { throw CoreWorkspaceSyncFailure.refreshRequired }
        guard snapshot.version < UInt64.max else { throw CoreWorkspaceSyncFailure.versionExhausted }
        let token = Write(epoch: epoch, expectedVersion: snapshot.version, document: document, nonce: UUID())
        writing = token; lastWriteResult = nil
        return token
    }
    public mutating func finish(_ token: Write, result: WriteResult) throws {
        guard token == writing, token.epoch == epoch else { throw CoreWorkspaceSyncFailure.staleOperation }
        writing = nil; refreshRequired = true; reading = nil
        if case .acknowledged(let version) = result, version != token.expectedVersion + 1 {
            lastWriteResult = .uncertain
            throw CoreWorkspaceSyncFailure.inconsistentSnapshot
        }
        switch result {
        case .acknowledged(let version): minimumKnownVersion = max(minimumKnownVersion, version)
        case .conflict: minimumKnownVersion = max(minimumKnownVersion, token.expectedVersion + 1)
        case .uncertain: break
        }
        lastWriteResult = result
        // Even a successful ACK requires a new subscribed read: another device
        // may have written immediately afterward. Never overwrite/retry blindly.
    }
}
