import Foundation

public nonisolated enum CoreWorkspaceRecoveryFailure: Error, Equatable, Sendable {
    case staleTicket, busy, limit, invalidJournal, requiresReview, targetChanged
}

/// Records non-atomic run/doc and close/kill outcomes. This is NOT a dispatcher
/// or authorization source. The caller performs authorized RPCs exactly once.
/// persist MUST save successfully before returning; failed persistence exposes
/// no dispatch ticket. No argv, environment, credential or browser lease is saved.
public actor CoreWorkspaceRecovery {
    public enum Kind: String, Codable, Sendable { case launch, close }
    public enum Run: String, Codable, Sendable { case inFlight, returned, uncertain, notDispatched }
    public enum Layout: String, Codable, Sendable { case pending, inFlight, confirmed, conflict, uncertain }
    public enum Stop: String, Codable, Sendable { case pending, inFlight, confirmed, uncertain, shared, foreign }
    public struct Target: Codable, Equatable, Sendable {
        public let terminal: CoreWorkspaceDocument.TerminalReference
        public fileprivate(set) var state: Stop
    }
    public struct Member: Codable, Equatable, Sendable {
        public let paneID: UUID
        public let terminal: CoreWorkspaceDocument.TerminalReference?
    }
    public struct Record: Codable, Equatable, Sendable {
        public let id: UUID
        public let epoch: UUID
        public let kind: Kind
        public let paneID: UUID?
        public let tabID: UUID?
        public let members: [Member]
        public fileprivate(set) var run: Run?
        public fileprivate(set) var terminal: CoreWorkspaceDocument.TerminalReference?
        public fileprivate(set) var layout: Layout
        public fileprivate(set) var targets: [Target]
        fileprivate var layoutAttempt: UUID?
        fileprivate var layoutVersion: UInt64?
        public var complete: Bool {
            layout == .confirmed && (kind == .launch || targets.allSatisfy { $0.state == .confirmed || $0.state == .shared })
        }
    }
    public struct Ticket: Sendable {
        public let operationID: UUID
        public let epoch: UUID
        fileprivate let session: UUID
        /// Correlation ONLY. Even one matching label is not proof of ownership.
        public var label: [String: String] { ["3rdr.operation": operationID.uuidString.lowercased()] }
    }
    public struct LayoutAttempt: Sendable {
        public let ticket: Ticket
        public let expectedVersion: UInt64
        public let edit: CoreWorkspaceEdit
        fileprivate let nonce: UUID
    }
    public struct StopAttempt: Sendable {
        public let ticket: Ticket
        public let terminal: CoreWorkspaceDocument.TerminalReference
    }
    private struct Saved: Codable { let schema: Int; let coreID: String; let records: [Record] }
    public nonisolated let coreID: String
    public nonisolated let epoch: UUID
    private let session = UUID()
    private let persist: @Sendable (Data) throws -> Void
    private var records: [Record]

    public init(coreID: String, epoch: UUID, restoring data: Data? = nil,
                persist: @escaping @Sendable (Data) throws -> Void) throws {
        guard Self.validCoreID(coreID) else { throw CoreWorkspaceRecoveryFailure.invalidJournal }
        self.coreID = coreID; self.epoch = epoch; self.persist = persist
        if let data {
            guard data.count <= 1 << 20 else { throw CoreWorkspaceRecoveryFailure.limit }
            let saved = try JSONDecoder().decode(Saved.self, from: data)
            guard saved.schema == 1, saved.coreID == coreID, saved.records.count <= 64,
                  Set(saved.records.map(\.id)).count == saved.records.count else { throw CoreWorkspaceRecoveryFailure.invalidJournal }
            var restored = saved.records
            for index in restored.indices {
                let record = restored[index]
                guard record.targets.count <= 128, record.members.count <= CoreWorkspaceDocument.maximumItems,
                      Set(record.targets.map(\.terminal)).count == record.targets.count,
                      Set(record.members.map(\.paneID)).count == record.members.count,
                      (record.kind == .launch ? record.paneID != nil && record.tabID == nil && record.run != nil && record.targets.isEmpty : record.tabID != nil && record.paneID == nil && record.run == nil),
                      record.run != .returned || record.terminal?.coreID == coreID,
                      (record.terminal.map(Self.validReference) ?? true),
                      record.targets.allSatisfy({ Self.validReference($0.terminal) }),
                      record.members.allSatisfy({ $0.terminal.map(Self.validReference) ?? true }) else {
                    throw CoreWorkspaceRecoveryFailure.invalidJournal
                }
                if restored[index].run == .inFlight { restored[index].run = .uncertain }
                if restored[index].layout == .inFlight { restored[index].layout = .uncertain }
                restored[index].layoutAttempt = nil
                for target in restored[index].targets.indices where restored[index].targets[target].state == .inFlight {
                    restored[index].targets[target].state = .uncertain
                }
            }
            records = restored
        } else { records = [] }
    }
    private nonisolated static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
        }
    }
    private nonisolated static func validCoreID(_ value: String) -> Bool { identifier(value) }
    private nonisolated static func validReference(_ ref: CoreWorkspaceDocument.TerminalReference) -> Bool {
        canonicalID(ref.terminalID) && validCoreID(ref.coreID)
    }
    /// Generation-1 terminal IDs, not names. Names can retarget another program.
    private nonisolated static func canonicalID(_ value: String) -> Bool {
        let bytes = Array(value.utf8), alphabet = Array("0123456789bcdfghjkmnpqrstvwxyz".utf8)
        guard bytes.count >= 2, bytes.count <= 9, bytes[0] == 116, (49...57).contains(bytes[1]) else { return false }
        var rest = UInt64(bytes[1] - 49), before: UInt64 = 0, size: UInt64 = 9
        for byte in bytes.dropFirst(2) {
            guard let digit = alphabet.firstIndex(of: byte) else { return false }
            rest = rest * 30 + UInt64(digit); before += size; size *= 30
            if before + rest + 1 > UInt32.max { return false }
        }
        return before + rest + 1 <= UInt32.max
    }
    public func snapshot() -> [Record] { records }
    public func encoded() throws -> Data { try encode(records) }
    private func encode(_ records: [Record]) throws -> Data {
        let data = try JSONEncoder().encode(Saved(schema: 1, coreID: coreID, records: records))
        guard data.count <= 1 << 20, records.count <= 64 else { throw CoreWorkspaceRecoveryFailure.limit }
        return data
    }
    private func save(_ next: [Record]) throws { try persist(encode(next)); records = next }
    private func index(_ ticket: Ticket) throws -> Int {
        guard ticket.session == session, ticket.epoch == epoch,
              let index = records.firstIndex(where: { $0.id == ticket.operationID && $0.epoch == epoch }) else { throw CoreWorkspaceRecoveryFailure.staleTicket }
        return index
    }
    private func ticket(_ id: UUID) -> Ticket { Ticket(operationID: id, epoch: epoch, session: session) }

    /// Reserve before terminal.run. The supplied snapshot must be fresh; it is
    /// not authority. Native launch reservation/credentials remain independent.
    public func beginLaunch(paneID: UUID, document: CoreWorkspaceDocument) throws -> Ticket {
        guard let pane = document.pane(paneID), pane.terminal == nil else { throw CoreWorkspaceRecoveryFailure.targetChanged }
        guard !records.contains(where: { $0.paneID == paneID && !$0.complete }) else { throw CoreWorkspaceRecoveryFailure.busy }
        let record = Record(id: UUID(), epoch: epoch, kind: .launch, paneID: paneID, tabID: nil, members: [], run: .inFlight, terminal: nil, layout: .pending, targets: [])
        try save(records + [record]); return ticket(record.id)
    }
    /// A missing/failed RPC reply is uncertain, not a license to re-run. Only a
    /// matching successful run reply supplies a known terminal reference.
    public func finishLaunch(_ ticket: Ticket, terminal: CoreWorkspaceDocument.TerminalReference?) throws {
        let i = try index(ticket)
        guard records[i].kind == .launch, records[i].run == .inFlight else { throw CoreWorkspaceRecoveryFailure.staleTicket }
        if let terminal { guard terminal.coreID == coreID, Self.validReference(terminal) else { throw CoreWorkspaceRecoveryFailure.targetChanged } }
        var next = records; next[i].run = terminal == nil ? .uncertain : .returned; next[i].terminal = terminal
        try save(next)
    }
    /// An explicit close plan records unique targets. Shared views are retained;
    /// foreign-origin targets need their own routing/authorization, never aliases.
    public func beginClose(tabID: UUID, document: CoreWorkspaceDocument, endPrograms: Bool) throws -> Ticket {
        guard let tab = document.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }) else { throw CoreWorkspaceRecoveryFailure.targetChanged }
        guard !records.contains(where: { $0.tabID == tabID && !$0.complete }) else { throw CoreWorkspaceRecoveryFailure.busy }
        let panes = tab.layout?.panes ?? [], ids = Set(panes.map(\.id))
        let elsewhere = Set(document.panes.filter { !ids.contains($0.id) }.compactMap(\.terminal))
        let references = Set(panes.compactMap(\.terminal)).sorted { ($0.coreID, $0.terminalID) < ($1.coreID, $1.terminalID) }
        guard references.count <= 128 else { throw CoreWorkspaceRecoveryFailure.limit }
        guard references.allSatisfy(Self.validReference) else { throw CoreWorkspaceRecoveryFailure.targetChanged }
        let targets = endPrograms ? references.map { ref in Target(terminal: ref, state: elsewhere.contains(ref) ? .shared : ref.coreID == coreID ? .pending : .foreign) } : []
        let record = Record(id: UUID(), epoch: epoch, kind: .close, paneID: nil, tabID: tabID,
                            members: panes.map { Member(paneID: $0.id, terminal: $0.terminal) }, run: nil, terminal: nil, layout: .pending, targets: targets)
        try save(records + [record]); return ticket(record.id)
    }
    /// Explicit reapplication after review, not an automatic retry loop. Check
    /// the target fields against a freshly read document and persist the attempt
    /// BEFORE doc.set. A response-loss outcome must first be reconciled by read.
    public func prepareLayoutAfterReview(_ ticket: Ticket, snapshot: CoreWorkspaceCAS.Snapshot) throws -> LayoutAttempt? {
        let i = try index(ticket), record = records[i]
        guard record.layout == .pending || record.layout == .conflict else { throw CoreWorkspaceRecoveryFailure.requiresReview }
        guard let document = snapshot.document else { throw CoreWorkspaceRecoveryFailure.targetChanged }
        let edit: CoreWorkspaceEdit
        if record.kind == .launch {
            guard record.run == .returned, let paneID = record.paneID, let terminal = record.terminal,
                  let pane = document.pane(paneID), pane.terminal == nil else { throw CoreWorkspaceRecoveryFailure.targetChanged }
            edit = .bindPane(paneID, expected: nil, replacement: terminal)
        } else {
            guard let tab = document.workspaces.flatMap(\.tabs).first(where: { $0.id == record.tabID }),
                  (tab.layout?.panes ?? []).map({ Member(paneID: $0.id, terminal: $0.terminal) }) == record.members else { throw CoreWorkspaceRecoveryFailure.targetChanged }
            edit = .removeTab(tab.id)
        }
        let nonce = UUID()
        var next = records; next[i].layout = .inFlight; next[i].layoutAttempt = nonce; next[i].layoutVersion = snapshot.version; try save(next)
        return LayoutAttempt(ticket: ticket, expectedVersion: snapshot.version, edit: edit, nonce: nonce)
    }
    public func finishLayout(_ attempt: LayoutAttempt, result: CoreWorkspaceCAS.WriteResult) throws {
        let i = try index(attempt.ticket)
        guard records[i].layout == .inFlight, records[i].layoutAttempt == attempt.nonce else { throw CoreWorkspaceRecoveryFailure.staleTicket }
        var next = records; next[i].layoutAttempt = nil
        switch result {
        case .acknowledged(let version):
            guard attempt.expectedVersion < UInt64.max, version == attempt.expectedVersion + 1 else {
                next[i].layout = .uncertain; try save(next); throw CoreWorkspaceSyncFailure.inconsistentSnapshot
            }
            next[i].layout = .confirmed
        case .conflict: next[i].layout = .conflict
        case .uncertain: next[i].layout = .uncertain
        }
        try save(next)
    }
    /// Reading can resolve metadata even after reconnect, but never creates new
    /// dispatch tickets or treats operation labels as ownership proof.
    public func reconcileLayout(operationID: UUID, snapshot: CoreWorkspaceCAS.Snapshot) throws {
        guard let i = records.firstIndex(where: { $0.id == operationID }) else { throw CoreWorkspaceRecoveryFailure.staleTicket }
        let record = records[i]
        guard record.layout != .inFlight else { throw CoreWorkspaceRecoveryFailure.busy }
        if let floor = record.layoutVersion, snapshot.version < floor { throw CoreWorkspaceRecoveryFailure.targetChanged }
        let document = snapshot.document
        let complete: Bool
        if record.kind == .launch {
            complete = record.terminal != nil && document?.pane(record.paneID!)?.terminal == record.terminal
        } else { complete = document?.workspaces.flatMap(\.tabs).contains(where: { $0.id == record.tabID }) != true }
        if complete, let floor = record.layoutVersion, snapshot.version <= floor { throw CoreWorkspaceRecoveryFailure.targetChanged }
        var next = records; next[i].layout = complete ? .confirmed : .conflict; try save(next)
    }
    /// Only an explicit caller-approved first attempt. No uncertain stop can be
    /// retried automatically: hc kill has no atomic process-incarnation CAS.
    /// The dispatcher must separately validate current authority/terminal facts.
    public func beginStop(_ ticket: Ticket, terminal: CoreWorkspaceDocument.TerminalReference,
                          currentDocument: CoreWorkspaceDocument) throws -> StopAttempt? {
        let i = try index(ticket)
        guard records[i].kind == .close, records[i].layout == .confirmed,
              let t = records[i].targets.firstIndex(where: { $0.terminal == terminal }), records[i].targets[t].state == .pending else { throw CoreWorkspaceRecoveryFailure.requiresReview }
        var next = records
        if currentDocument.panes.contains(where: { $0.terminal == terminal }) {
            next[i].targets[t].state = .shared; try save(next); return nil
        }
        guard terminal.coreID == coreID else { throw CoreWorkspaceRecoveryFailure.requiresReview }
        next[i].targets[t].state = .inFlight; try save(next)
        return StopAttempt(ticket: ticket, terminal: terminal)
    }
    public func finishStop(_ attempt: StopAttempt, confirmedEnded: Bool) throws {
        let i = try index(attempt.ticket)
        guard let t = records[i].targets.firstIndex(where: { $0.terminal == attempt.terminal }), records[i].targets[t].state == .inFlight else { throw CoreWorkspaceRecoveryFailure.staleTicket }
        var next = records; next[i].targets[t].state = confirmedEnded ? .confirmed : .uncertain; try save(next)
    }
    /// Reconcile a lost kill reply using a fresh direct-origin terminal.get,
    /// never absence from a list or a label. This does not issue another kill.
    public func confirmStoppedAfterRead(operationID: UUID, terminal: CoreAttentionRecord) throws {
        guard terminal.state == "finished", let i = records.firstIndex(where: { $0.id == operationID }),
              let t = records[i].targets.firstIndex(where: { $0.terminal.coreID == coreID && $0.terminal.terminalID == terminal.address }),
              records[i].targets[t].state == .uncertain else { throw CoreWorkspaceRecoveryFailure.requiresReview }
        var next = records; next[i].targets[t].state = .confirmed; try save(next)
    }

    /// Forgetting recovery metadata never terminates a program. Must be an
    /// explicit UI action after review, not quota eviction or automatic cleanup.
    public func forgetAfterUserReview(_ operationID: UUID) throws { try save(records.filter { $0.id != operationID }) }
}
