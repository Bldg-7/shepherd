import Foundation

/// Native agent session identity, scoped to a local herdr session. Route,
/// pane and terminal IDs are deliberately not the conversation key: a resumed
/// native session may get a new route and terminal. Callers supply public IDs,
/// never launch URLs, route tokens, credentials or session-file paths.
public nonisolated struct ConversationKey: Hashable, Sendable {
    public let agent: String
    public let herdrSession: String
    public let nativeSession: String

    public init?(agent: String, herdrSession: String, nativeSession: String) {
        guard ["claude", "codex", "pi"].contains(agent),
              RequestProjection.identifier(herdrSession) != nil,
              RequestProjection.identifier(nativeSession) != nil else { return nil }
        self.agent = agent; self.herdrSession = herdrSession; self.nativeSession = nativeSession
    }

    // These are opaque identifiers, not natural-language text. Swift String
    // equality otherwise merges canonically equivalent Unicode spellings.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent.utf8.elementsEqual(rhs.agent.utf8)
            && lhs.herdrSession.utf8.elementsEqual(rhs.herdrSession.utf8)
            && lhs.nativeSession.utf8.elementsEqual(rhs.nativeSession.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Data(agent.utf8))
        hasher.combine(Data(herdrSession.utf8))
        hasher.combine(Data(nativeSession.utf8))
    }
}

public nonisolated struct ConversationContext: Equatable, Sendable {
    public let routeID: String
    public let paneID: String
    public let terminalID: String

    public init?(routeID: String, paneID: String, terminalID: String) {
        guard [routeID, paneID, terminalID].allSatisfy({ RequestProjection.identifier($0) != nil }) else { return nil }
        self.routeID = routeID; self.paneID = paneID; self.terminalID = terminalID
    }
}

public nonisolated struct ConversationItem: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case reconstructed, observed, response, summary, discontinuity
        /// Localized separator/status, never an empty assistant speech bubble.
        case compaction(CapturedCompaction.Availability)
        case subagent(id: String, depth: Int?)
    }
    /// Stable ID supplied by the reconciler, never inferred from text equality.
    public let id: String
    public let message: CapturedMessage
    public let origin: Origin
    public let status: CapturedResponse.Status

    public init(id: String, message: CapturedMessage, origin: Origin, status: CapturedResponse.Status) {
        self.id = id; self.message = message; self.origin = origin; self.status = status
    }

    var cost: Int {
        let childBytes: Int
        if case .subagent(let child, _) = origin { childBytes = child.utf8.count + 32 } else { childBytes = 0 }
        return 128 + id.utf8.count + message.cost + childBytes
    }
}

public nonisolated struct ConversationSummary: Equatable, Sendable {
    public let id: String
    public let key: ConversationKey
    public let context: ConversationContext
    public let revision: UInt64
    /// Changes when history before the last live item is replaced or evicted.
    public let historyRevision: UInt64
    public let itemCount: Int
    public let truncated: Bool
    public let status: CapturedResponse.Status
    public let subagents: ConversationSubagents
}

public nonisolated struct ConversationSnapshot: Equatable, Sendable {
    public let epoch: String
    public let sequence: UInt64
    public let summary: ConversationSummary
    public let items: [ConversationItem]
}

/// An in-memory admission/eviction boundary for already reconciled transcripts.
/// It performs no disk I/O, reads no credentials and does not infer request
/// class or deduplicate by text. A caller must serialize access (e.g. one
/// recorder event loop), reconcile request/response identities, and separately
/// budget in-flight bodies, parsers and queued subscriber writes.
///
/// Accounting includes UTF-8 payloads plus conservative per-object allowances;
/// it is not a strict allocator/RSS bound. Counts independently bound empty
/// messages/objects. Reads do not change eviction order: oldest *updated*
/// conversations are evicted first. A repeat of the same snapshot is a no-op.
public nonisolated struct ConversationStore: Sendable {
    public struct Limits: Sendable {
        public let conversationBytes: Int
        public let totalBytes: Int
        public let conversations: Int
        public let itemsPerConversation: Int

        /// Trusted process configuration, not values from an RPC request.
        /// Lower limits allow small deterministic resource-bound tests.
        public init(conversationBytes: Int = ConversationCaptureLimits.conversation,
                    totalBytes: Int = ConversationCaptureLimits.allConversations,
                    conversations: Int = 256, itemsPerConversation: Int = 4_096) {
            precondition(conversationBytes > 0 && conversationBytes <= ConversationCaptureLimits.conversation)
            precondition(totalBytes >= conversationBytes && totalBytes <= ConversationCaptureLimits.allConversations)
            precondition(conversations > 0 && conversations <= 256)
            precondition(itemsPerConversation > 0 && itemsPerConversation <= 4_096)
            self.conversationBytes = conversationBytes; self.totalBytes = totalBytes
            self.conversations = conversations; self.itemsPerConversation = itemsPerConversation
        }
    }

    public enum Failure: Error, Equatable { case invalidItems, tooManyIncomingItems, metadataExceedsLimit }
    public struct Update: Equatable, Sendable {
        public let conversationID: String
        public let changed: Bool
        public let evictedConversationIDs: [String]
        public let discardedItemCount: Int
    }
    private struct Entry: Sendable {
        let id: String
        let key: ConversationKey
        let context: ConversationContext
        var revision: UInt64
        let historyRevision: UInt64
        let items: [ConversationItem]
        let truncated: Bool
        let status: CapturedResponse.Status
        let subagents: ConversationSubagents
        let cost: Int

        var summary: ConversationSummary {
            ConversationSummary(id: id, key: key, context: context, revision: revision,
                                historyRevision: historyRevision, itemCount: items.count, truncated: truncated, status: status, subagents: subagents)
        }
    }

    public let limits: Limits
    public private(set) var epoch = UUID().uuidString
    public private(set) var sequence: UInt64 = 0
    public private(set) var accountedBytes = 0
    private var entries: [ConversationKey: Entry] = [:]
    private var keysByID: [String: ConversationKey] = [:]

    public init(limits: Limits = Limits()) { self.limits = limits }
    public var count: Int { entries.count }

    /// Summaries only: listing conversations must not materialize every body.
    public func list() -> [ConversationSummary] {
        entries.values.sorted { $0.revision > $1.revision }.map(\.summary)
    }

    public func read(id: String) -> ConversationSnapshot? {
        guard let key = keysByID[id], let entry = entries[key] else { return nil }
        return ConversationSnapshot(epoch: epoch, sequence: sequence, summary: entry.summary, items: entry.items)
    }

    public func read(key: ConversationKey) -> ConversationSnapshot? {
        guard let entry = entries[key] else { return nil }
        return read(id: entry.id)
    }

    /// Admission pressure may evict retained history before accepting another
    /// in-flight capture. Deletion advances the cursor; rollover resets epoch.
    public mutating func evictOldest() -> [String] {
        guard let victim = entries.values.min(by: { $0.revision < $1.revision }) else { return [] }
        if sequence == .max {
            let ids = entries.values.map(\.id)
            entries.removeAll(); keysByID.removeAll(); accountedBytes = 0
            sequence = 0; epoch = UUID().uuidString
            return ids
        }
        entries.removeValue(forKey: victim.key); keysByID.removeValue(forKey: victim.id)
        accountedBytes -= victim.cost; sequence += 1
        return [victim.id]
    }

    private static func valid(_ message: CapturedMessage) -> Bool {
        guard !message.blocks.isEmpty, message.blocks.count <= 64 else { return false }
        let cap = message.role == .assistant ? ConversationCaptureLimits.assistantText :
            (message.role == .tool ? ConversationCaptureLimits.toolText : ConversationCaptureLimits.userText)
        var bytes = 0
        for block in message.blocks {
            guard block.text.utf8.count <= cap - bytes else { return false }
            bytes += block.text.utf8.count
            if let id = block.callID, RequestProjection.identifier(id) == nil { return false }
            if let name = block.toolName, RequestProjection.identifier(name) == nil { return false }
            if block.kind == .toolCall || block.kind == .toolResult {
                guard block.callID != nil, block.text.utf8.count <= ConversationCaptureLimits.toolText else { return false }
            }
            if block.kind == .toolCall && block.toolName == nil { return false }
            if block.kind == .image && !block.text.isEmpty { return false }
        }
        return true
    }

    /// Replace a reconciled transcript atomically. Invalid input cannot evict
    /// other conversations or alter a previous snapshot. Keep the most recent
    /// items when a count/byte limit is reached, with explicit truncation.
    public mutating func upsert(key: ConversationKey, context: ConversationContext,
                                items: [ConversationItem], status: CapturedResponse.Status,
                                historyTruncated: Bool = false, subagents: ConversationSubagents? = nil) throws -> Update {
        guard items.count <= 16_384 else { throw Failure.tooManyIncomingItems }
        var seen = Set<String>()
        for item in items {
            if case .subagent(let child, let depth) = item.origin {
                guard RequestProjection.identifier(child) != nil, depth.map({ (1...16).contains($0) }) ?? true,
                      item.message.role == .assistant,
                      item.message.blocks.reduce(0, { $0 + $1.text.utf8.count }) <= ConversationCaptureLimits.toolText else { throw Failure.invalidItems }
            }
            guard RequestProjection.identifier(item.id) != nil, seen.insert(item.id).inserted,
                  Self.valid(item.message) else { throw Failure.invalidItems }
        }
        let base = 1_024 + key.agent.utf8.count + key.herdrSession.utf8.count + key.nativeSession.utf8.count
            + context.routeID.utf8.count + context.paneID.utf8.count + context.terminalID.utf8.count
        guard base <= limits.conversationBytes else { throw Failure.metadataExceedsLimit }
        var start = max(0, items.count - limits.itemsPerConversation)
        var cost = base + items[start...].reduce(0) { $0 + $1.cost }
        while cost > limits.conversationBytes, start < items.count {
            cost -= items[start].cost
            start += 1
        }
        let retained = Array(items[start...])
        let old = entries[key]
        let childStats = subagents ?? old?.subagents ?? ConversationSubagents()
        guard childStats.valid else { throw Failure.invalidItems }
        let truncated = historyTruncated || start > 0 || retained.contains(where: { $0.message.truncated }) || old?.truncated == true
        if let old, old.context == context, old.items == retained, old.status == status, old.truncated == truncated, old.subagents == childStats {
            return Update(conversationID: old.id, changed: false, evictedConversationIDs: [], discardedItemCount: start)
        }
        var evicted: [String] = []
        // Epoch rollover prevents a cursor from silently wrapping. Normal
        // restarts create a new store/epoch; no snapshot is loaded from disk.
        if sequence == .max {
            evicted = entries.values.map(\.id)
            entries.removeAll(); keysByID.removeAll(); accountedBytes = 0
            sequence = 0; epoch = UUID().uuidString
        }
        let id = entries[key]?.id ?? UUID().uuidString
        if let previous = entries.removeValue(forKey: key) {
            keysByID.removeValue(forKey: previous.id)
            accountedBytes -= previous.cost
        }
        while entries.count >= limits.conversations || cost > limits.totalBytes - accountedBytes {
            guard let victim = entries.values.min(by: { $0.revision < $1.revision }) else { break }
            entries.removeValue(forKey: victim.key); keysByID.removeValue(forKey: victim.id)
            accountedBytes -= victim.cost; evicted.append(victim.id)
        }
        sequence += 1
        // Only appending or editing the same last item is a safe suffix delta.
        // Reconciliation/eviction elsewhere invalidates paged client history.
        let stablePrefix = old.map { previous in
            !previous.items.isEmpty && retained.count >= previous.items.count
                && previous.items.dropLast().elementsEqual(retained.prefix(previous.items.count - 1))
                && previous.items.last?.id == retained[previous.items.count - 1].id
        } ?? false
        let historyRevision = stablePrefix && old?.id == id ? old!.historyRevision : sequence
        let entry = Entry(id: id, key: key, context: context, revision: sequence,
                          historyRevision: historyRevision, items: retained, truncated: truncated, status: status, subagents: childStats, cost: cost)
        entries[key] = entry; keysByID[id] = key; accountedBytes += cost
        return Update(conversationID: id, changed: true, evictedConversationIDs: evicted, discardedItemCount: start)
    }

    /// Exports only already-admitted normalized entries. The envelope contains
    /// no live epoch, read cursor, reconciliation ticket/owner, parser, or
    /// compaction/subagent-correlation state.
    public func persistenceSnapshot() -> PersistentSnapshot {
        PersistentSnapshot(records: entries.values.sorted { $0.revision < $1.revision }.map(Self.persistentRecord))
    }

    /// Export one admitted record without materializing other bodies.
    public func persistenceRecord(id: String) -> PersistentSnapshot.Record? {
        guard let key = keysByID[id], let entry = entries[key] else { return nil }
        return Self.persistentRecord(entry)
    }

    private static func persistentRecord(_ entry: Entry) -> PersistentSnapshot.Record {
            PersistentSnapshot.Record(
                id: entry.id,
                key: .init(agent: entry.key.agent, herdrSession: entry.key.herdrSession, nativeSession: entry.key.nativeSession),
                context: .init(routeID: entry.context.routeID, paneID: entry.context.paneID, terminalID: entry.context.terminalID),
                updatedOrder: entry.revision,
                items: entry.items.map(Self.persistentItem),
                truncated: entry.truncated,
                status: Self.persistentStatus(entry.status),
                subagents: .init(observed: entry.subagents.observed, withFinalResult: entry.subagents.withFinalResult,
                                 limited: entry.subagents.limited, linkAvailable: entry.subagents.linkAvailable,
                                 ancestryIncomplete: entry.subagents.ancestryIncomplete)
            )
    }

    /// The host rechecks current authority. Existing live entries and their
    /// owners must never be replaced or evicted by an asynchronous import.
    @discardableResult
    public mutating func restoreOne(_ record: PersistentSnapshot.Record) -> String? {
        guard let value = Self.persistenceEntry(record), entries[value.key] == nil else { return nil }
        var trial = self
        guard let update = try? trial.upsert(key: value.key, context: value.context, items: value.items,
                                             status: value.status, historyTruncated: value.truncated,
                                             subagents: value.subagents),
              update.discardedItemCount == 0, update.evictedConversationIDs.isEmpty else { return nil }
        self = trial
        return update.conversationID
    }

    /// Rebuilds this store as a fresh recorder epoch. Persistent IDs are
    /// validated but deliberately replaced; `RestoreResult.restoredIDs` uses
    /// UTF-8-byte-exact persistent-ID keys and is the only mapping a filesystem
    /// coordinator may retain. Every streaming item
    /// and summary is downgraded to incomplete before normal store admission.
    /// Route/session authorization remains the caller's responsibility.
    @discardableResult
    public mutating func restore(_ snapshot: PersistentSnapshot) throws -> RestoreResult {
        try snapshot.validateEnvelope()
        let ordered = snapshot.records.enumerated().sorted {
            $0.element.updatedOrder == $1.element.updatedOrder ? $0.offset < $1.offset : $0.element.updatedOrder < $1.element.updatedOrder
        }
        var rejected = Set<Int>()
        var parsed: [(index: Int, record: PersistentSnapshot.Record, value: PersistenceEntry)] = []
        for pair in ordered {
            guard let value = Self.persistenceEntry(pair.element) else { rejected.insert(pair.offset); continue }
            parsed.append((pair.offset, pair.element, value))
        }

        func rejectDuplicates<Key: Hashable>(_ values: [(Int, Key)]) {
            var indexes: [Key: [Int]] = [:]
            for (index, value) in values { indexes[value, default: []].append(index) }
            for duplicates in indexes.values where duplicates.count > 1 { rejected.formUnion(duplicates) }
        }
        rejectDuplicates(parsed.map { ($0.index, Data($0.record.id.utf8)) })
        rejectDuplicates(parsed.map { ($0.index, $0.record.updatedOrder) })
        rejectDuplicates(parsed.map { ($0.index, $0.value.key) })

        // Build separately so a rejected record cannot alter the previous live
        // store or evict a valid candidate halfway through its own admission.
        var rebuilt = ConversationStore(limits: limits)
        var persistentByLiveID: [String: Data] = [:]
        var evictedPersistentIDs: [Data] = []
        for candidate in parsed where !rejected.contains(candidate.index) {
            var trial = rebuilt
            do {
                let update = try trial.upsert(key: candidate.value.key, context: candidate.value.context,
                                              items: candidate.value.items, status: candidate.value.status,
                                              historyTruncated: candidate.value.truncated,
                                              subagents: candidate.value.subagents)
                // A snapshot record must already fit its per-conversation
                // bound. Normal live upserts may trim; restore must reject that
                // source record without committing its trial evictions.
                guard update.discardedItemCount == 0 else { rejected.insert(candidate.index); continue }
                rebuilt = trial
                for id in update.evictedConversationIDs {
                    if let persistentID = persistentByLiveID.removeValue(forKey: id) { evictedPersistentIDs.append(persistentID) }
                }
                persistentByLiveID[update.conversationID] = Data(candidate.record.id.utf8)
            } catch {
                rejected.insert(candidate.index)
            }
        }
        self = rebuilt

        var reportedRejected = Set<Data>()
        let rejectedIDs = snapshot.records.enumerated().compactMap { index, record -> Data? in
            let id = Data(record.id.utf8)
            guard rejected.contains(index), RequestProjection.identifier(record.id) != nil,
                  reportedRejected.insert(id).inserted else { return nil }
            return id
        }
        let restoredIDs = Dictionary(uniqueKeysWithValues: persistentByLiveID.map { ($0.value, $0.key) })
        return RestoreResult(restoredIDs: restoredIDs, rejectedPersistentIDs: rejectedIDs,
                             rejectedRecordCount: rejected.count, evictedPersistentIDs: evictedPersistentIDs)
    }

    private struct PersistenceEntry {
        let key: ConversationKey
        let context: ConversationContext
        let items: [ConversationItem]
        let truncated: Bool
        let status: CapturedResponse.Status
        let subagents: ConversationSubagents
    }

    private static func persistenceEntry(_ record: PersistentSnapshot.Record) -> PersistenceEntry? {
        guard RequestProjection.identifier(record.id) != nil, record.updatedOrder > 0,
              record.items.count <= 4_096,
              let key = ConversationKey(agent: record.key.agent, herdrSession: record.key.herdrSession,
                                        nativeSession: record.key.nativeSession),
              let context = ConversationContext(routeID: record.context.routeID, paneID: record.context.paneID,
                                                terminalID: record.context.terminalID),
              let status = responseStatus(record.status) else { return nil }
        let subagents = ConversationSubagents(observed: record.subagents.observed,
                                               withFinalResult: record.subagents.withFinalResult,
                                               limited: record.subagents.limited,
                                               linkAvailable: record.subagents.linkAvailable,
                                               ancestryIncomplete: record.subagents.ancestryIncomplete)
        guard subagents.valid else { return nil }
        var items: [ConversationItem] = []
        items.reserveCapacity(record.items.count)
        for persisted in record.items {
            guard RequestProjection.identifier(persisted.id) != nil,
                  let role = CapturedMessage.Role(rawValue: persisted.message.role),
                  persisted.message.blocks.count <= 64,
                  let itemStatus = responseStatus(persisted.status),
                  let origin = conversationOrigin(persisted.origin) else { return nil }
            var blocks: [CapturedBlock] = []
            blocks.reserveCapacity(persisted.message.blocks.count)
            for block in persisted.message.blocks {
                guard let kind = CapturedBlock.Kind(rawValue: block.kind) else { return nil }
                blocks.append(CapturedBlock(kind: kind, text: block.text, callID: block.callID, toolName: block.toolName))
            }
            let message = CapturedMessage(role: role, blocks: blocks, truncated: persisted.message.truncated)
            items.append(ConversationItem(id: persisted.id, message: message, origin: origin,
                                          status: itemStatus == .streaming ? .incomplete : itemStatus))
        }
        return PersistenceEntry(key: key, context: context, items: items, truncated: record.truncated,
                                status: status == .streaming ? .incomplete : status, subagents: subagents)
    }

    private static func persistentItem(_ item: ConversationItem) -> PersistentSnapshot.Item {
        PersistentSnapshot.Item(
            id: item.id,
            message: .init(role: item.message.role.rawValue,
                           blocks: item.message.blocks.map { .init(kind: $0.kind.rawValue, text: $0.text, callID: $0.callID, toolName: $0.toolName) },
                           truncated: item.message.truncated),
            origin: persistentOrigin(item.origin), status: persistentStatus(item.status)
        )
    }

    private static func persistentOrigin(_ origin: ConversationItem.Origin) -> PersistentSnapshot.Origin {
        switch origin {
        case .reconstructed: return .init(kind: "reconstructed")
        case .observed: return .init(kind: "observed")
        case .response: return .init(kind: "response")
        case .summary: return .init(kind: "summary")
        case .discontinuity: return .init(kind: "discontinuity")
        case .compaction(let availability): return .init(kind: "compaction", compactionAvailability: compactionAvailabilityName(availability))
        case .subagent(let id, let depth): return .init(kind: "subagent", subagentID: id, subagentDepth: depth)
        }
    }

    private static func conversationOrigin(_ origin: PersistentSnapshot.Origin) -> ConversationItem.Origin? {
        switch origin.kind {
        case "reconstructed" where origin.compactionAvailability == nil && origin.subagentID == nil && origin.subagentDepth == nil: return .reconstructed
        case "observed" where origin.compactionAvailability == nil && origin.subagentID == nil && origin.subagentDepth == nil: return .observed
        case "response" where origin.compactionAvailability == nil && origin.subagentID == nil && origin.subagentDepth == nil: return .response
        case "summary" where origin.compactionAvailability == nil && origin.subagentID == nil && origin.subagentDepth == nil: return .summary
        case "discontinuity" where origin.compactionAvailability == nil && origin.subagentID == nil && origin.subagentDepth == nil: return .discontinuity
        case "compaction" where origin.subagentID == nil && origin.subagentDepth == nil:
            guard let value = origin.compactionAvailability, let availability = compactionAvailability(value) else { return nil }
            return .compaction(availability)
        case "subagent" where origin.compactionAvailability == nil:
            guard let id = origin.subagentID else { return nil }
            return .subagent(id: id, depth: origin.subagentDepth)
        default: return nil
        }
    }

    private static func persistentStatus(_ status: CapturedResponse.Status) -> String {
        switch status { case .streaming: return "streaming"; case .complete: return "complete"; case .incomplete: return "incomplete" }
    }

    private static func responseStatus(_ value: String) -> CapturedResponse.Status? {
        switch value { case "streaming": return .streaming; case "complete": return .complete; case "incomplete": return .incomplete; default: return nil }
    }

    private static func compactionAvailabilityName(_ value: CapturedCompaction.Availability) -> String {
        switch value { case .plaintext: return "plaintext"; case .opaque: return "opaque"; case .noText: return "noText"; case .incomplete: return "incomplete" }
    }

    private static func compactionAvailability(_ value: String) -> CapturedCompaction.Availability? {
        switch value { case "plaintext": return .plaintext; case "opaque": return .opaque; case "noText": return .noText; case "incomplete": return .incomplete; default: return nil }
    }
}
