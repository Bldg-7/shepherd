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
    private var running = false
    private var finished: DispatchSemaphore?
    private(set) var health: Health = .volatile

    init(root: String, loop: EventLoop, capture: ConversationCapture) {
        self.root = root; self.loop = loop; self.capture = capture
    }

    /// The fixed reservation covers the normalized record and transient
    /// encoding; pressure skips a snapshot instead of delaying forwarding.
    func schedule(_ record: ConversationStore.PersistentSnapshot.Record) -> Bool {
        loop.assertInEventLoop()
        guard pending[record.id] != nil || pending.count < 8,
              capture.accountedBytes <= capture.limits.totalBytes - min(capture.limits.totalBytes, 8 << 20),
              let reservation = capture.reserve(bytes: 8 << 20) else { health = .degraded; return false }
        if let old = pending.updateValue(Pending(record: record, reservation: reservation, updatedAt: Date()), forKey: record.id) {
            capture.release(old.reservation)
        }
        drain()
        return true
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
        running = true
        worker.async { [self] in
            let success: Bool
            do {
                if journal == nil {
                    guard !initializationFailed else { throw ConversationPersistenceJournalError.unavailable }
                    do {
                        let files = try ConversationPersistenceFiles(verifiedStateRootPath: root)
                        let opened = ConversationPersistenceJournal(files: files)
                        try opened.activate()
                        journal = opened
                    } catch {
                        initializationFailed = true
                        throw error
                    }
                }
                try journal!.upsert(next.record, updatedAt: next.updatedAt)
                success = true
            } catch { success = false }
            loop.execute { [self] in
                capture.release(next.reservation)
                if !success { health = .degraded }
                else if case .volatile = health { health = .healthy }
                running = false
                drain()
            }
        }
    }
}
