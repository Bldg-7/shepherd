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
    private var ownerCloseFailed = false // worker queue only; sticky shutdown outcome
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
    final class Finish: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var clean = false
        func complete(_ value: Bool) { clean = value; semaphore.signal() }
        func wait(timeout: DispatchTime) -> Bool { semaphore.wait(timeout: timeout) == .success && clean }
    }
    private var finished: Finish?
    private(set) var health: Health = .volatile
    private(set) var statusWorkspaceDeferrals = 0

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
            let ownerPending = owner?.isClosed == true
            loop.execute { [self] in
                capture.release(workspace)
                // Degradation is sticky for this recorder lifetime: a later
                // unrelated success does not prove a failed record is healthy.
                if case .failure = result { health = .degraded }
                completion(result)
                settleWorker(ownerPending: ownerPending)
            }
        }
        return true
    }

    private func openOwner(generation: UInt64) throws -> ConversationStorageOwnerClient {
        try producerLease.verify()
        if let current = owner {
            if !current.isClosed { return current }
            switch current.closeOwner() {
            case .pending, .unknown: throw ConversationStorageOwner.Failure.unavailable
            case .clean, .failed: owner = nil
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard !initializationFailed, now.isFinite, now >= initializationRetryAfter else { throw ConversationStorageOwner.Failure.unavailable }
        do {
            let opened = try ConversationStorageOwnerClient(stateDirectory: root, producer: producerLease)
            // Install before the first request so even a failed begin remains
            // fenced until the child has actually been reaped.
            owner = opened
            let reply = try opened.request(operation: .begin, generation: generation)
            guard reply.outcome == .success else { throw ConversationStorageOwner.Failure.unavailable }
            return opened
        } catch {
            retireOwner()
            if let failure = error as? ConversationStorageOwner.Failure, case .unsafe = failure { initializationFailed = true }
            else { initializationRetryAfter = now + 5 }
            throw error
        }
    }

    private func retireOwner() {
        if let current = owner {
            switch current.closeOwner() {
            case .clean: owner = nil
            case .failed: ownerCloseFailed = true; owner = nil
            case .pending, .unknown: ownerCloseFailed = true
            }
        }
        initializationRetryAfter = ProcessInfo.processInfo.systemUptime + 5
    }

    /// Status may start the owner and its activation/retention scan, or run a
    /// metadata check that retires expired records. Admit the full journal
    /// workspace; this is accounting, not an allocator or process RSS bound.
    func refreshStatus() {
        loop.assertInEventLoop()
        guard !authorityPaused, !running, pending.isEmpty else { return }
        guard Self.workspaceBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.workspaceBytes,
              let reservation = capture.reserve(bytes: Self.workspaceBytes) else {
            if statusWorkspaceDeferrals < Int.max { statusWorkspaceDeferrals += 1 }
            return
        }
        running = true
        let generation = storageGeneration
        worker.async { [self] in
            let healthy: Bool
            do {
                let reply = try openOwner(generation: generation).request(operation: .status, generation: generation)
                healthy = reply.outcome == .success && reply.health == "healthy" && reply.record == nil
            } catch { retireOwner(); healthy = false }
            let ownerPending = owner?.isClosed == true
            loop.execute { [self] in
                capture.release(reservation)
                if !healthy { health = .degraded }
                else if case .volatile = health { health = .healthy }
                settleWorker(ownerPending: ownerPending)
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
                let ownerPending = owner?.isClosed == true
                loop.execute { [self] in
                    capture.release(workspace)
                    if case .cleared = outcome {} else { health = .degraded }
                    completion(outcome)
                    settleWorker(ownerPending: ownerPending)
                }
            }
        }
    }

    /// The caller waits outside the event loop and imposes its own deadline.
    func finishWhenIdle() -> Finish {
        loop.assertInEventLoop()
        let result = Finish()
        finished = result
        drain()
        return result
    }

    private func drain() {
        loop.assertInEventLoop()
        guard !running, !authorityPaused else { return }
        guard let key = pending.keys.sorted().first, let next = pending.removeValue(forKey: key) else {
            guard let completion = finished else { return }
            finished = nil; running = true
            worker.async { [self] in
                if let current = owner {
                    switch current.closeOwner() {
                    case .clean: owner = nil
                    case .failed: ownerCloseFailed = true; owner = nil
                    case .pending, .unknown: ownerCloseFailed = true
                    }
                }
                let clean = !ownerCloseFailed
                loop.execute { [self] in
                    running = false
                    if !clean { health = .degraded }
                    completion.complete(clean)
                }
            }
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
            let ownerPending = owner?.isClosed == true
            loop.execute { [self] in
                capture.release(workspace)
                capture.release(next.reservation)
                if !success { health = .degraded }
                else if case .volatile = health { health = .healthy }
                loop.execute { next.completion(success) }
                settleWorker(ownerPending: ownerPending)
            }
        }
    }

    /// An unreaped owner may still finish I/O. Keep the fence closed until
    /// the worker proves exit; an unknown child identity stays fail-closed.
    private func settleWorker(ownerPending: Bool) {
        loop.assertInEventLoop()
        if ownerPending {
            loop.scheduleTask(in: .milliseconds(50)) { [self] in
                worker.async { [self] in
                    guard let current = owner else {
                        loop.execute { [self] in settleWorker(ownerPending: false) }
                        return
                    }
                    switch current.closeOwner() {
                    case .pending: loop.execute { [self] in settleWorker(ownerPending: true) }
                    case .unknown: break // Keep the fence closed without guessing the child's identity.
                    case .clean, .failed:
                        owner = nil
                        loop.execute { [self] in settleWorker(ownerPending: false) }
                    }
                }
            }
            return
        }
        running = false
        let waiters = fenceWaiters
        fenceWaiters.removeAll()
        for waiter in waiters { waiter() }
        drain()
    }
}
