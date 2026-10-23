import Foundation
import AgentProxyCore

struct ConversationReadAPITests {
    static func call(_ method: String, _ params: [String: Any] = [:], store: ConversationStore) throws -> ConversationReadAPI.Reply {
        let line = try JSONSerialization.data(withJSONObject: ["id": "query", "method": method, "params": params])
        let data = ConversationReadAPI.answer(line, store: store)
        guard data.last == 10, data.count <= ConversationReadAPI.maximumReplyBytes else { throw TestFailure.invalid }
        return try JSONDecoder().decode(ConversationReadAPI.Reply.self, from: data)
    }
    enum TestFailure: Error { case invalid }
    static func run(check: (Bool, String) -> Void) throws {
        var core = ConversationReconciler()
        let owner = ConversationOwnerTests.claude()
        let request = try ConversationReconcilerTests.request((0..<40).map { ConversationReconcilerTests.message("user", "item-\($0)") })
        let begin = try core.beginMain(classification: owner, request: request)
        _ = try core.apply(ConversationReconcilerTests.response("answer"), ticket: begin.ticket, finished: true)
        let id = begin.ticket.conversationID
        let list = try call("conversations.list", store: core.store)
        check(list.id == "query" && list.error == nil && list.result?.protocolVersion == 1, "versioned read response echoes bounded request id")
        check(list.result?.conversations?.map(\.id) == [id] && list.result?.items == nil, "list exposes summaries without bodies")
        let first = try call("conversation.read", ["conversationID": id, "limit": 8], store: core.store).result!
        check(first.items?.count == 8 && first.items?.last?.blocks.first?.text == "answer", "read begins at latest bounded page")
        let previous = try call("conversation.read", ["conversationID": id, "beforeItemID": first.nextBeforeItemID!, "limit": 8, "epoch": first.epoch], store: core.store).result!
        check(previous.items?.count == 8 && Set(first.items!.map(\.id)).isDisjoint(with: previous.items!.map(\.id)), "stable before-item pagination neither duplicates nor guesses offsets")
        let full = try call("conversation.read", ["conversationID": id, "limit": 64], store: core.store).result!
        check(full.items?.count == 41 && full.nextBeforeItemID == nil, "oldest retained page has no continuation")
        let missing = try call("conversation.read", ["conversationID": "missing"], store: core.store).result!
        check(missing.reset && missing.reason == "not_found" && missing.items == nil, "evicted/missing conversation explicitly resets")
        let stale = try call("conversation.read", ["conversationID": id, "epoch": "old"], store: core.store).result!
        check(stale.reset && stale.reason == "epoch_changed", "old recorder epoch cannot read a guessed continuation")
        let anchor = try call("conversation.read", ["conversationID": id, "beforeItemID": "removed"], store: core.store).result!
        check(anchor.reset && anchor.reason == "anchor_removed", "removed anchor does not silently become an offset")
        for params: [String: Any] in [[:], ["conversationID": id, "limit": 0], ["conversationID": id, "limit": 65], ["conversationID": id, "limit": true], ["conversationID": "bad\n"]] {
            check(try call("conversation.read", params, store: core.store).error != nil, "invalid read parameters fail without mutation")
        }
        check(try call("routes.create", store: core.store).error?.code == "unknown_method", "read API cannot mutate routes or state")
        check(try call("conversations.list", ["terminalID": "wrong"], store: core.store).result?.conversations?.isEmpty == true, "terminal filter is applied")
        check(try call("conversations.list", ["herdrSession": "wrong"], store: core.store).result?.conversations?.isEmpty == true, "herdr namespace filter is applied")
        check(try call("conversations.list", ["nativeSession": "native", "agent": "claude"], store: core.store).result?.conversations?.count == 1, "native session and agent filters")
        let compact = core.beginCompaction(classification: ConversationOwnerTests.claude("compaction"))!
        _ = try core.completeCompaction(ConversationReconcilerTests.response("summary"), ticket: compact, transportComplete: true)
        let summaryPage = try call("conversation.read", ["conversationID": id], store: core.store).result!
        check(summaryPage.items?.dropLast().last?.origin == "compaction" && summaryPage.items?.dropLast().last?.compaction == "plaintext", "compaction boundary retains typed rendering information")
        check(summaryPage.items?.last?.origin == "summary", "summary is not mislabeled as ordinary assistant response")
        var unicode = ConversationReconciler()
        for native in ["\u{E9}", "e\u{301}"] {
            _ = try unicode.beginMain(classification: ConversationOwnerTests.claude(native: native), request: request)
        }
        let exact = try call("conversations.list", ["nativeSession": "\u{E9}"], store: unicode.store).result!
        check(exact.conversations?.count == 1 && exact.conversations?.first?.nativeSession.utf8.elementsEqual("\u{E9}".utf8) == true, "query filters preserve byte-exact native identity")
        let large = ConversationReconcilerTests.message("user", String(repeating: "x", count: 60_000))
        var pages = ConversationReconciler()
        let big = try pages.beginMain(classification: owner, request: ConversationReconcilerTests.request(Array(repeating: large, count: 20)))
        let page = try call("conversation.read", ["conversationID": big.ticket.conversationID, "limit": 64], store: pages.store).result!
        check(page.items!.count < 20 && page.nextBeforeItemID != nil, "payload budget limits page even below item-count maximum")
        var escaping = ConversationReconciler()
        let start = try escaping.beginMain(classification: owner, request: request)
        let controlText = AnthropicResponseTests.Stream(); try controlText.start()
        try controlText.block(0, ["type": "text", "text": ""])
        for _ in 0..<64 { try controlText.delta(0, ["type": "text_delta", "text": String(repeating: "\u{1}", count: 4096)]) }
        try controlText.stop(0); try controlText.complete()
        _ = try escaping.apply(controlText.assembly.snapshot, ticket: start.ticket, finished: true)
        let escaped = try call("conversation.read", ["conversationID": start.ticket.conversationID], store: escaping.store).result!
        check(escaped.items?.count == 1 && escaped.items?.first?.blocks.first?.text.utf8.count == ConversationCaptureLimits.assistantText, "single maximum item survives worst-case JSON escaping within encoded reply cap")
        for data in [Data("not JSON".utf8), Data(repeating: 65, count: ConversationReadAPI.maximumRequestBytes + 1),
                     Data("{\"id\":\"bad\\n\",\"method\":\"conversations.list\"}".utf8)] {
            let response = ConversationReadAPI.answer(data, store: core.store)
            let reply = try JSONDecoder().decode(ConversationReadAPI.Reply.self, from: response)
            check(reply.error != nil && reply.id == nil && response.count < 512, "malformed input returns bounded static error without reflecting content")
        }
        let empty = try call("conversations.list", store: ConversationStore()).result!
        check(empty.conversations?.isEmpty == true && !empty.reset, "fresh recorder has a valid empty list and fresh epoch")
    }
}
