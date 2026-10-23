import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct SubagentTests {
    static func child(_ id: String, parent: String = "root", native: String = "native", route: String = "route") -> ClassifiedRequest {
        ConversationOwnerTests.claude("subagent", agent: id, parent: parent, native: native, route: route)
    }
    static func answer(_ text: String, final: Bool = true, complete: Bool = true) throws -> CapturedResponse {
        let s = AnthropicResponseTests.Stream(); try s.start()
        try s.block(0, ["type": "text", "text": text]); try s.stop(0)
        try s.send(["type": "message_delta", "delta": ["stop_reason": final ? "end_turn" : "max_tokens"]])
        try s.complete(transport: complete)
        return s.assembly.snapshot
    }
    static func run(check: (Bool, String) -> Void) throws {
        var core = ConversationReconciler()
        let request = try ConversationReconcilerTests.request([ConversationReconcilerTests.message("user", "root")])
        let owner = ConversationOwnerTests.claude()
        let main = try core.beginMain(classification: owner, request: request)
        let id = main.ticket.conversationID
        let first = try core.beginSubagent(classification: child("child"), requestBody: Data("private child context".utf8))!
        check(core.store.read(id: id)?.summary.subagents.observed == 1 && core.trackedSubagentCount == 1, "explicit linked child counted once")
        check(!String(describing: core.store.read(id: id)).contains("private child context"), "child context not copied into parent history")
        let nested = try core.beginSubagent(classification: child("nested", parent: "child"), requestBody: Data("nested".utf8))!
        check(core.store.read(id: id)?.summary.subagents.observed == 2, "observed explicit ancestry links nested child")
        check(try core.beginSubagent(classification: child("orphan", parent: "unobserved"), requestBody: Data()) == nil, "unknown parent is not guessed")
        check(try core.beginSubagent(classification: child("child", parent: "nested"), requestBody: Data()) == nil, "cycle/reparenting fails closed")
        check(try core.beginSubagent(classification: child("elsewhere", route: "moved"), requestBody: Data()) == nil, "shared session on moved route cannot attach")
        check(try core.beginSubagent(classification: child("other", native: "unrelated"), requestBody: Data()) == nil, "Claude native session must also match")
        _ = try core.completeSubagent(answer("intermediate", final: false), ticket: first, transportComplete: true)
        check(core.store.read(id: id)?.summary.subagents.withFinalResult == 0 && !String(describing: core.store.read(id: id)).contains("intermediate"), "HTTP completion without end_turn does not store intermediate child text")
        let retry = try core.beginSubagent(classification: child("child"), requestBody: Data("private child context".utf8))!
        check(try core.completeSubagent(answer("stale"), ticket: first, transportComplete: true) == nil, "finished/superseded child ticket is stale")
        _ = try core.completeSubagent(answer("final result"), ticket: retry, transportComplete: true)
        let result = core.store.read(id: id)!.items.last!
        check(result.origin == .subagent(id: "child", depth: 1) && result.message.blocks[0].text == "final result", "only final child text receives typed child origin")
        let retried = try core.beginSubagent(classification: child("child"), requestBody: Data("private child context".utf8))!
        _ = try core.completeSubagent(answer("final result"), ticket: retried, transportComplete: true)
        check(core.store.read(id: id)!.items.filter { $0.id == result.id }.count == 1 && core.store.read(id: id)!.items.count == 2, "adjacent request retry neither duplicates nor relocates final result")
        _ = try core.completeSubagent(answer("nested result"), ticket: nested, transportComplete: true)
        check(core.store.read(id: id)?.items.last?.origin == .subagent(id: "nested", depth: 2), "nested result retains verified depth")
        check(core.store.read(id: id)?.summary.subagents.withFinalResult == 2, "counts refer to observed final answers, not process exits")
        let body = try ConversationReadAPITests.call("conversation.read", ["conversationID": id], store: core.store).result!
        check(body.summary?.subagents.observed == 2 && body.items?.last?.subagentDepth == 2, "counts and typed result metadata reach bounded read API")
        _ = try core.apply(ConversationReconcilerTests.response("parent reply"), ticket: main.ticket, finished: true)
        let secondMain = try core.beginMain(classification: owner, request: request)
        check(core.trackedSubagentCount == 2 && core.store.read(id: id)?.summary.subagents.observed == 2, "same verified root preserves bounded child ancestry across main turns")
        let aborted = try core.beginSubagent(classification: child("aborted"), requestBody: Data())!
        _ = try core.completeSubagent(answer("must not appear"), ticket: aborted, transportComplete: false)
        check(!String(describing: core.store.read(id: id)).contains("must not appear"), "tee abort overrides provider final answer")
        _ = secondMain
        let bounded = try core.beginSubagent(classification: child("bounded"), requestBody: Data())!
        _ = try core.completeSubagent(answer(String(repeating: "🧪", count: 10_000)), ticket: bounded, transportComplete: true)
        let clipped = core.store.read(id: id)!.items.first { $0.origin == .subagent(id: "bounded", depth: 1) }!
        check(clipped.message.blocks[0].text.utf8.count <= 16 << 10 && clipped.message.truncated, "final child summary has its own16KiB UTF-8 budget")

        var omitted = ConversationReconciler()
        let nilRoot = ConversationOwnerTests.claude(agent: nil, version: "2.1.309")
        let absent = try omitted.beginMain(classification: nilRoot, request: request)
        let member = ConversationOwnerTests.claude("subagent", agent: "member", parent: "native", version: "2.1.309")
        check(ConversationOwner(classification: nilRoot)?.agentID == nil && ConversationOwner(classification: nilRoot)?.directSubagentID(member) == nil,
              "scoped membership does not fabricate the omitted root ID or a direct-parent relation")
        let memberTicket = try omitted.beginSubagent(classification: member, requestBody: Data())!
        _ = try omitted.completeSubagent(answer("member result"), ticket: memberTicket, transportComplete: true)
        check(omitted.store.read(id: absent.ticket.conversationID)?.summary.subagents.ancestryIncomplete == true && omitted.store.read(id: absent.ticket.conversationID)?.items.last?.origin == .subagent(id: "member", depth: nil), "known-build managed-native membership can expose final result with explicitly unknown ancestry")
        check(omitted.beginCompaction(classification: ConversationOwnerTests.claude("compaction", agent: "member", parent: "native", version: "2.1.309")) == nil, "scoped child membership NEVER authorizes child compaction on main")
        check(try omitted.beginSubagent(classification: child("other-version", parent: "native"), requestBody: Data()) == nil, "unverified version does not inherit scoped membership convention")
        for outside in [ConversationOwnerTests.claude("subagent", agent: "foreign", parent: "missing", native: "other", version: "2.1.309"),
                        ConversationOwnerTests.claude("subagent", agent: "foreign", parent: "missing", route: "other", version: "2.1.309"),
                        ConversationOwnerTests.claude("subagent", agent: "foreign", parent: "missing", session: "other", version: "2.1.309")] {
            check(try omitted.beginSubagent(classification: outside, requestBody: Data()) == nil, "scoped membership still requires exact native and managed launch location")
        }
        _ = try omitted.beginSubagent(classification: ConversationOwnerTests.claude("subagent", agent: "orphan-a", parent: "orphan-b", version: "2.1.309"), requestBody: Data())
        check(try omitted.beginSubagent(classification: ConversationOwnerTests.claude("subagent", agent: "orphan-b", parent: "orphan-a", version: "2.1.309"), requestBody: Data()) == nil, "later unresolved parent cannot close an ancestry cycle")
        var invalidStore = ConversationStore()
        for origin: ConversationItem.Origin in [.subagent(id: String(repeating: "x", count: 257), depth: 1), .subagent(id: "child", depth: 17)] {
            do {
                _ = try invalidStore.upsert(key: owner.mainConversationKey!, context: owner.context!,
                    items: [ConversationItem(id: "bad", message: result.message, origin: origin, status: .complete)], status: .complete)
                check(false, "unbounded child metadata accepted")
            } catch { check(invalidStore.count == 0, "invalid child metadata cannot mutate or evict store") }
        }

        var levels = ConversationReconciler()
        let depthRoot = try levels.beginMain(classification: owner, request: request)
        var parent = "root"
        for depth in 1...16 {
            let name = "depth\(depth)"
            check(try levels.beginSubagent(classification: child(name, parent: parent), requestBody: Data()) != nil, "bounded ancestry depth\(depth)")
            parent = name
        }
        check(try levels.beginSubagent(classification: child("too-deep", parent: parent), requestBody: Data()) == nil, "ancestry maximum is enforced")
        check(levels.store.read(id: depthRoot.ticket.conversationID)?.summary.subagents.limited == true, "depth limit is visible, not a claimed complete count")
        var counts = ConversationReconciler()
        let countRoot = try counts.beginMain(classification: owner, request: request)
        for n in 0..<128 { _ = try counts.beginSubagent(classification: child("c\(n)"), requestBody: Data()) }
        check(try counts.trackedSubagentCount == 128 && counts.beginSubagent(classification: child("overflow"), requestBody: Data()) == nil, "per-root child metadata bounded")
        check(counts.store.read(id: countRoot.ticket.conversationID)?.summary.subagents.limited == true, "count cap explicit")
        _ = counts.evictOldest()
        check(counts.trackedSubagentCount == 0, "eviction releases all child metadata")
        _ = core.evictOldest()
        check(try core.trackedSubagentCount == 0 && core.completeSubagent(answer("late"), ticket: nested, transportComplete: true) == nil, "evicted child completion cannot resurrect root")

        var global = ConversationReconciler()
        for root in 0..<8 {
            _ = try global.beginMain(classification: ConversationOwnerTests.claude(native: "root\(root)"), request: request)
            for n in 0..<128 { _ = try global.beginSubagent(classification: child("c\(n)", native: "root\(root)"), requestBody: Data()) }
        }
        _ = try global.beginMain(classification: ConversationOwnerTests.claude(native: "ninth"), request: request)
        check(try global.trackedSubagentCount == 1024 && global.beginSubagent(classification: child("overflow", native: "ninth"), requestBody: Data()) == nil, "all roots share1024-node metadata admission")
        _ = global.evictOldest()
        check(try global.trackedSubagentCount == 896 && global.beginSubagent(classification: child("reclaimed", native: "ninth"), requestBody: Data()) != nil, "root eviction reclaims global child slots")

        var codex = ConversationReconciler()
        let cx = try codex.beginMain(classification: ConversationOwnerTests.codex(), request: request)
        let childClass = try ConversationOwnerTests.codex(native: "child-thread", parent: "native")
        for phase: String? in [nil, "commentary", "final_answer"] {
            let t = try codex.beginSubagent(classification: childClass, requestBody: Data((phase ?? "none").utf8))!
            let response = ResponsesAssemblyTests.Stream(); try response.start()
            var message = ResponsesAssemblyTests.message("message", "result"); message["phase"] = phase
            try response.complete([message])
            check(response.assembly.snapshot.isFinalAnswer == (phase == "final_answer"), "Codex finality requires explicit final_answer phase")
            _ = try codex.completeSubagent(response.assembly.snapshot, ticket: t, transportComplete: true)
        }
        check(codex.store.read(id: cx.ticket.conversationID)?.summary.subagents.withFinalResult == 1 && codex.store.read(id: cx.ticket.conversationID)?.items.count == 2, "Codex commentary is not stored as a final child result")
        let cxNested = try codex.beginSubagent(classification: ConversationOwnerTests.codex(native: "nested-thread", parent: "child-thread"), requestBody: Data())
        check(cxNested != nil, "Codex parent-thread ancestry stays under verified root")
        let toolResponse = ResponsesAssemblyTests.Stream(); try toolResponse.start()
        var finalMessage = ResponsesAssemblyTests.message("final", "not really final"); finalMessage["phase"] = "final_answer"
        try toolResponse.complete([finalMessage, ResponsesAssemblyTests.function("{}")])
        check(!toolResponse.assembly.snapshot.isFinalAnswer, "function call prevents a Responses tool turn from becoming final")
        let tool = AnthropicResponseTests.Stream(); try tool.start()
        try tool.block(0, ["type": "tool_use", "id": "call", "name": "read", "input": [:]]); try tool.stop(0)
        try tool.send(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]); try tool.complete()
        check(!tool.assembly.snapshot.isFinalAnswer, "Anthropic tool block overrides conflicting end_turn finality")
        check(try !answer("truncated transport", complete: false).isFinalAnswer, "transport failure clears provider finality")

        let tee = ConversationCaptureTests.Harness()
        try tee.open(1); try tee.request(1); try tee.head(1); try tee.answer(1, "parent"); try tee.end(1)
        let childOpen = RequestClassificationTests.open(.claude, headers: [["x-claude-code-session-id", "native"],
            ["x-claude-code-request-class", "subagent"], ["x-claude-code-agent-id", "child"], ["x-claude-code-parent-agent-id", "root"]])
        try tee.json(.open, 2, childOpen); try tee.request(2, "private child history"); try tee.head(2); try tee.answer(2, "child final", complete: false)
        check(tee.snapshot?.summary.subagents.observed == 1 && !String(describing: tee.snapshot).contains("child final"), "real capture counts child but withholds streaming content")
        try tee.event(2, ["type": "content_block_stop", "index": 0])
        try tee.event(2, ["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        try tee.event(2, ["type": "message_stop"]); try tee.end(2)
        check(tee.snapshot?.summary.subagents.withFinalResult == 1 && tee.snapshot?.items.last?.origin == .subagent(id: "child", depth: 1), "tee End delivers only verified final child result")
        check(!String(describing: tee.snapshot).contains("private child history"), "child history never enters main projection")
    }
}
