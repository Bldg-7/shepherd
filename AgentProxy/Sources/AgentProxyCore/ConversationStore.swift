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
    public enum Origin: Sendable { case reconstructed, observed, response, summary, discontinuity }
    /// Stable ID supplied by the reconciler, never inferred from text equality.
    public let id: String
    public let message: CapturedMessage
    public let origin: Origin
    public let status: CapturedResponse.Status

    public init(id: String, message: CapturedMessage, origin: Origin, status: CapturedResponse.Status) {
        self.id = id; self.message = message; self.origin = origin; self.status = status
    }

    var cost: Int { 128 + id.utf8.count + message.cost }
}

public nonisolated struct ConversationSummary: Equatable, Sendable {
    public let id: String
    public let key: ConversationKey
    public let context: ConversationContext
    public let revision: UInt64
    public let itemCount: Int
    public let truncated: Bool
    public let status: CapturedResponse.Status
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
        let items: [ConversationItem]
        let truncated: Bool
        let status: CapturedResponse.Status
        let cost: Int

        var summary: ConversationSummary {
            ConversationSummary(id: id, key: key, context: context, revision: revision,
                                itemCount: items.count, truncated: truncated, status: status)
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
                                historyTruncated: Bool = false) throws -> Update {
        guard items.count <= 16_384 else { throw Failure.tooManyIncomingItems }
        var seen = Set<String>()
        for item in items {
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
        let truncated = historyTruncated || start > 0 || retained.contains(where: { $0.message.truncated }) || old?.truncated == true
        if let old, old.context == context, old.items == retained, old.status == status, old.truncated == truncated {
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
        let entry = Entry(id: id, key: key, context: context, revision: sequence,
                          items: retained, truncated: truncated, status: status, cost: cost)
        entries[key] = entry; keysByID[id] = key; accountedBytes += cost
        return Update(conversationID: id, changed: true, evictedConversationIDs: evicted, discardedItemCount: start)
    }
}
