import Foundation
import AgentProxyCore

/// Bounded UI history, independent of SwiftUI/SSH. Live patches cannot silently
/// cross recorder epochs, miss a sequence, replace an unknown suffix or amend
/// earlier paged history. On failure the caller discards/re-subscribes.
public nonisolated struct ConversationWindow: Sendable {
    public private(set) var epoch: String?
    public private(set) var seq: UInt64 = 0
    public private(set) var summary: ConversationHeader?
    public private(set) var items: [ConversationMessage] = []
    public private(set) var nextBeforeItemID: String?
    public private(set) var clientLimited = false
    public init() {}

    public mutating func apply(_ page: ConversationPage) throws {
        try ConversationWire.validate(page)
        guard let header = page.summary, let incoming = page.items else { throw ConversationClientError.reset }
        if let epoch {
            guard wireEqual(epoch, page.epoch), let summary, wireEqual(summary.id, header.id),
                  page.seq > seq, page.baseSeq == seq else { throw ConversationClientError.reset }
            if page.reset {
                items = incoming; nextBeforeItemID = page.nextBeforeItemID; clientLimited = false
            } else {
                guard summary.historyRevision == header.historyRevision, let anchor = page.replaceFromItemID,
                      let index = items.firstIndex(where: { wireEqual($0.id, anchor) }),
                      incoming.first.map({ wireEqual($0.id, anchor) }) == true else { throw ConversationClientError.reset }
                let candidate = Array(items.prefix(index)) + incoming
                guard Set(candidate.map { Data($0.id.utf8) }).count == candidate.count else { throw ConversationClientError.invalidReply }
                items = candidate
            }
        } else {
            guard page.baseSeq == nil, page.replaceFromItemID == nil else { throw ConversationClientError.reset }
            items = incoming; nextBeforeItemID = page.nextBeforeItemID
        }
        epoch = page.epoch; seq = page.seq; summary = header
        trim()
    }

    /// Paging does not advance the live stream's base sequence. Stable history
    /// generation proves this earlier page is compatible with live edits that
    /// arrived while the RPC was in flight.
    public mutating func prepend(_ page: ConversationPage, before: String) throws {
        try ConversationWire.validate(page)
        guard !page.reset, let epoch, wireEqual(epoch, page.epoch), let current = summary,
              let header = page.summary, wireEqual(current.id, header.id), current.historyRevision == header.historyRevision,
              let anchor = nextBeforeItemID, wireEqual(anchor, before), let older = page.items else { throw ConversationClientError.reset }
        let candidate = older + items
        guard Set(candidate.map { Data($0.id.utf8) }).count == candidate.count else { throw ConversationClientError.invalidReply }
        items = candidate; nextBeforeItemID = page.nextBeforeItemID
        trim()
    }

    public var accountedBytes: Int { 2048 + items.reduce(0) { $0 + Self.cost($1) } }
    private static func cost(_ item: ConversationMessage) -> Int {
        384 + item.id.utf8.count + (item.subagentID.map { $0.utf8.count + 32 } ?? 0) + item.blocks.reduce(0) {
            $0 + 256 + $1.text.utf8.count + ($1.callID?.utf8.count ?? 0) + ($1.toolName?.utf8.count ?? 0)
        }
    }
    private mutating func trim() {
        var bytes = accountedBytes, start = 0
        while start < items.count && (bytes > 4 << 20 || items.count - start > 4096) {
            bytes -= Self.cost(items[start]); start += 1
        }
        if start > 0 {
            items.removeFirst(start); clientLimited = true
            // Don't offer an endless 'load older' loop that re-fetches the
            // same page only to discard it at this client's memory bound.
            nextBeforeItemID = nil
        }
    }
}
