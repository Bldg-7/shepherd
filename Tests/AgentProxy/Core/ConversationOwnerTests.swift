import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct ConversationOwnerTests {
    static func claude(_ kind: String = "main", agent: String? = "root", parent: String? = nil,
                       native: String = "native", session: String = "default", route: String = "route",
                       pane: String = "w1:p1", terminal: String = "term", version: String = "test") -> ClassifiedRequest {
        var headers = [["x-claude-code-session-id", native], ["x-claude-code-request-class", kind]]
        if let agent { headers.append(["x-claude-code-agent-id", agent]) }
        if let parent { headers.append(["x-claude-code-parent-agent-id", parent]) }
        return RequestClassification.classify(.init(routeID: route, upstream: "anthropic", method: "POST", path: "/v1/messages",
            headers: headers, routeIdentity: .init(kind: .claude, session: session, paneID: pane, terminalID: terminal, cliVersion: version)), body: Data())
    }
    static func codex(_ kind: String = "turn", native: String = "native", parent: String? = nil) throws -> ClassifiedRequest {
        RequestClassification.classify(RequestClassificationTests.open(.codex), body: try RequestClassificationTests.body(kind, native: native, parent: parent,
            flatExtra: parent == nil ? [:] : ["x-openai-subagent": "collab_spawn"]))
    }

    static func run(check: (Bool, String) -> Void) throws {
        let root = claude(), compact = claude("compaction")
        let owner = ConversationOwner(classification: root)!
        check(owner.ownsCompaction(compact), "explicit root agent identity binds Claude compaction")
        for request in [claude("compaction", agent: "child", parent: "root"), claude("compaction", agent: "child"),
                        claude("compaction", agent: nil), claude("compaction", native: "another"),
                        claude("compaction", session: "other"), claude("compaction", route: "old-route"),
                        claude("compaction", pane: "other"), claude("compaction", terminal: "other"), claude("main")] {
            check(!owner.ownsCompaction(request), "shared native session cannot override agent/route/namespace/class evidence")
        }
        let absent = ConversationOwner(classification: claude(agent: nil))!
        check(!absent.ownsCompaction(claude("compaction", agent: nil)), "two missing agent IDs do not prove root ownership")
        let knownRoot = ConversationOwner(classification: claude(agent: nil, version: "2.1.309"))!
        check(knownRoot.agentID == nil && knownRoot.ownsCompaction(claude("compaction", agent: nil, version: "2.1.309")), "known build root omission is source-backed without synthesizing an agent ID")
        check(!knownRoot.ownsCompaction(claude("compaction", agent: nil, version: "2.1.310")), "omitted-root convention not generalized to unverified builds")
        check(!knownRoot.ownsCompaction(claude("compaction", agent: "child", version: "2.1.309")), "known omitted-root contract still rejects child agent ID")
        check(!knownRoot.ownsCompaction(claude("compaction", agent: nil, parent: "parent", version: "2.1.309")), "parent evidence conflicts with omitted-root convention")
        check(ConversationOwner(classification: claude(parent: "parent")) == nil, "main label with a parent cannot register root ownership")
        check(ConversationOwner(classification: compact) == nil, "non-main class cannot create an owner")
        let unicode = ConversationOwner(classification: claude(agent: "\u{E9}"))!
        check(!unicode.ownsCompaction(claude("compaction", agent: "e\u{301}")), "agent IDs compare exact UTF8 rather than canonical Unicode")
        check(owner.directSubagentID(claude("subagent", agent: "child", parent: "root")) == "child", "explicit Claude direct-parent link")
        for request in [claude("subagent", agent: "child"), claude("subagent", agent: "child", parent: "nested"),
                        claude("subagent", agent: "root", parent: "root"), claude("subagent", agent: nil, parent: "root"),
                        claude("subagent", agent: "child", parent: "root", native: "other"), compact] {
            check(owner.directSubagentID(request) == nil, "unknown/nested/self/wrong-native links not guessed as direct children")
        }
        let codexRoot = try codex(), codexCompact = try codex("compaction")
        let codexOwner = ConversationOwner(classification: codexRoot)!
        check(codexOwner.ownsCompaction(codexCompact), "Codex main compaction uses native thread")
        check(!codexOwner.ownsCompaction(try codex("compaction", native: "child", parent: "native")), "Codex child compaction cannot replace parent history")
        check(codexOwner.directSubagentID(try codex(native: "child", parent: "native")) == "child", "Codex explicit native parent-thread link")
        check(codexOwner.directSubagentID(try codex(native: "native", parent: "native")) == nil, "Codex self-parent rejected")
        check(!owner.ownsCompaction(codexCompact) && !codexOwner.ownsCompaction(compact), "provider namespaces cannot cross")

        let request = try ConversationReconcilerTests.request([ConversationReconcilerTests.message("user", "original")])
        let reply = try ConversationReconcilerTests.response("original answer")
        let summary = try ConversationReconcilerTests.response("summary")
        var core = ConversationReconciler()
        check(core.beginCompaction(classification: compact) == nil && core.store.count == 0, "compaction cannot create a new conversation")
        let main = try core.beginMain(classification: root, request: request)
        check(core.beginCompaction(classification: compact) == nil, "active main response prevents compaction ownership race")
        _ = try core.apply(reply, ticket: main.ticket, finished: true)
        let old = core.store.read(id: main.ticket.conversationID)!
        check(core.beginCompaction(classification: claude("compaction", agent: "child", parent: "root")) == nil, "child compaction never acquires a main write ticket")
        let first = core.beginCompaction(classification: compact)!
        let second = core.beginCompaction(classification: compact)!
        check(first != second && core.store.read(id: main.ticket.conversationID) == old, "compaction retry supersedes ticket without rewriting history")
        check(try core.completeCompaction(summary, ticket: first, transportComplete: true) == nil, "superseded compaction cannot write")
        _ = try core.completeCompaction(summary, ticket: second, transportComplete: true)
        let completed = core.store.read(id: main.ticket.conversationID)!
        check(Array(completed.items.prefix(old.items.count)) == old.items, "compaction preserves all old item identities/text/order")
        check(completed.items[old.items.count].origin == .compaction(.plaintext) && completed.items.last?.origin == .summary, "typed boundary then bounded plaintext summary")
        check(completed.items.last?.message.blocks.first?.text == "summary", "actual API summary stored without fabricated content")
        let sequence = core.store.sequence
        check(try core.completeCompaction(summary, ticket: second, transportComplete: true) == nil && core.store.sequence == sequence, "completed compaction ticket cannot replay")
        let rebuilt = try core.beginMain(classification: root, request: request)
        check(!rebuilt.isRetry && rebuilt.discontinuity, "same request after compaction is rebuilt context, not old retry")
        check(Array(core.store.read(id: main.ticket.conversationID)!.items.prefix(completed.items.count)) == completed.items, "post-compaction reconstruction cannot move old reply behind boundary")
        _ = try core.apply(reply, ticket: rebuilt.ticket, finished: true)
        let stale = core.beginCompaction(classification: compact)!
        _ = try core.beginMain(classification: root, request: request)
        check(try core.completeCompaction(summary, ticket: stale, transportComplete: true) == nil, "new main request revokes pending compaction")

        var opaqueCore = ConversationReconciler()
        let cm = try opaqueCore.beginMain(classification: codexRoot, request: request)
        _ = try opaqueCore.apply(reply, ticket: cm.ticket, finished: true)
        let before = opaqueCore.store.read(id: cm.ticket.conversationID)!
        let encrypted = ResponsesAssemblyTests.Stream(); try encrypted.start()
        try encrypted.complete([["type": "context_compaction", "encrypted_content": "PRIVATE_CIPHER", "summary": "PRIVATE_FAKE"]])
        let ct = opaqueCore.beginCompaction(classification: codexCompact)!
        _ = try opaqueCore.completeCompaction(encrypted.assembly.snapshot, ticket: ct, transportComplete: true)
        let after = opaqueCore.store.read(id: cm.ticket.conversationID)!
        check(Array(after.items.prefix(before.items.count)) == before.items && after.items.count == before.items.count + 1, "encrypted compaction appends marker only and preserves history")
        check(after.items.last?.origin == .compaction(.opaque) && !String(describing: after).contains("PRIVATE_"), "ciphertext/fake summary cannot enter conversation store")
        let failed = opaqueCore.beginCompaction(classification: codexCompact)!
        _ = try opaqueCore.completeCompaction(summary, ticket: failed, transportComplete: false)
        let failedState = opaqueCore.store.read(id: cm.ticket.conversationID)!
        check(failedState.items.last?.origin == .compaction(.incomplete) && failedState.items.last?.status == .incomplete, "failed compaction appends incomplete marker, not partial summary")
        check(failedState.items.count == after.items.count + 1, "failed compaction does not duplicate history or summary")

        var lowLevel = ConversationReconciler()
        let low = try lowLevel.beginMain(key: owner.key, context: owner.context, request: request)
        _ = try lowLevel.apply(reply, ticket: low.ticket, finished: true)
        check(lowLevel.beginCompaction(classification: compact) == nil, "raw key/context path cannot manufacture observed owner evidence")
        do {
            _ = try lowLevel.beginMain(classification: compact, request: request)
            check(false, "non-main rejected by classified entry point")
        } catch { check(error as? ConversationReconciler.Failure == .invalidClassification, "classified main entry point rejects non-main before mutation") }
        check(lowLevel.store.count == 1, "invalid classification leaves existing conversation intact")
        var moved = ConversationReconciler()
        let moving = try moved.beginMain(classification: root, request: request)
        _ = try moved.apply(reply, ticket: moving.ticket, finished: true)
        let oldRoute = moved.beginCompaction(classification: compact)!
        let movedMain = try moved.beginMain(classification: claude(route: "new-route"), request: request)
        _ = try moved.apply(reply, ticket: movedMain.ticket, finished: true)
        check(movedMain.ticket.conversationID == moving.ticket.conversationID && moved.beginCompaction(classification: compact) == nil, "native resume keeps conversation but rejects old route ownership")
        check(try moved.completeCompaction(summary, ticket: oldRoute, transportComplete: true) == nil, "old route ticket cannot write after main rebind")
        check(moved.beginCompaction(classification: claude("compaction", route: "new-route")) != nil, "newly observed route can own compaction")

        var small = ConversationReconciler(limits: .init(conversationBytes: 5000, totalBytes: 10_000, conversations: 1))
        let sm = try small.beginMain(classification: root, request: request)
        _ = try small.apply(reply, ticket: sm.ticket, finished: true)
        let doomed = small.beginCompaction(classification: compact)!
        _ = try small.beginMain(classification: claude(native: "other"), request: request)
        check(try small.completeCompaction(summary, ticket: doomed, transportComplete: true) == nil && small.store.count == 1, "eviction retires compaction metadata; completion cannot resurrect history")
        var fresh = ConversationReconciler()
        check(try fresh.completeCompaction(summary, ticket: doomed, transportComplete: true) == nil && fresh.store.count == 0, "compaction ticket cannot cross recorder epochs")
        check(small.trackedConversationCount == small.store.count, "compaction metadata stays bounded by resident conversation count")
        var budgeted = ConversationReconciler(limits: .init(conversationBytes: 5000, totalBytes: 6500, conversations: 2))
        let a = try budgeted.beginMain(classification: root, request: request)
        _ = try budgeted.apply(reply, ticket: a.ticket, finished: true)
        let aCompact = budgeted.beginCompaction(classification: compact)!
        let b = try budgeted.beginMain(classification: claude(native: "other"), request: request)
        _ = try budgeted.apply(reply, ticket: b.ticket, finished: true)
        let bCompact = budgeted.beginCompaction(classification: claude("compaction", native: "other"))!
        let eviction = try budgeted.completeCompaction(ConversationReconcilerTests.response(String(repeating: "s", count: 2000)), ticket: aCompact, transportComplete: true)
        check(eviction?.evictedConversationIDs == [b.ticket.conversationID], "summary admission reports oldest conversation eviction")
        check(budgeted.store.read(id: a.ticket.conversationID)?.summary.truncated == true && budgeted.store.accountedBytes <= 6500, "existing byte caps apply to summaries with explicit history truncation")
        check(try budgeted.completeCompaction(summary, ticket: bCompact, transportComplete: true) == nil && budgeted.trackedConversationCount == 1, "compaction-triggered eviction prunes other owner and pending ticket")
    }
}
