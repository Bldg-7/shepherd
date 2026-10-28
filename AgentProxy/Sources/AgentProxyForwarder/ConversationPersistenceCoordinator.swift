import Foundation
import NIOCore
import AgentProxyCore

/// Recorder-loop admission with one serial IPC worker. Only the spawned
/// storage-owner role opens the journal; capture never performs journal I/O.
final class ConversationPersistenceCoordinator: @unchecked Sendable {
    enum Health { case volatile, healthy, degraded }
    private struct Pending {
        let record: ConversationStore.PersistentSnapshot.Record
        let reservation: UUID
        let updatedAt: Date
        let generation: UInt64
        let completion: (Bool) -> Void
    }
    private let loop: EventLoop
    private let worker = DispatchQueue(label: "conversation-persistence")
    private let root: String
    private let capture: ConversationCapture
    private let producerLease: ConversationProducerLease
    private var owner: ConversationStorageOwnerClient? // worker queue only
    private var initializationFailed = false // worker queue only; unsafe state stays closed
    private var initializationRetryAfter: TimeInterval = 0 // worker queue only
    private var pending: [String: Pending] = [:] // recorder loop only
    // JSON encoding, checked reads and validation can transiently exceed the
    // normalized 4 MiB record (escaping alone can expand text sixfold).
    // This is admission accounting, not a process RSS guarantee.
    private static let workspaceBytes = 64 << 20
    private static let recordBytes = 8 << 20
    private var running = false
    private var authorityPaused = false
    private var storageGeneration: UInt64 = 1 // recorder loop only
    private var fenceWaiters: [() -> Void] = []
    private var finished: DispatchSemaphore?
    private(set) var health: Health = .volatile

    init(root: String, loop: EventLoop, capture: ConversationCapture, producerLease: ConversationProducerLease) {
        self.root = root; self.loop = loop; self.capture = capture; self.producerLease = producerLease
    }

    /// Pressure skips a snapshot instead of delaying forwarding. Replacing a
    /// pending record reuses its reservation, rather than briefly doubling it.
    func schedule(_ record: ConversationStore.PersistentSnapshot.Record, completion: @escaping (Bool) -> Void) -> Bool {
        loop.assertInEventLoop()
        guard !authorityPaused else { return false }
        if let old = pending[record.id] {
            pending[record.id] = Pending(record: record, reservation: old.reservation, updatedAt: Date(), generation: storageGeneration, completion: completion)
            loop.execute { old.completion(false) }
            return true
        }
        guard pending.count < 8, Self.recordBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.recordBytes,
              let reservation = capture.reserve(bytes: Self.recordBytes) else { health = .degraded; return false }
        pending[record.id] = Pending(record: record, reservation: reservation, updatedAt: Date(), generation: storageGeneration, completion: completion)
        drain()
        return true
    }

    /// One serial, admitted referenced-body scan. Busy or memory pressure is
    /// reported to the caller, which must not create a duplicate disk record.
    func loadFirst(_ key: ConversationStore.PersistentSnapshot.Key,
                   completion: @escaping (Result<ConversationStore.PersistentSnapshot.Record?, Error>) -> Void) -> Bool {
        loop.assertInEventLoop()
        guard !authorityPaused, !running, Self.workspaceBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.workspaceBytes,
              let workspace = capture.reserve(bytes: Self.workspaceBytes) else { return false }
        running = true
        let generation = storageGeneration
        worker.async { [self] in
            let result: Result<ConversationStore.PersistentSnapshot.Record?, Error>
            do {
                let reply = try openOwner(generation: generation).request(operation: .load, generation: generation, key: key)
                guard reply.outcome == .success else { throw ConversationStorageOwner.Failure.unavailable }
                result = .success(reply.record)
            } catch { retireOwner(); result = .failure(error) }
            loop.execute { [self] in
                capture.release(workspace)
                running = false
                // Degradation is sticky for this recorder lifetime: a later
                // unrelated success does not prove a failed record is healthy.
                if case .failure = result { health = .degraded }
                completion(result)
                let waiters = fenceWaiters
                fenceWaiters.removeAll()
                for waiter in waiters { waiter() }
                drain()
            }
        }
        return true
    }

    private func openOwner(generation: UInt64) throws -> ConversationStorageOwnerClient {
        try producerLease.verify()
        if let owner { return owner }
        let now = ProcessInfo.processInfo.systemUptime
        guard !initializationFailed, now.isFinite, now >= initializationRetryAfter else { throw ConversationStorageOwner.Failure.unavailable }
        do {
            let opened = try ConversationStorageOwnerClient(stateDirectory: root, producer: producerLease, generation: generation)
            owner = opened
            return opened
        } catch {
            if let failure = error as? ConversationStorageOwner.Failure, case .unsafe = failure { initializationFailed = true }
            else { initializationRetryAfter = now + 5 }
            throw error
        }
    }

    private func retireOwner() {
        owner = nil
        initializationRetryAfter = ProcessInfo.processInfo.systemUptime + 5
    }

    /// Status is obtained from the owner over the same serial channel; this
    /// cached health never claims that a queued write has committed.
    func refreshStatus() {
        loop.assertInEventLoop()
        let workspace = 1 << 20
        guard !authorityPaused, !running, pending.isEmpty, workspace <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - workspace,
              let reservation = capture.reserve(bytes: workspace) else { return }
        running = true
        let generation = storageGeneration
        worker.async { [self] in
            let healthy: Bool
            do {
                let reply = try openOwner(generation: generation).request(operation: .status, generation: generation)
                healthy = reply.outcome == .success && reply.health == "healthy" && reply.record == nil
            } catch { retireOwner(); healthy = false }
            loop.execute { [self] in
                capture.release(reservation); running = false
                if !healthy { health = .degraded }
                else if case .volatile = health { health = .healthy }
                let waiters = fenceWaiters; fenceWaiters.removeAll()
                for waiter in waiters { waiter() }
                drain()
            }
        }
    }

    /// Pause new filesystem admissions while authority replacement is waiting
    /// for workspace. Queued old work is discarded and active I/O is fenced.
    func pauseForAuthority(_ completion: @escaping () -> Void) {
        loop.assertInEventLoop()
        authorityPaused = true
        fence(completion)
    }

    func resumeAfterAuthority() {
        loop.assertInEventLoop()
        authorityPaused = false
        drain()
    }

    /// Drop queued old-authority snapshots and wait for the one filesystem
    /// operation already executing. The caller must pause new admissions until
    /// this completion and invalidate its capture/read/restore tickets first.
    func fence(_ completion: @escaping () -> Void) {
        loop.assertInEventLoop()
        for value in pending.values {
            capture.release(value.reservation)
            loop.execute { value.completion(false) }
        }
        pending.removeAll()
        if running { fenceWaiters.append(completion) }
        else { loop.execute(completion) }
    }

    enum ClearOutcome: Equatable { case cleared, unavailable, partial }

    /// The owner has already invalidated capture and readers. Admission is
    /// paused before queued writes are dropped and active disk work finishes.
    func clearHistory(_ completion: @escaping (ClearOutcome) -> Void) {
        loop.assertInEventLoop()
        pauseForAuthority { [self] in
            guard Self.workspaceBytes <= capture.limits.totalBytes,
                  capture.accountedBytes <= capture.limits.totalBytes - Self.workspaceBytes,
                  let workspace = capture.reserve(bytes: Self.workspaceBytes) else {
                health = .degraded; completion(.unavailable); return
            }
            guard storageGeneration < UInt64.max else { capture.release(workspace); completion(.unavailable); return }
            storageGeneration += 1
            let generation = storageGeneration
            running = true
            worker.async { [self] in
                let outcome: ClearOutcome
                do {
                    try producerLease.verify()
                    let reply = try openOwner(generation: generation - 1).request(operation: .clear, generation: generation)
                    outcome = reply.outcome == .success ? .cleared : .partial
                } catch { retireOwner(); outcome = .partial }
                loop.execute { [self] in
                    capture.release(workspace); running = false
                    if case .cleared = outcome {} else { health = .degraded }
                    completion(outcome)
                    let waiters = fenceWaiters; fenceWaiters.removeAll()
                    for waiter in waiters { waiter() }
                    drain()
                }
            }
        }
    }

    /// The caller waits outside the event loop and imposes its own deadline.
    func finishWhenIdle() -> DispatchSemaphore {
        loop.assertInEventLoop()
        let result = DispatchSemaphore(value: 0)
        finished = result
        drain()
        return result
    }

    private func drain() {
        loop.assertInEventLoop()
        guard !running, !authorityPaused else { return }
        guard let key = pending.keys.sorted().first, let next = pending.removeValue(forKey: key) else {
            finished?.signal(); finished = nil
            return
        }
        guard Self.workspaceBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.workspaceBytes,
              let workspace = capture.reserve(bytes: Self.workspaceBytes) else {
            capture.release(next.reservation)
            health = .degraded
            loop.execute { next.completion(false) }
            drain()
            return
        }
        running = true
        worker.async { [self] in
            let success: Bool
            do {
                let reply = try openOwner(generation: next.generation).request(operation: .save, generation: next.generation, record: next.record, updatedAt: next.updatedAt)
                success = reply.outcome == .success
            } catch { retireOwner(); success = false }
            loop.execute { [self] in
                capture.release(workspace)
                capture.release(next.reservation)
                if !success { health = .degraded }
                else if case .volatile = health { health = .healthy }
                loop.execute { next.completion(success) }
                running = false
                let waiters = fenceWaiters
                fenceWaiters.removeAll()
                for completion in waiters { completion() }
                drain()
            }
        }
    }
}
