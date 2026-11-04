import Foundation

public nonisolated enum CoreWorkspaceStoreFailure: Error, Equatable, Sendable {
    case closed, alreadyStarted, staleRevision, subscriberLimit, readFailed, invalidDocument, eventStreamFailed, changingTooQuickly, originUnavailable
}

/// One origin connection, one unfiltered subscription, one bounded refresh job.
/// Does not own/stop the core or connection. A reconnect creates a new store;
/// this store's final cached view remains read-only. No launch/kill or authority.
public actor CoreWorkspaceStore {
    public enum Phase: Sendable { case idle, starting, active, failed, closed }
    public struct View: Sendable {
        public let originCoreID: String
        public let epoch: UUID
        public let phase: Phase
        public let snapshot: CoreWorkspaceCAS.Snapshot?
        public let canWrite: Bool
        public let failure: CoreWorkspaceStoreFailure?
        public let lastWriteResult: CoreWorkspaceCAS.WriteResult?
    }
    public nonisolated let originCoreID: String
    public nonisolated let epoch: UUID
    private let connection: CoreRPCConnection
    private let gatewayCoreID: String?
    private let timeout: Duration
    private var cas: CoreWorkspaceCAS
    private var phase: Phase = .idle
    private var failure: CoreWorkspaceStoreFailure?
    private var stream: CoreStream?
    private var reader: Task<Void, Never>?
    private var opening: Task<CoreStream, Error>?
    private var closing: Task<Void, Error>?
    private var refreshJob: (id: UUID, task: Task<Void, Never>)?
    private var writing = false
    private var watchers: [UUID: AsyncStream<View>.Continuation] = [:]

    /// gatewayCoreID is an explicit configured first-level origin ID, never an
    /// alias. It is not native authority or an atomic lease on gateway config.
    public init(connection: CoreRPCConnection, timeout: Duration = .seconds(5), gatewayCoreID: String? = nil) async throws {
        guard timeout > .zero, timeout <= .seconds(30) else { throw CoreConnectionFailure.invalidTimeout }
        guard await connection.state == .ready, let hello = await connection.hello else { throw CoreConnectionFailure.notReady }
        guard Set(["events.subscribe", "doc.get", "doc.set"]).isSubset(of: Set(hello.methods)) else { throw CoreConnectionFailure.methodUnavailable }
        if let gatewayCoreID { try await Self.validateGateway(connection, target: gatewayCoreID) }
        self.connection = connection; self.timeout = timeout; self.gatewayCoreID = gatewayCoreID
        originCoreID = gatewayCoreID ?? hello.core.id; epoch = connection.epoch
        cas = try CoreWorkspaceCAS(originCoreID: gatewayCoreID ?? hello.core.id, epoch: connection.epoch)
    }
    private nonisolated static func validateGateway(_ connection: CoreRPCConnection, target: String) async throws {
        do {
            let snapshot = try await HcGatewaySnapshot.read(connection: connection)
            guard snapshot.machines.contains(where: { $0.id == target && $0.state == "connected" }) else { throw CoreWorkspaceStoreFailure.originUnavailable }
        } catch { throw CoreWorkspaceStoreFailure.originUnavailable }
    }
    private func readParameters() throws -> Data {
        struct Params: Encodable { let name: String; let on: String? }
        return try JSONEncoder().encode(Params(name: CoreWorkspaceDocument.documentName, on: gatewayCoreID))
    }
    deinit {
        opening?.cancel(); reader?.cancel(); refreshJob?.task.cancel()
        for watcher in watchers.values { watcher.finish() }
        if let stream { Task { try? await stream.close() } }
    }
    public func view() -> View {
        View(originCoreID: originCoreID, epoch: epoch, phase: phase, snapshot: cas.snapshot,
             canWrite: phase == .active && refreshJob == nil && !writing && cas.canWrite, failure: failure, lastWriteResult: cas.lastWriteResult)
    }
    /// Full views, not deltas. Slow UIs retain at most one pending view each.
    public func updates() throws -> AsyncStream<View> {
        guard watchers.count < 8 else { throw CoreWorkspaceStoreFailure.subscriberLimit }
        let id = UUID(), pair = AsyncStream<View>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(view())
        if phase == .closed || phase == .failed { pair.continuation.finish(); return pair.stream }
        watchers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeWatcher(id) } }
        return pair.stream
    }
    private func removeWatcher(_ id: UUID) { watchers[id] = nil }
    private func publish() { let value = view(); for watcher in watchers.values { watcher.yield(value) } }

    @discardableResult public func start() async throws -> View {
        guard phase == .idle else { throw CoreWorkspaceStoreFailure.alreadyStarted }
        phase = .starting; publish()
        do {
            let connection = connection, timeout = timeout, gatewayCoreID = gatewayCoreID
            let job = Task { try await connection.openStream("events.subscribe", timeout: timeout) }
            opening = job
            let events = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            opening = nil
            guard phase == .starting else { try await events.close(); throw CoreWorkspaceStoreFailure.closed }
            stream = events
            try Task.checkCancellation()
            let initial: CoreWorkspaceEvents.Initial = try events.initialReply.result()
            try cas.didSubscribe(coreID: originCoreID, epoch: epoch)
            phase = .active
            reader = Task.detached { [weak self, events] in
                do {
                    var lines = try CoreEventLines(maximumLineBytes: 1 << 20)
                    var reducer = CoreWorkspaceEvents(sequence: initial.seq, remoteDocuments: gatewayCoreID != nil)
                    // hc advertises a heartbeat every 15 seconds. A stalled
                    // event lane must not leave a cached layout writable forever.
                    while let packet = try await events.next(timeout: .seconds(45)) {
                        guard packet.frame.kind == .data else { break }
                        var effect = CoreWorkspaceEvents.Effect()
                        try lines.receive(packet.frame.payload) { effect.merge(try reducer.consume($0)) }
                        guard let self else { try await events.close(); return }
                        await self.observed(effect)
                        try await events.acknowledge(packet) // After parsing and invalidation, not on dequeue.
                    }
                    try lines.finish()
                } catch { /* Only a bounded public failure kind is published. */ }
                await self?.eventsEnded()
            }
            return try await refresh()
        } catch {
            opening = nil
            if phase != .closed { await eventsEnded() }
            throw error
        }
    }
    private func observed(_ effect: CoreWorkspaceEvents.Effect) {
        guard phase == .active, effect.refresh else { return }
        try? cas.invalidate(epoch: epoch, minimumVersion: effect.minimumVersion)
        publish(); scheduleRefresh()
    }
    private func eventsEnded() async {
        guard phase == .starting || phase == .active else { return }
        phase = .failed; failure = .eventStreamFailed; cas.reconnect(epoch: epoch)
        refreshJob?.task.cancel(); publish()
        for watcher in watchers.values { watcher.finish() }; watchers.removeAll()
        if let stream { try? await stream.close() }
    }
    private func scheduleRefresh() {
        guard phase == .active, !writing, refreshJob == nil else { return }
        let id = UUID()
        refreshJob = (id, Task { [weak self] in await self?.refreshBatch(id) })
    }
    private func refreshBatch(_ id: UUID) async {
        failure = nil
        for _ in 0..<3 {
            guard phase == .active, !Task.isCancelled else { break }
            let token: CoreWorkspaceCAS.Read
            do { token = try cas.beginRead() }
            catch { break }
            publish()
            do {
                if let gatewayCoreID { try await Self.validateGateway(connection, target: gatewayCoreID) }
                let reply = try await connection.call("doc.get", parameters: readParameters(), timeout: timeout)
                guard phase == .active else { break }
                let result: CoreWorkspaceReadResult = try reply.result()
                try cas.accept(token, version: result.version, document: result.document)
                failure = nil; publish(); break
            } catch CoreWorkspaceSyncFailure.staleOperation {
                // An event invalidated this in-flight read; retry READ only.
                continue
            } catch {
                guard phase == .active else { break }
                try? cas.readFailed(token)
                if let error = error as? CoreWorkspaceStoreFailure, error == .originUnavailable { failure = .originUnavailable }
                else { failure = error is CoreWorkspaceFailure || error is DecodingError ? .invalidDocument : .readFailed }
                break
            }
        }
        guard refreshJob?.id == id else { return }
        refreshJob = nil
        if phase == .active, cas.refreshRequired, failure == nil { failure = .changingTooQuickly }
        publish()
    }
    /// Coalesced, bounded read retry. Canceling one waiter does not cancel other
    /// UI readers' shared refresh; the owned RPC still has its finite timeout.
    @discardableResult public func refresh() async throws -> View {
        guard phase == .active else { throw CoreWorkspaceStoreFailure.closed }
        if refreshJob == nil, !writing { try cas.invalidate(epoch: epoch) }
        scheduleRefresh(); publish()
        await refreshJob?.task.value
        try Task.checkCancellation()
        guard phase == .active else { throw CoreWorkspaceStoreFailure.closed }
        return view()
    }
    public func edit(_ edit: CoreWorkspaceEdit, expectedVersion: UInt64) async throws -> CoreWorkspaceCAS.WriteResult {
        guard phase == .active, cas.canWrite else { throw CoreWorkspaceSyncFailure.refreshRequired }
        guard cas.snapshot?.version == expectedVersion else { throw CoreWorkspaceStoreFailure.staleRevision }
        let baseline = try cas.snapshot?.document ?? CoreWorkspaceDocument()
        return try await commit(edit.applying(to: baseline), expectedVersion: expectedVersion)
    }

    /// Caller must supply the version from which it prepared the edit. A newer
    /// automatically refreshed baseline MUST NOT authorize an old replacement.
    public func commit(_ document: CoreWorkspaceDocument, expectedVersion: UInt64) async throws -> CoreWorkspaceCAS.WriteResult {
        guard phase == .active else { throw CoreWorkspaceStoreFailure.closed }
        guard cas.snapshot?.version == expectedVersion else { throw CoreWorkspaceStoreFailure.staleRevision }
        guard refreshJob == nil, !writing else { throw CoreWorkspaceSyncFailure.refreshRequired }
        if let gatewayCoreID {
            do { try await Self.validateGateway(connection, target: gatewayCoreID) }
            catch { try? cas.invalidate(epoch: epoch); failure = .originUnavailable; publish(); throw error }
            // Validation suspends. It cannot authorize another caller's newer
            // baseline or a concurrent write/refresh that began while awaiting.
            guard phase == .active else { throw CoreWorkspaceStoreFailure.closed }
            guard cas.snapshot?.version == expectedVersion else { throw CoreWorkspaceStoreFailure.staleRevision }
            guard refreshJob == nil, !writing, cas.canWrite else { throw CoreWorkspaceSyncFailure.refreshRequired }
        }
        let token = try cas.beginWrite(document)
        writing = true; publish()
        let result: CoreWorkspaceCAS.WriteResult
        do {
            struct Written: Decodable, Sendable { let version: UInt64 }
            let ack: Written = try await connection.call("doc.set", parameters: token.parameters(on: gatewayCoreID), timeout: timeout).result()
            result = .acknowledged(version: ack.version)
        } catch let error as CoreRPCRemoteFailure where error.kind == "conflict" {
            result = .conflict
        } catch { result = .uncertain }
        writing = false
        guard phase == .active else { throw CoreWorkspaceStoreFailure.closed }
        do { try cas.finish(token, result: result) }
        catch { scheduleRefresh(); publish(); throw error }
        scheduleRefresh(); publish()
        return result // Never re-send a mutation, even after timeout/conflict.
    }
    /// Closes only this subscription; other users of the connection stay alive.
    public func close() async throws {
        if let closing { try await closing.value; return }
        phase = .closed; cas.reconnect(epoch: epoch)
        let reader = reader, refresh = refreshJob?.task, opening = opening, stream = stream
        opening?.cancel(); reader?.cancel(); refresh?.cancel(); publish()
        for watcher in watchers.values { watcher.finish() }; watchers.removeAll()
        let job = Task {
            var failure: (any Error)?
            // Canceled late opens remain tracked by CoreRPCConnection's orphan
            // cleanup. If an open already succeeded, dispose its actual stream.
            if let opened = try? await opening?.value { do { try await opened.close() } catch { failure = error } }
            if let stream { do { try await stream.close() } catch { failure = error } }
            await reader?.value; await refresh?.value
            if let failure { throw failure }
        }
        closing = job
        try await job.value
        self.reader = nil; self.opening = nil; refreshJob = nil; self.stream = nil
    }
}
