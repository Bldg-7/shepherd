import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct ConversationSubscriptionTests {
    static func run(check: (Bool, String) -> Void) throws {
        let key = ConversationKey(agent: "claude", herdrSession: "s", nativeSession: "n")!
        let context = ConversationContext(routeID: "r", paneID: "p", terminalID: "t")!
        func item(_ id: String, _ text: String = "text") throws -> ConversationItem {
            let message = try RequestProjection.project(JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": text]]]), provider: .anthropic).messages[0]
            return ConversationItem(id: id, message: message, origin: .observed, status: .complete)
        }
        var store = ConversationStore()
        let first = try item("first"), last = try item("last")
        let id = try store.upsert(key: key, context: context, items: [first, last], status: .streaming).conversationID
        let initial = try ConversationReadAPITests.call("conversation.subscribe", ["conversationID": id], store: store).result!
        let cursor = ConversationReadAPI.Cursor(initial)!
        check(ConversationReadAPI.update(after: cursor, store: store) == nil, "unchanged subscription emits nothing")
        _ = try store.upsert(key: key, context: context, items: [first, item("last", "edited"), item("append")], status: .streaming)
        let patch = ConversationReadAPI.update(after: cursor, store: store)!
        check(!patch.reset && patch.replaceFromItemID == "last" && patch.items?.map(\.id) == ["last", "append"], "live edit plus append replaces only known suffix")
        check(patch.baseSeq == cursor.seq && patch.seq > cursor.seq && patch.summary?.historyRevision == cursor.historyRevision, "patch binds base cursor and immutable history generation")
        let patchCursor = ConversationReadAPI.Cursor(patch)!
        _ = try store.upsert(key: key, context: context, items: [item("first", "changed old content"), item("last", "edited"), item("append")], status: .streaming)
        let reset = ConversationReadAPI.update(after: patchCursor, store: store)!
        check(reset.reset && reset.reason == "history_changed" && reset.summary!.historyRevision > patchCursor.historyRevision, "older history mutation resets paged client state")
        let resetCursor = ConversationReadAPI.Cursor(reset)!
        _ = try store.upsert(key: key, context: context, items: [item("first", "changed old content"), item("last", "edited"), item("differentID")], status: .complete)
        check(ConversationReadAPI.update(after: resetCursor, store: store)?.reset == true, "replaced final item ID cannot masquerade as suffix update")
        let c = ConversationReadAPI.Cursor(try ConversationReadAPITests.call("conversation.subscribe", ["conversationID": id], store: store).result!)!
        var many = store.read(id: id)!.items
        many += try (0..<70).map { try item("new\($0)") }
        _ = try store.upsert(key: key, context: context, items: many, status: .complete)
        let bounded = ConversationReadAPI.update(after: c, store: store)!
        check(bounded.reset && bounded.items?.count == 16 && bounded.nextBeforeItemID != nil, "large coalesced burst resets to bounded latest window")
        check(ConversationReadAPI.encodeUpdate(bounded).count < ConversationReadAPI.maximumReplyBytes, "notification encoding remains bounded")
        let cursorBeforeEviction = ConversationReadAPI.Cursor(bounded)!
        _ = store.evictOldest()
        check(ConversationReadAPI.update(after: cursorBeforeEviction, store: store)?.reason == "not_found", "evicted conversation produces terminal reset")
        check(ConversationReadAPI.update(after: cursorBeforeEviction, store: ConversationStore())?.reason == "epoch_changed", "new process epoch invalidates subscription")
        check(try ConversationReadAPITests.call("conversation.subscribe", ["conversationID": id, "beforeItemID": "first"], store: store).error != nil, "subscription cannot start from ambiguous historical page")

        let small = ConversationCapture(limits: .init(totalBytes: 100_000, fixedBytes: 1_000, workingBytes: 10_000))
        let token = small.reserve(bytes: 90_000)!
        check(small.accountedBytes == 91_000 && small.reservedBytes == 90_000, "host reservations share the global capture budget")
        check(small.reserve(bytes: 10_000) == nil, "encoding/client admission rejects aggregate overflow")
        small.release(token); small.release(token)
        check(small.reservedBytes == 0 && small.accountedBytes == 1_000, "release is idempotent and reclaims reservation")
        check(small.reserve(bytes: 0) == nil && small.reserve(bytes: Int.max) == nil, "invalid trusted-host sizes cannot overflow accounting")
        let tokens = (0..<32).compactMap { _ in small.reserve(bytes: 1) }
        check(tokens.count == 32 && small.reserve(bytes: 1) == nil, "reservation token count is independently bounded")
        tokens.forEach(small.release)
        let active = ConversationCaptureTests.Harness()
        let authority1 = active.capture.reserve(bytes: 8 << 20)!
        let authority2 = active.capture.reserve(bytes: 8 << 20)!
        try active.open(1); try active.request(1)
        let record = active.capture.reserve(bytes: 8 << 20)!
        let save = active.capture.reserve(bytes: 64 << 20)!
        let liveID = active.snapshot!.summary.id
        check(active.capture.accountedBytes > 124 << 20 && active.capture.accountedBytes < 128 << 20, "active capture and save reservations reproduce read pressure")
        check(active.capture.reserve(bytes: 4 << 20) == nil, "read reservation fails closed under active capture pressure")
        check(active.capture.activeExchangeCount == 1 && active.snapshot?.summary.id == liveID && active.capture.drops[.evicted] == nil, "host reservation cannot evict an active conversation")
        active.capture.release(save)
        let reader = active.capture.reserve(bytes: 4 << 20)
        let query = active.capture.reserve(bytes: 8 << 20)
        check(reader != nil && query != nil && active.capture.accountedBytes <= active.capture.limits.totalBytes, "read admission progresses after save workspace is released")
        if let reader { active.capture.release(reader) }
        if let query { active.capture.release(query) }
        active.capture.release(record); active.capture.release(authority1); active.capture.release(authority2)
        try active.head(1); try active.answer(1, "still alive"); try active.end(1)
        check(active.snapshot?.summary.id == liveID && active.snapshot?.items.last?.message.blocks.first?.text == "still alive", "active response remains capturable after refused reservation")

        let mixed = ConversationCaptureTests.Harness(small)
        try mixed.open(1, native: "old"); try mixed.request(1); try mixed.head(1); try mixed.answer(1, "old"); try mixed.end(1)
        try mixed.open(2, native: "live"); try mixed.request(2)
        let beforeIDs = Set(mixed.capture.reconciler.store.list().map(\.id))
        let beforeBytes = mixed.capture.accountedBytes
        check(beforeIDs.count == 2 && mixed.capture.activeExchangeCount == 1, "mixed history and live conversation established")
        check(mixed.capture.reserve(bytes: 99_000) == nil && mixed.capture.accountedBytes == beforeBytes, "refused host admission does not mutate existing accounting")
        check(Set(mixed.capture.reconciler.store.list().map(\.id)) == beforeIDs && mixed.capture.activeExchangeCount == 1, "host pressure preserves both live and idle history during an exchange")
        try mixed.head(2); try mixed.answer(2, "new"); try mixed.end(2)

        let h = ConversationCaptureTests.Harness(small)
        try h.open(1); try h.request(1); try h.head(1); try h.answer(1, "answer"); try h.end(1)
        let pressure = small.reserve(bytes: 99_000)
        check(pressure != nil && small.reconciler.store.count == 0 && small.accountedBytes == 100_000, "reader admission evicts retained history rather than exceeding aggregate bound")
        small.release(pressure!)
        check(AgentProxyPaths.recorderSocket(forControlSocket: "/private/ap.sock") == "/private/ac.sock", "release read socket derived explicitly")
        check(AgentProxyPaths.recorderSocket(forControlSocket: "/private/ap-debug.sock") == "/private/ac-debug.sock", "debug read socket isolated")
        check(AgentProxyPaths.recorderSocket(forControlSocket: "/private/custom.sock") == "/private/custom.sock.ac", "custom path does not touch release listener")
    }
}
