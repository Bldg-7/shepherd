import Foundation

/// Presentation-only facts. PID/status/turn never authenticate an agent or
/// authorize input/termination. Core's private parent `seen` is NOT UI seen.
public nonisolated struct CoreAttentionRecord: Decodable, Equatable, Sendable {
    public struct Status: Decodable, Equatable, Sendable { public let state: String }
    public let address: String
    public let state: String
    public let pid: UInt32?
    public let created_ms: UInt64
    public let finished_ms: UInt64?
    public let reported: Bool
    public let status: Status?
    public let status_ms: UInt64?
    public let turn: UInt64
    public let reason: String?
}

public nonisolated struct CoreAttentionFeed: Sendable {
    public enum Kind: Int, Codable, Sendable { case blocked, done, exitedWhileWorking }
    public struct Key: Equatable, Sendable {
        public let terminal: CoreWorkspaceDocument.TerminalReference
        public let created: UInt64
        public let turn: UInt64
        public let timestamp: UInt64
        public let kind: Kind
        fileprivate func isNewer(than other: Self) -> Bool {
            if created != other.created { return false } // An incarnation change requires a baseline.
            if turn != other.turn { return turn > other.turn }
            if timestamp != other.timestamp { return timestamp > other.timestamp }
            return kind.rawValue > other.kind.rawValue
        }
    }
    public struct Candidate: Equatable, Sendable {
        public let epoch: UUID
        public let key: Key
        fileprivate let nonce = UUID()
    }
    public let coreID: String
    public private(set) var epoch: UUID
    public private(set) var overflowed = false
    private var needsBaseline = true
    private var sequence: UInt64?
    private var records: [String: CoreAttentionRecord] = [:]
    private var decided: [String: Key] = [:]
    private var pending: [String: Candidate] = [:]
    public init(coreID: String, epoch: UUID) { self.coreID = coreID; self.epoch = epoch }

    public mutating func reconnect(epoch: UUID) {
        self.epoch = epoch; needsBaseline = true; sequence = nil; records.removeAll(); decided.removeAll(); pending.removeAll(); overflowed = false
    }
    private func sameProgram(_ a: CoreAttentionRecord, _ b: CoreAttentionRecord) -> Bool {
        a.created_ms == b.created_ms && !(b.state == "live" && (a.state != "live" || a.pid != b.pid))
    }
    private func key(_ record: CoreAttentionRecord, previous: CoreAttentionRecord?) -> Key? {
        let kind: Kind, timestamp: UInt64
        if record.state == "live", record.reported, let time = record.status_ms {
            switch record.status?.state {
            case "blocked", "error": kind = .blocked
            case "done": kind = .done
            default: return nil
            }
            timestamp = time
        } else if record.state == "finished", previous?.state == "live", previous?.status?.state == "working",
                  previous?.reported == true, record.reason != "killed", let time = record.finished_ms {
            kind = .exitedWhileWorking; timestamp = time
        } else { return nil }
        return Key(terminal: .init(coreID: coreID, terminalID: record.address), created: record.created_ms,
                   turn: record.turn, timestamp: timestamp, kind: kind)
    }
    /// Full snapshots only. First connection/missed snapshot is baseline-only;
    /// new/restarted terminals also get a baseline instead of catch-up alerts.
    public mutating func observe(_ snapshot: [CoreAttentionRecord], epoch: UUID, sequence nextSequence: UInt64, baseline: Bool = false,
                                 restarted: Set<String> = []) throws -> [Candidate] {
        guard epoch == self.epoch else { throw CoreWorkspaceSyncFailure.staleOperation }
        if let sequence {
            if baseline { guard nextSequence >= sequence else { throw CoreWorkspaceSyncFailure.inconsistentSnapshot } }
            else if nextSequence <= sequence { return [] }
        }
        guard snapshot.count <= 4096 else { throw CoreWorkspaceFailure.limitExceeded }
        var next: [String: CoreAttentionRecord] = [:]
        for record in snapshot {
            // Direct-origin feed only: never mistake gateway aliases for IDs.
            guard !record.address.isEmpty, record.address.utf8.count <= 256, !record.address.contains("/"),
                  record.state.utf8.count <= 32, (record.status?.state.utf8.count ?? 0) <= 32, (record.reason?.utf8.count ?? 0) <= 128,
                  next.updateValue(record, forKey: record.address) == nil else { throw CoreWorkspaceFailure.invalidReference }
        }
        let reset = needsBaseline || baseline || sequence.map { nextSequence - $0 > 1 } == true
        if reset { pending.removeAll(); overflowed = false }
        var candidates: [Candidate] = []
        for address in next.keys.sorted() {
            let record = next[address]!, previous = records[address]
            if reset || previous == nil || restarted.contains(address) || !sameProgram(previous!, record) {
                pending[address] = nil; decided[address] = key(record, previous: nil)
                continue
            }
            let eventKey = key(record, previous: previous)
            // A terminal that remains finished must retain its exit candidate.
            if record == previous, pending[address] != nil { continue }
            if let existing = pending[address], existing.key != eventKey { pending[address] = nil }
            guard let eventKey else { continue }
            if let old = decided[address], !eventKey.isNewer(than: old) { continue }
            if pending[address]?.key == eventKey { continue }
            guard pending.count < 128 else {
                // Bound backlog without evicting old keys and replaying them.
                overflowed = true; decided[address] = eventKey; continue
            }
            let candidate = Candidate(epoch: epoch, key: eventKey)
            pending[address] = candidate; candidates.append(candidate)
        }
        records = next; needsBaseline = false; sequence = nextSequence
        decided = decided.filter { next[$0.key] != nil }; pending = pending.filter { next[$0.key] != nil }
        return candidates
    }
    /// Caller refetches on the SAME connection immediately before presentation.
    /// This check does not request OS notification permission or show anything.
    public func confirm(_ candidate: Candidate, fresh: CoreAttentionRecord, epoch: UUID) -> Bool {
        let address = candidate.key.terminal.terminalID
        guard epoch == self.epoch, candidate.epoch == epoch, candidate.key.terminal.coreID == coreID,
              pending[address] == candidate, fresh.address == address, let prior = records[address], sameProgram(prior, fresh) else { return false }
        if candidate.key.kind == .exitedWhileWorking {
            return fresh.state == "finished" && fresh.turn == candidate.key.turn && fresh.finished_ms == candidate.key.timestamp && fresh.reason != "killed"
        }
        return key(fresh, previous: prior) == candidate.key
    }
    public mutating func delivered(_ candidate: Candidate) throws {
        let address = candidate.key.terminal.terminalID
        guard candidate.epoch == epoch, pending[address] == candidate else { throw CoreWorkspaceSyncFailure.staleOperation }
        decided[address] = candidate.key; pending[address] = nil
    }
    /// Call only for an actually viewed pane, not merely a remote focus update.
    public mutating func markViewed(_ address: String) {
        if let candidate = pending[address] { decided[address] = candidate.key; pending[address] = nil }
        else if let record = records[address], let key = key(record, previous: nil) { decided[address] = key }
    }
    public var pendingCount: Int { pending.count }
}
