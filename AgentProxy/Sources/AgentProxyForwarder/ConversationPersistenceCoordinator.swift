import Foundation
import NIOCore
import AgentProxyCore

/// Recorder-loop admission with one serial filesystem worker. The worker owns
/// the journal lease; no filesystem operation runs on the capture loop.
final class ConversationPersistenceCoordinator: @unchecked Sendable {
    enum Health { case volatile, healthy, degraded }
    private struct Pending {
        let record: ConversationStore.PersistentSnapshot.Record
        let reservation: UUID
        let updatedAt: Date
    }
    private let loop: EventLoop
    private let worker = DispatchQueue(label: "conversation-persistence")
    private let root: String
    private let capture: ConversationCapture
    private var journal: ConversationPersistenceJournal? // worker queue only
    private var initializationFailed = false // worker queue only; no unsafe repeated open
    private var pending: [String: Pending] = [:] // recorder loop only
    // JSON encoding, checked reads and validation can transiently exceed the
    // normalized 4 MiB record (escaping alone can expand text sixfold).
    // This is admission accounting, not a process RSS guarantee.
    private static let workspaceBytes = 64 << 20
    private static let recordBytes = 8 << 20
    private var running = false
    private var fenceWaiters: [() -> Void] = []
    private var finished: DispatchSemaphore?
    private(set) var health: Health = .volatile

    init(root: String, loop: EventLoop, capture: ConversationCapture) {
        self.root = root; self.loop = loop; self.capture = capture
    }

    /// Pressure skips a snapshot instead of delaying forwarding. Replacing a
    /// pending record reuses its reservation, rather than briefly doubling it.
    func schedule(_ record: ConversationStore.PersistentSnapshot.Record) -> Bool {
        loop.assertInEventLoop()
        if let old = pending[record.id] {
            pending[record.id] = Pending(record: record, reservation: old.reservation, updatedAt: Date())
            return true
        }
        guard pending.count < 8, Self.recordBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.recordBytes,
              let reservation = capture.reserve(bytes: Self.recordBytes) else { health = .degraded; return false }
        pending[record.id] = Pending(record: record, reservation: reservation, updatedAt: Date())
        drain()
        return true
    }

    /// One serial, admitted referenced-body scan. Busy or memory pressure is
    /// reported to the caller, which must not create a duplicate disk record.
    func loadFirst(_ key: ConversationStore.PersistentSnapshot.Key,
                   completion: @escaping (Result<ConversationPersistenceJournalLoadedRecord?, Error>) -> Void) -> Bool {
        loop.assertInEventLoop()
        guard !running, Self.workspaceBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.workspaceBytes,
              let workspace = capture.reserve(bytes: Self.workspaceBytes) else { return false }
        running = true
        worker.async { [self] in
            let result: Result<ConversationPersistenceJournalLoadedRecord?, Error>
            do { result = .success(try openJournal().firstRecord(matching: key)) }
            catch { result = .failure(error) }
            loop.execute { [self] in
                capture.release(workspace)
                running = false
                completion(result)
                let waiters = fenceWaiters
                fenceWaiters.removeAll()
                for waiter in waiters { waiter() }
                drain()
            }
        }
        return true
    }

    private func openJournal() throws -> ConversationPersistenceJournal {
        if let journal { return journal }
        guard !initializationFailed else { throw ConversationPersistenceJournalError.unavailable }
        do {
            let files = try ConversationPersistenceFiles(verifiedStateRootPath: root)
            let opened = ConversationPersistenceJournal(files: files)
            try opened.activate()
            journal = opened
            return opened
        } catch {
            initializationFailed = true
            throw error
        }
    }

    /// Drop queued old-authority snapshots and wait for the one filesystem
    /// operation already executing. The caller must pause new admissions until
    /// this completion and invalidate its capture/read/restore tickets first.
    func fence(_ completion: @escaping () -> Void) {
        loop.assertInEventLoop()
        for value in pending.values { capture.release(value.reservation) }
        pending.removeAll()
        if running { fenceWaiters.append(completion) }
        else { loop.execute(completion) }
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
        guard !running else { return }
        guard let key = pending.keys.sorted().first, let next = pending.removeValue(forKey: key) else {
            finished?.signal(); finished = nil
            return
        }
        guard Self.workspaceBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.workspaceBytes,
              let workspace = capture.reserve(bytes: Self.workspaceBytes) else {
            capture.release(next.reservation)
            health = .degraded
            drain()
            return
        }
        running = true
        worker.async { [self] in
            let success: Bool
            do {
                try openJournal().upsert(next.record, updatedAt: next.updatedAt)
                success = true
            } catch { success = false }
            loop.execute { [self] in
                capture.release(workspace)
                capture.release(next.reservation)
                if !success { health = .degraded }
                else if case .volatile = health { health = .healthy }
                running = false
                let waiters = fenceWaiters
                fenceWaiters.removeAll()
                for completion in waiters { completion() }
                drain()
            }
        }
    }
}
