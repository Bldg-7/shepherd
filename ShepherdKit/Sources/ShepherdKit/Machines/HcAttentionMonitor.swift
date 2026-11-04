import Foundation

/// One origin's passive attention subscription. Status is presentation only;
/// never authorizes input, termination, native sessions or browser access.
public actor HcAttentionMonitor {
    public struct View: Sendable { public let terminals: [CoreAttentionRecord]; public let unreadBlocked: Int }
    private struct Initial: Decodable { let seq: UInt64; let terminals: [CoreAttentionRecord] }
    private struct Listed: Decodable { let terminals: [CoreAttentionRecord] }
    private struct Notice: Decodable {
        struct Params: Decodable { let seq: UInt64; let type: String?; let terminal: String?; let machine: String? }
        let jsonrpc: String; let method: String; let params: Params
    }
    private struct Stamp: Equatable { let created: UInt64; let pid: UInt32?; let turn: UInt64; let time: UInt64? }
    public nonisolated let coreID: String
    private let connection: CoreRPCConnection
    private let delay: Duration
    private var feed: CoreAttentionFeed
    private var records: [CoreAttentionRecord] = []
    private var viewed = Set<String>()
    private var seen: [String: Stamp] = [:]
    private var started = false
    private var closed = false
    private var stream: CoreStream?
    private var opening: Task<CoreStream, Error>?
    private var closing: Task<Void, Error>?
    private var stateCallback: (@Sendable (View) async -> Void)?

    public init(connection: CoreRPCConnection, confirmationDelay: Duration = .milliseconds(1500)) async throws {
        guard await connection.state == .ready, let hello = await connection.hello,
              confirmationDelay >= .zero, confirmationDelay <= .seconds(5) else { throw CoreConnectionFailure.notReady }
        self.connection = connection; coreID = hello.core.id; delay = confirmationDelay
        feed = CoreAttentionFeed(coreID: hello.core.id, epoch: connection.epoch)
    }
    deinit {
        opening?.cancel()
        if let stream { Task { try? await stream.close() } }
    }
    private func stamp(_ record: CoreAttentionRecord) -> Stamp {
        Stamp(created: record.created_ms, pid: record.pid, turn: record.turn, time: record.status_ms)
    }
    public func view() -> View {
        View(terminals: records, unreadBlocked: records.filter {
            $0.state == "live" && $0.reported && ["blocked", "error"].contains($0.status?.state ?? "") && !viewed.contains($0.address) && seen[$0.address] != stamp($0)
        }.count)
    }
    public func setViewed(_ addresses: Set<String>) async throws -> View {
        guard addresses.count <= 4096 else { throw CoreWorkspaceFailure.limitExceeded }
        viewed = addresses
        for record in records where viewed.contains(record.address) { feed.markViewed(record.address); seen[record.address] = stamp(record) }
        let value = view(); await stateCallback?(value); return value
    }
    private func direct(_ all: [CoreAttentionRecord]) throws -> [CoreAttentionRecord] {
        guard all.count <= 4096 else { throw CoreWorkspaceFailure.limitExceeded }
        return all.filter { !$0.address.contains("/") }
    }
    private func observe(_ all: [CoreAttentionRecord], sequence: UInt64, baseline: Bool, restarted: Set<String> = []) async throws -> [CoreAttentionFeed.Candidate] {
        guard !closed else { throw CoreStreamFailure.closed }
        records = try direct(all)
        let candidates = try feed.observe(records, epoch: connection.epoch, sequence: sequence, baseline: baseline, restarted: restarted)
        let addresses = Set(records.map(\.address))
        seen = seen.filter { addresses.contains($0.key) }
        for record in records where viewed.contains(record.address) { feed.markViewed(record.address); seen[record.address] = stamp(record) }
        await stateCallback?(view())
        return candidates
    }
    /// Can be called again after OS permission UI, before requesting a banner.
    /// It never returns facts from another connection epoch or from a label.
    public func confirm(_ candidate: CoreAttentionFeed.Candidate) async throws -> CoreAttentionRecord? {
        guard !closed, !viewed.contains(candidate.key.terminal.terminalID) else { return nil }
        let params = try JSONEncoder().encode(["terminal":candidate.key.terminal.terminalID])
        let fresh: CoreAttentionRecord = try await connection.call("terminal.get", parameters: params).result()
        guard !closed, !viewed.contains(fresh.address), feed.confirm(candidate, fresh: fresh, epoch: connection.epoch) else { return nil }
        return fresh
    }
    public func run(state: @escaping @Sendable (View) async -> Void,
                    attention: @escaping @Sendable (CoreAttentionFeed.Candidate, CoreAttentionRecord) async -> Bool) async throws {
        guard !started, !closed else { throw CoreStreamFailure.closed }
        started = true; stateCallback = state
        let connection = connection
        let job = Task { try await connection.openStream("events.subscribe") }; opening = job
        do {
            let stream = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            opening = nil
            guard !closed else { try await stream.close(); throw CoreStreamFailure.closed }
            self.stream = stream
            let initial: Initial = try stream.initialReply.result()
            var sequence = initial.seq
            _ = try await observe(initial.terminals, sequence: sequence, baseline: true)
            var lines = try CoreEventLines(maximumLineBytes: 1 << 20)
            while let packet = try await stream.next(timeout: .seconds(45)) {
                guard !closed, packet.frame.kind == .data else { throw CoreStreamFailure.closed }
                var notices: [Notice] = []
                try lines.receive(packet.frame.payload) { data in
                    guard notices.count < 4096 else { throw CoreWorkspaceFailure.limitExceeded }
                    let note = try JSONDecoder().decode(Notice.self, from: data)
                    guard note.jsonrpc == "2.0" else { throw CoreWorkspaceFailure.invalidDocument }
                    notices.append(note)
                }
                var candidates: [CoreAttentionFeed.Candidate] = []
                // Admit each actual sequence, even if several notices share a
                // DATA packet. Coalescing 2 consecutive events into a +2 jump
                // would falsely look like a missed-event baseline to the feed.
                for note in notices {
                    var changed = false, baseline = false, restarted = Set<String>()
                    let next = note.params.seq
                    switch note.method {
                    case "missed", "snapshot":
                        guard next >= sequence else { throw CoreWorkspaceSyncFailure.inconsistentSnapshot }
                        sequence = next; baseline = true; changed = true
                    case "heartbeat":
                        guard next >= sequence else { throw CoreWorkspaceSyncFailure.inconsistentSnapshot }
                        if next > sequence { sequence = next; baseline = true; changed = true }
                    case "event":
                        guard let kind = note.params.type, !kind.isEmpty, kind.utf8.count <= 128 else { throw CoreWorkspaceFailure.invalidDocument }
                        if next <= sequence { continue }
                        baseline = next - sequence > 1; sequence = next; changed = true
                        if note.params.type == "restarted", note.params.machine == nil, let terminal = note.params.terminal { restarted.insert(terminal) }
                    default: throw CoreWorkspaceFailure.invalidDocument
                    }
                    if changed {
                        let listed: Listed = try await connection.call("terminal.list", parameters: Data("{\"all\":true}".utf8)).result()
                        candidates += try await observe(listed.terminals, sequence: sequence, baseline: baseline, restarted: restarted)
                    }
                }
                try await stream.acknowledge(packet) // After validated parsing/state admission, not before consumption.
                if !candidates.isEmpty { try await Task.sleep(for: delay) }
                for candidate in candidates {
                    guard !closed else { throw CoreStreamFailure.closed }
                    if let fresh = try await confirm(candidate), await attention(candidate, fresh), !closed {
                        // A viewed or changed candidate may have retired while
                        // the OS awaited permission. Never recreate it here.
                        if feed.confirm(candidate, fresh: fresh, epoch: connection.epoch) { try feed.delivered(candidate) }
                    }
                }
            }
            try lines.finish()
            throw CoreStreamFailure.closed
        } catch {
            opening = nil
            try await close()
            throw error
        }
    }
    public func close() async throws {
        if let closing { try await closing.value; return }
        closed = true; stateCallback = nil
        let opening = opening, stream = stream
        opening?.cancel()
        let task = Task {
            if let opened = try? await opening?.value { try await opened.close() }
            try await stream?.close()
        }
        closing = task; try await task.value
        self.stream = nil; self.opening = nil
    }
}
