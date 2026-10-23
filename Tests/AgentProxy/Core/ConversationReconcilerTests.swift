import Foundation
import AgentProxyCore

struct ConversationReconcilerTests {
    static func request(_ messages: [[String: Any]], previous: String? = nil, responses: Bool = false) throws -> CapturedRequest {
        var object: [String: Any] = [responses ? "input" : "messages": messages]
        if let previous { object["previous_response_id"] = previous }
        return try RequestProjection.project(JSONSerialization.data(withJSONObject: object), provider: responses ? .responses : .anthropic)
    }
    static func message(_ role: String, _ text: String) -> [String: Any] { ["role": role, "content": text] }
    static func response(_ text: String, id: String = "resp", finished: Bool = true) throws -> CapturedResponse {
        let stream = ResponsesAssemblyTests.Stream()
        try stream.send(["type": "response.created", "response": ["id": id]])
        try stream.item(0, ResponsesAssemblyTests.message("msg", text))
        if finished {
            try stream.send(["type": "response.completed", "response": ["id": id, "status": "completed", "output": [ResponsesAssemblyTests.message("msg", text)]]])
            stream.assembly.finish(transportComplete: true)
        }
        return stream.assembly.snapshot
    }
    static func texts(_ snapshot: ConversationSnapshot?) -> [String] {
        snapshot?.items.filter { $0.origin != .discontinuity }.map { $0.message.blocks.map(\.text).joined() } ?? []
    }

    static func run(check: (Bool, String) -> Void) throws {
        let key = ConversationKey(agent: "claude", herdrSession: "s", nativeSession: "native")!
        let context = ConversationContext(routeID: "r", paneID: "p", terminalID: "t")!
        let firstRequest = try request([message("user", "continue")])
        var core = ConversationReconciler()
        let first = try core.beginMain(key: key, context: context, request: firstRequest)
        check(!first.isRetry && !first.discontinuity && core.store.read(key: key)?.items.first?.origin == .reconstructed, "first visible request history reconstructed")
        _ = try core.apply(response("first", id: "r1", finished: false), ticket: first.ticket)
        let responseItemID = core.store.read(key: key)!.items.last!.id
        let retry = try core.beginMain(key: key, context: context, request: firstRequest)
        check(retry.isRetry && retry.ticket.requestID != first.ticket.requestID && retry.ticket.conversationID == first.ticket.conversationID, "retry gets fresh ownership without duplicate request")
        let beforeLate = core.store.sequence
        check(try core.apply(response("late old response"), ticket: first.ticket, finished: true) == nil && core.store.sequence == beforeLate, "superseded request cannot overwrite newer state")
        _ = try core.apply(response("replacement", id: "r2", finished: false), ticket: retry.ticket)
        check(texts(core.store.read(key: key)) == ["continue", "replacement"] && core.store.read(key: key)?.items.last?.id == responseItemID, "retry updates one stable provisional response item")
        _ = try core.apply(response("answer", id: "r2"), ticket: retry.ticket, finished: true)
        check(try core.apply(response("late after finish"), ticket: retry.ticket) == nil, "finished ownership retired")
        let repeated = try request([message("user", "continue"), message("assistant", "answer"), message("user", "continue")])
        let next = try core.beginMain(key: key, context: context, request: repeated)
        check(!next.isRetry && !next.discontinuity && texts(core.store.read(key: key)) == ["continue", "answer", "continue"], "identical new user input not swallowed by last text match")
        check(core.store.read(key: key)?.items.contains(where: { $0.id == responseItemID }) == false, "authoritative request history replaces previous provisional response")
        _ = try core.apply(response("unfinished", id: "r3", finished: false), ticket: next.ticket, finished: true)
        check(core.store.read(key: key)?.summary.status == .incomplete, "finishing a streaming snapshot cannot claim success")

        let moved = ConversationContext(routeID: "r-new", paneID: "p-new", terminalID: "t-new")!
        let sameRequest = try core.beginMain(key: key, context: moved, request: repeated)
        check(sameRequest.isRetry && sameRequest.ticket.conversationID == first.ticket.conversationID && core.store.read(key: key)?.summary.context == moved, "route movement preserves native request history")
        let reset = try core.beginMain(key: key, context: moved, request: request([message("user", "changed context")]))
        check(reset.discontinuity && core.store.read(key: key)?.summary.truncated == true, "unmatched full history is an explicit discontinuity")
        check(core.store.read(key: key)?.items.filter { $0.origin == .discontinuity }.count == 1, "typed boundary rather than fabricated user content")
        check(texts(core.store.read(key: key)).last == "changed context", "unmatched input not discarded")

        var continuation = ConversationReconciler()
        let c1 = try continuation.beginMain(key: key, context: context, request: request([message("user", "one")], responses: true))
        _ = try continuation.apply(response("one-answer", id: "response-1"), ticket: c1.ticket, finished: true)
        let delta = try request([message("user", "two")], previous: "response-1", responses: true)
        let c2 = try continuation.beginMain(key: key, context: context, request: delta)
        check(!c2.discontinuity && texts(continuation.store.read(key: key)) == ["one", "one-answer", "two"], "Responses continuation retains prior response and appends incremental input")
        let c2retry = try continuation.beginMain(key: key, context: context, request: delta)
        check(c2retry.isRetry && texts(continuation.store.read(key: key)) == ["one", "one-answer", "two"], "incremental retry does not append duplicate input")
        check(try continuation.apply(response("stale"), ticket: c2.ticket) == nil, "incremental retry replaces ownership")
        _ = try continuation.apply(response("two-answer", id: "response-2"), ticket: c2retry.ticket, finished: true)
        let unknown = try continuation.beginMain(key: key, context: context, request: request([message("user", "branch")], previous: "not-known", responses: true))
        check(unknown.discontinuity, "unknown Responses predecessor not silently joined")
        var opaqueResponse = ConversationReconciler()
        let opaqueStart = try opaqueResponse.beginMain(key: key, context: context, request: firstRequest)
        _ = try opaqueResponse.apply(response("text", id: "\u{E9}"), ticket: opaqueStart.ticket, finished: true)
        let opaqueNext = try opaqueResponse.beginMain(key: key, context: context, request: request([message("user", "next")], previous: "e\u{301}", responses: true))
        check(opaqueNext.discontinuity, "provider response references compare exact UTF8 bytes")
        var firstContinuation = ConversationReconciler()
        let noHistory = try firstContinuation.beginMain(key: key, context: context, request: delta)
        check(noHistory.discontinuity && firstContinuation.store.read(key: key)?.summary.truncated == true, "first incremental request declares missing predecessor history")

        // The authoritative next request may split one streamed response into
        // separate message and function-call items. Never append both versions.
        var grouped = ConversationReconciler()
        let g1 = try grouped.beginMain(key: key, context: context, request: request([message("user", "start")], responses: true))
        let provider = ResponsesAssemblyTests.Stream(); try provider.start()
        let tool: [String: Any] = ["id": "fn", "type": "function_call", "call_id": "c", "name": "run", "arguments": "{\"a\":1}"]
        try provider.complete([ResponsesAssemblyTests.message("m", "working"), tool])
        _ = try grouped.apply(provider.assembly.snapshot, ticket: g1.ticket, finished: true)
        let full: [[String: Any]] = [message("user", "start"), ResponsesAssemblyTests.message("m", "working"), tool,
                                     ["type": "function_call_output", "call_id": "c", "output": "result"]]
        let g2 = try grouped.beginMain(key: key, context: context, request: request(full, responses: true))
        check(!g2.discontinuity && texts(grouped.store.read(key: key)) == ["start", "working", "{\"a\":1}", "result"], "authoritative history grouping replaces combined streamed blocks without duplicates")
        let reordered: [String: Any] = ["id": "fn", "type": "function_call", "call_id": "c", "name": "run", "arguments": "{ \"a\" : 1 }"]
        let sameMeaning = try grouped.beginMain(key: key, context: context, request: request([full[0], full[1], reordered, full[3]], responses: true))
        check(sameMeaning.isRetry, "tool JSON whitespace/order canonicalized for fingerprints")

        var rolling = ConversationReconciler()
        _ = try rolling.beginMain(key: key, context: context, request: request((0..<205).map { message("user", "u\($0)") }))
        let rolled = try rolling.beginMain(key: key, context: context, request: request((0..<206).map { message("user", "u\($0)") }))
        check(!rolled.discontinuity && texts(rolling.store.read(key: key)).last == "u205" && rolling.store.read(key: key)?.items.count == 201, "unique multi-message tail reconciles rolling history window")
        var ambiguous = ConversationReconciler()
        _ = try ambiguous.beginMain(key: key, context: context, request: request((0..<205).map { _ in message("user", "repeat") }))
        let ambiguousNext = try ambiguous.beginMain(key: key, context: context, request: request((0..<206).map { _ in message("user", "repeat") }))
        check(!ambiguousNext.isRetry && ambiguousNext.discontinuity, "ambiguous repeated tails not guessed as retries")
        check(ambiguous.retainedFingerprintCount == 200, "fingerprint metadata bounded to projected history")

        var evicting = ConversationReconciler(limits: .init(conversationBytes: 10_000, totalBytes: 20_000, conversations: 1))
        let old = try evicting.beginMain(key: key, context: context, request: firstRequest)
        let otherKey = ConversationKey(agent: "pi", herdrSession: "s", nativeSession: "native")!
        let new = try evicting.beginMain(key: otherKey, context: context, request: firstRequest)
        check(new.evictedConversationIDs == [old.ticket.conversationID] && evicting.trackedConversationCount == 1, "store eviction removes ownership/fingerprint metadata")
        check(try evicting.apply(response("must not resurrect"), ticket: old.ticket) == nil && evicting.store.count == 1, "evicted response cannot recreate conversation")
        check(evicting.store.read(id: old.ticket.conversationID) == nil && evicting.store.read(key: otherKey) != nil, "different agent namespace remains separate")
        var fresh = ConversationReconciler()
        check(try fresh.apply(response("old epoch"), ticket: new.ticket) == nil && fresh.store.count == 0, "ticket cannot cross recorder epochs")
        check(core.trackedConversationCount <= core.store.count && continuation.retainedFingerprintCount <= 200 * continuation.store.count, "metadata remains bounded by resident conversations")
    }
}
