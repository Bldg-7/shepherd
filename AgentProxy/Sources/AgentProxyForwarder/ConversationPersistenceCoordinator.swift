import Foundation
import NIOCore
import AgentProxyCore

/// Recorder-loop admission with one serial database worker. Capture never
/// performs database I/O; the worker is the only connection in this process.
final class ConversationPersistenceCoordinator: @unchecked Sendable {
    enum Health { case volatile, healthy, degraded }
    private struct Pending {
        var record: ConversationStore.PersistentSnapshot.Record
        let reservation: UUID
        var updatedAt: Date
        var generation: UInt64
        let firstChange: NIODeadline
        var lastChange: NIODeadline
        /// A finished or interrupted turn is written without waiting.
        var urgent: Bool
        var completion: (Bool) -> Void
    }
    private let loop: EventLoop
    private let worker = DispatchQueue(label: "conversation-persistence")
    private let root: String
    private let capture: ConversationCapture
    private let producerLease: ConversationProducerLease
    private var database: ConversationDatabase? // worker queue only
    private var databaseUnsafe = false // worker queue only; sticky until a clear
    private var openRetryAfter: TimeInterval = 0 // worker queue only
    private var pending: [String: Pending] = [:] // recorder loop only
    /// The pending record shares its strings with the live store; this is
    /// admission accounting for the copy, not a process RSS guarantee.
    private static let recordBytes = 8 << 20
    // Leave room for one reader's connection and query during an online save.
    private static let readerHeadroomBytes = 12 << 20
    /// Streaming changes are coalesced: a record is written once it has been
    /// quiet this long, and never later than `maximumDelay` after it changed.
    static let quietInterval = TimeAmount.milliseconds(500)
    static let maximumDelay = TimeAmount.seconds(2)
    private var wakeAt: NIODeadline?
    private var running = false
    private var authorityPaused = false
    private var storageGeneration: UInt64 = 1 // recorder loop only
    private var fenceWaiters: [() -> Void] = []
    final class Finish: @unchecked Sendable {
        enum Result { case clean, failed, timedOut }
        private let semaphore = DispatchSemaphore(value: 0)
        private var clean = false
        func complete(_ value: Bool) { clean = value; semaphore.signal() }
        func wait(timeout: DispatchTime) -> Result {
            guard semaphore.wait(timeout: timeout) == .success else { return .timedOut }
            return clean ? .clean : .failed
        }
    }
    private var finished: Finish?
    private var shutdownFailed = false
    private(set) var health: Health = .volatile
    private(set) var statusWorkspaceDeferrals = 0
    #if SHPHRD_PERSISTENCE_TESTING
    private(set) var testSaves: [ConversationDatabase.SaveReport] = []
    var testOperationRunning: Bool { running }
    var testPendingRecords: Int { pending.count }
    #endif

    init(root: String, loop: EventLoop, capture: ConversationCapture, producerLease: ConversationProducerLease) {
        self.root = root; self.loop = loop; self.capture = capture; self.producerLease = producerLease
    }

    /// Pressure skips a snapshot instead of delaying forwarding. Replacing a
    /// pending record reuses its reservation, rather than briefly doubling it.
    func schedule(_ record: ConversationStore.PersistentSnapshot.Record, completion: @escaping (Bool) -> Void) -> Bool {
        loop.assertInEventLoop()
        guard !authorityPaused else { return false }
        let now = NIODeadline.now()
        let urgent = record.status != "streaming"
        if var value = pending[record.id] {
            let old = value.completion
            value.record = record; value.updatedAt = Date(); value.generation = storageGeneration
            value.lastChange = now; value.urgent = value.urgent || urgent; value.completion = completion
            pending[record.id] = value
            loop.execute { old(false) }
            drain()
            return true
        }
        guard pending.count < 8, Self.recordBytes <= capture.limits.totalBytes,
              capture.accountedBytes <= capture.limits.totalBytes - Self.recordBytes,
              let reservation = capture.reserve(bytes: Self.recordBytes) else { health = .degraded; return false }
        pending[record.id] = Pending(record: record, reservation: reservation, updatedAt: Date(), generation: storageGeneration,
                                     firstChange: now, lastChange: now, urgent: urgent, completion: completion)
        drain()
        return true
    }

    /// Workspace for one save: Core admission rebuilds the record in a scratch
    /// store (about twice its normalized text), one item is encoded at a time
    /// (at most about twice its text), plus the connection's page cache.
    static func saveWorkspaceBytes(_ record: ConversationStore.PersistentSnapshot.Record) -> Int {
        var total = 0, largest = 0
        for item in record.items {
            var bytes = 256 + item.id.utf8.count
            for block in item.message.blocks {
                bytes += 64 + block.text.utf8.count + (block.callID?.utf8.count ?? 0) + (block.toolName?.utf8.count ?? 0)
            }
            total += bytes; largest = max(largest, bytes)
        }
        return 2 * total + min(2 * largest, ConversationDatabase.maximumItemBodyBytes) + ConversationDatabase.connectionWorkspaceBytes
    }

    /// Workspace for one load: the decoded record and its scratch admission
    /// copy, one stored body, and the page cache.
    private var loadWorkspaceBytes: Int {
        4 * capture.limits.store.conversationBytes + ConversationDatabase.maximumItemBodyBytes + ConversationDatabase.connectionWorkspaceBytes
    }

    private func reserveWorkspace(_ bytes: Int, headroom: Int = 0) -> UUID? {
        guard bytes <= capture.limits.totalBytes - headroom,
              capture.accountedBytes <= capture.limits.totalBytes - bytes - headroom else { return nil }
        return capture.reserve(bytes: bytes)
    }

    /// One serial, admitted lookup. Busy or memory pressure is reported to the
    /// caller, which must not create a duplicate disk record.
    func loadFirst(_ key: ConversationStore.PersistentSnapshot.Key,
                   completion: @escaping (Result<ConversationStore.PersistentSnapshot.Record?, Error>) -> Void) -> Bool {
        loop.assertInEventLoop()
        guard !authorityPaused, !running, let workspace = reserveWorkspace(loadWorkspaceBytes) else { return false }
        running = true
        worker.async { [self] in
            let result: Result<ConversationStore.PersistentSnapshot.Record?, Error>
            do { result = .success(try perform { try $0.load(key) }) }
            catch { result = .failure(error) }
            loop.execute { [self] in
                // Degradation is sticky for this recorder lifetime: a later
                // unrelated success does not prove a failed record is healthy.
                if case .failure = result { health = .degraded }
                settle(releasing: [workspace]) { completion(result) }
            }
        }
        return true
    }

    /// Runs one database operation on the worker, opening the database first
    /// if needed. A storage failure closes the connection and backs off five
    /// seconds; a database found unsafe when opening stays closed until
    /// history is cleared. A rejected record leaves the connection open.
    private func perform<T>(_ operation: (ConversationDatabase) throws -> T) throws -> T {
        try producerLease.verify()
        let database = try openDatabase()
        do {
            let value = try operation(database)
            try producerLease.verify()
            return value
        } catch {
            switch error as? ConversationDatabase.Failure {
            case .unsafe?, .unavailable?: openRetryAfter = ProcessInfo.processInfo.systemUptime + 5; self.database = nil
            case .capacity?, .invalidRecord?: break
            case nil: self.database = nil
            }
            throw error
        }
    }

    private func openDatabase() throws -> ConversationDatabase {
        if let database { return database }
        let now = ProcessInfo.processInfo.systemUptime
        guard !databaseUnsafe, now >= openRetryAfter else { throw ConversationDatabase.Failure.unavailable }
        do {
            let opened = try ConversationDatabase(stateDirectory: root)
            database = opened
            return opened
        } catch {
            if case ConversationDatabase.Failure.unsafe = error { databaseUnsafe = true }
            else { openRetryAfter = now + 5 }
            throw error
        }
    }

    /// Status opens the database if needed and retires expired records.
    func refreshStatus() {
        loop.assertInEventLoop()
        guard !authorityPaused, !running, pending.isEmpty else { return }
        guard let workspace = reserveWorkspace(ConversationDatabase.connectionWorkspaceBytes) else {
            if statusWorkspaceDeferrals < Int.max { statusWorkspaceDeferrals += 1 }
            return
        }
        running = true
        worker.async { [self] in
            let healthy = (try? perform { try $0.expire() }) != nil
            loop.execute { [self] in
                if !healthy { health = .degraded }
                else if case .volatile = health { health = .healthy }
                settle(releasing: [workspace]) {}
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

    /// Drop queued old-authority snapshots and wait for the one database
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
    /// The connection is closed and the database files are removed, so a
    /// corrupt or unsupported database is cleared as well.
    func clearHistory(_ completion: @escaping (ClearOutcome) -> Void) {
        loop.assertInEventLoop()
        pauseForAuthority { [self] in
            guard let workspace = reserveWorkspace(ConversationDatabase.connectionWorkspaceBytes) else {
                health = .degraded; completion(.unavailable); return
            }
            guard storageGeneration < UInt64.max else { capture.release(workspace); completion(.unavailable); return }
            storageGeneration += 1
            running = true
            worker.async { [self] in
                let outcome: ClearOutcome
                database = nil
                do {
                    try producerLease.verify()
                    try ConversationDatabase.removeAll(stateDirectory: root)
                    try producerLease.verify()
                    databaseUnsafe = false; openRetryAfter = 0
                    outcome = .cleared
                } catch { outcome = .partial }
                loop.execute { [self] in
                    if case .cleared = outcome {} else { health = .degraded }
                    settle(releasing: [workspace]) { completion(outcome) }
                }
            }
        }
    }

    /// The caller waits outside the event loop and imposes its own deadline.
    /// Every pending record is written without waiting for its quiet interval.
    func finishWhenIdle() -> Finish {
        loop.assertInEventLoop()
        let result = Finish()
        finished = result
        drain()
        return result
    }

    private func ready(_ value: Pending, at now: NIODeadline) -> Bool {
        finished != nil || value.urgent || now >= value.lastChange + Self.quietInterval || now >= value.firstChange + Self.maximumDelay
    }

    private func drain() {
        loop.assertInEventLoop()
        guard !running, !authorityPaused else { return }
        if pending.isEmpty {
            guard let completion = finished else { return }
            finished = nil; running = true
            worker.async { [self] in
                database = nil
                loop.execute { [self] in
                    running = false
                    completion.complete(!shutdownFailed)
                }
            }
            return
        }
        let now = NIODeadline.now()
        guard let key = pending.keys.sorted().first(where: { ready(pending[$0]!, at: now) }), let next = pending[key] else {
            wake(at: pending.values.map { min($0.lastChange + Self.quietInterval, $0.firstChange + Self.maximumDelay) }.min()!)
            return
        }
        let headroom = finished == nil ? Self.readerHeadroomBytes : 0
        let bytes = Self.saveWorkspaceBytes(next.record)
        guard bytes <= capture.limits.totalBytes - capture.limits.fixedBytes - Self.recordBytes else {
            // This record can never be admitted; waiting would retry forever.
            pending.removeValue(forKey: key)
            capture.release(next.reservation)
            health = .degraded
            if finished != nil { shutdownFailed = true }
            loop.execute { next.completion(false) }
            drain()
            return
        }
        guard let workspace = reserveWorkspace(bytes, headroom: headroom) else {
            // Keep the bounded, coalesced record rather than silently dropping
            // it. Retry on the owning loop after other reservations can drain.
            wake(at: now + .milliseconds(100))
            return
        }
        pending.removeValue(forKey: key)
        running = true
        worker.async { [self] in
            var report: ConversationDatabase.SaveReport?
            do { report = try perform { try $0.save(next.record, updatedAt: next.updatedAt) } } catch {}
            loop.execute { [self] in
                // A clear that began after this record was scheduled wins.
                let success = report != nil && next.generation == storageGeneration
                #if SHPHRD_PERSISTENCE_TESTING
                if let report { testSaves.append(report) }
                #endif
                if !success {
                    health = .degraded
                    if finished != nil { shutdownFailed = true }
                } else if case .volatile = health { health = .healthy }
                settle(releasing: [workspace, next.reservation]) {
                    loop.execute { next.completion(success) }
                }
            }
        }
    }

    private func wake(at deadline: NIODeadline) {
        if let wakeAt, wakeAt <= deadline { return }
        wakeAt = deadline
        loop.scheduleTask(deadline: deadline) { [weak self] in
            guard let self else { return }
            if let wakeAt = self.wakeAt, wakeAt <= NIODeadline.now() { self.wakeAt = nil }
            self.drain()
        }
    }

    private func settle(releasing reservations: [UUID], completion: () -> Void) {
        loop.assertInEventLoop()
        for reservation in reservations { capture.release(reservation) }
        running = false
        let waiters = fenceWaiters
        fenceWaiters.removeAll()
        completion()
        for (index, waiter) in waiters.enumerated() {
            if running {
                fenceWaiters.insert(contentsOf: waiters[index...], at: 0)
                break
            }
            waiter()
        }
        drain()
    }
}
