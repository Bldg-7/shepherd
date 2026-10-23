import Foundation
import AgentProxyCore

struct ConversationStoreTests {
    static func run(check: (Bool, String) -> Void) throws {
        func key(_ native: String, agent: String = "claude", session: String = "s") -> ConversationKey {
            ConversationKey(agent: agent, herdrSession: session, nativeSession: native)!
        }
        let context = ConversationContext(routeID: "route", paneID: "w:p", terminalID: "term")!
        func item(_ id: String, _ text: String = "value", role: String = "user") throws -> ConversationItem {
            let data = try JSONSerialization.data(withJSONObject: ["messages": [["role": role, "content": text]]])
            let message = try RequestProjection.project(data, provider: .anthropic).messages[0]
            return ConversationItem(id: id, message: message, origin: .observed, status: .complete)
        }
        check(ConversationKey(agent: "unknown", herdrSession: "s", nativeSession: "x") == nil, "unknown agent key rejected")
        check(ConversationKey(agent: "pi", herdrSession: "s", nativeSession: "") == nil, "empty native session rejected")
        check(ConversationKey(agent: "pi", herdrSession: "s", nativeSession: String(repeating: "x", count: 257)) == nil, "session metadata bounded")
        check(ConversationContext(routeID: "route\n", paneID: "p", terminalID: "t") == nil, "control characters rejected from context")
        var store = ConversationStore()
        let initialEpoch = store.epoch
        let firstItem = try item("i", "A")
        let first = try store.upsert(key: key("k"), context: context, items: [firstItem], status: .complete)
        check(store.count == 1 && store.sequence == 1 && first.changed && first.evictedConversationIDs.isEmpty, "first snapshot admitted")
        check(store.accountedBytes == 1_686, "known UTF8 and object accounting total")
        let snapshot = store.read(id: first.conversationID)!
        check(snapshot.epoch == initialEpoch && snapshot.items == [firstItem] && snapshot.summary.key == key("k"), "snapshot carries epoch, identity and items")
        check(store.list().map(\.id) == [first.conversationID] && store.list()[0].itemCount == 1, "listing contains summaries only")
        let unchanged = try store.upsert(key: key("k"), context: context, items: [firstItem], status: .complete)
        check(!unchanged.changed && store.sequence == 1 && store.accountedBytes == 1_686, "identical snapshot does not churn sequence or accounting")
        let moved = ConversationContext(routeID: "new-route", paneID: "w2:p2", terminalID: "new-terminal")!
        let resumed = try store.upsert(key: key("k"), context: moved, items: [firstItem], status: .streaming)
        check(resumed.conversationID == first.conversationID && store.sequence == 2 && store.read(key: key("k"))?.summary.context == moved, "native identity survives route/terminal changes")
        _ = try store.upsert(key: key("k", agent: "pi"), context: context, items: [firstItem], status: .complete)
        _ = try store.upsert(key: key("k", session: "other"), context: context, items: [firstItem], status: .complete)
        check(store.count == 3, "agent kind and herdr namespace keep native IDs separate")
        check(store.read(id: "missing") == nil, "unknown snapshot not fabricated")

        var byCount = ConversationStore(limits: .init(conversationBytes: 20_000, totalBytes: 60_000, conversations: 10, itemsPerConversation: 2))
        let three = try [item("one"), item("two"), item("three")]
        let limited = try byCount.upsert(key: key("count"), context: context, items: three, status: .complete)
        check(limited.discardedItemCount == 1 && byCount.read(id: limited.conversationID)?.items.map(\.id) == ["two", "three"], "count trimming retains newest items in order")
        check(byCount.read(id: limited.conversationID)?.summary.truncated == true, "history truncation explicit")
        let sameTail = try byCount.upsert(key: key("count"), context: context, items: Array(three.suffix(2)), status: .complete)
        check(!sameTail.changed && byCount.read(id: limited.conversationID)?.summary.truncated == true, "caller cannot accidentally clear known history truncation")

        var byBytes = ConversationStore(limits: .init(conversationBytes: 3_000, totalBytes: 6_000))
        let sized = try (0..<3).map { try item("i\($0)", String(repeating: "x", count: 100)) }
        let trimmed = try byBytes.upsert(key: key("bytes"), context: context, items: sized, status: .complete)
        check(trimmed.discardedItemCount == 1 && byBytes.read(id: trimmed.conversationID)?.items.map(\.id) == ["i1", "i2"], "per-conversation byte trimming removes oldest first")
        check(byBytes.accountedBytes <= 3_000, "per-conversation accounting bound")
        let tooLarge = try byBytes.upsert(key: key("bytes"), context: context, items: [item("big", String(repeating: "x", count: 10_000))], status: .complete)
        check(tooLarge.discardedItemCount == 1 && byBytes.read(id: tooLarge.conversationID)?.items.isEmpty == true, "single item larger than budget discarded explicitly")

        var probe = ConversationStore()
        _ = try probe.upsert(key: key("k0"), context: context, items: [firstItem], status: .complete)
        let oneCost = probe.accountedBytes
        var global = ConversationStore(limits: .init(conversationBytes: oneCost * 2, totalBytes: oneCost * 2, conversations: 10))
        let a = try global.upsert(key: key("k0"), context: context, items: [firstItem], status: .complete)
        let b = try global.upsert(key: key("k1"), context: context, items: [firstItem], status: .complete)
        check(global.accountedBytes == oneCost * 2 && global.count == 2, "exact global byte bound accepted")
        _ = global.read(id: a.conversationID)
        let c = try global.upsert(key: key("k2"), context: context, items: [firstItem], status: .complete)
        check(c.evictedConversationIDs == [a.conversationID] && global.read(id: a.conversationID) == nil, "oldest-updated eviction and stale ID removal; reads do not pin")
        check(global.read(id: b.conversationID) != nil && global.read(id: c.conversationID) != nil && global.accountedBytes == oneCost * 2, "other retained entries and accounting survive eviction")
        let growth = try global.upsert(key: key("k1"), context: context, items: [item("i", String(repeating: "z", count: 100))], status: .complete)
        check(growth.conversationID == b.conversationID && growth.evictedConversationIDs == [c.conversationID] && global.count == 1, "replacement removes old cost before enforcing aggregate bound")

        var emptyBound = ConversationStore(limits: .init(conversationBytes: 2_000, totalBytes: 20_000, conversations: 3))
        var ids: [String] = []
        for n in 0..<20 {
            let update = try emptyBound.upsert(key: key("empty-\(n)"), context: context, items: [], status: .streaming)
            ids.append(update.conversationID)
            check(emptyBound.count <= 3 && emptyBound.accountedBytes <= 20_000, "empty conversations bounded by count and accounting")
        }
        check(emptyBound.read(id: ids[0]) == nil && emptyBound.list().map(\.id) == Array(ids.suffix(3).reversed()), "eviction order deterministic by update revision")

        let before = store.list(); let sequence = store.sequence; let accounted = store.accountedBytes
        do {
            _ = try store.upsert(key: key("invalid"), context: context, items: [firstItem, firstItem], status: .complete)
            check(false, "duplicate item IDs must fail")
        } catch { check(error as? ConversationStore.Failure == .invalidItems, "duplicate item IDs rejected before mutation") }
        do {
            _ = try store.upsert(key: key("invalid"), context: context, items: [ConversationItem(id: "bad\n", message: firstItem.message, origin: .observed, status: .complete)], status: .complete)
            check(false, "invalid item ID must fail")
        } catch { check(error as? ConversationStore.Failure == .invalidItems, "invalid ID rejected") }
        do {
            _ = try store.upsert(key: key("invalid"), context: context, items: Array(repeating: firstItem, count: 16_385), status: .complete)
            check(false, "incoming item count must fail")
        } catch { check(error as? ConversationStore.Failure == .tooManyIncomingItems, "incoming validation work bounded") }
        check(store.list() == before && store.sequence == sequence && store.accountedBytes == accounted, "invalid updates leave state and eviction order unchanged")
        var metadata = ConversationStore(limits: .init(conversationBytes: 1_200, totalBytes: 2_400))
        let original = try metadata.upsert(key: key("k"), context: context, items: [], status: .streaming)
        let originalSnapshot = metadata.read(id: original.conversationID)
        let long = String(repeating: "x", count: 256)
        do {
            _ = try metadata.upsert(key: key("k"), context: ConversationContext(routeID: long, paneID: long, terminalID: long)!, items: [], status: .complete)
            check(false, "metadata alone cannot exceed budget")
        } catch { check(error as? ConversationStore.Failure == .metadataExceedsLimit, "metadata budget checked before eviction") }
        check(metadata.read(id: original.conversationID) == originalSnapshot, "rejected metadata preserves prior snapshot")
        var contentLoss = ConversationStore()
        let clipped = try contentLoss.upsert(key: key("clipped"), context: context,
                                            items: [item("clipped", String(repeating: "x", count: 100_000))], status: .complete)
        check(contentLoss.read(id: clipped.conversationID)?.summary.truncated == true, "message-level clipping propagates to conversation summary")
        let fresh = ConversationStore()
        check(fresh.epoch != initialEpoch && fresh.count == 0 && fresh.accountedBytes == 0 && fresh.sequence == 0, "new recorder store starts empty with a new epoch")
    }
}
