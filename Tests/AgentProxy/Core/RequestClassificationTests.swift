import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct RequestClassificationTests {
    static func open(_ kind: AgentProxyRouteKind, headers: [[String]] = [], path: String? = nil,
                     method: String = "POST", upstream: String? = nil, identity: Bool = true) -> AgentProxyTeeFrame.Open {
        let provider = upstream ?? (kind == .codex ? "chatgpt" : "anthropic")
        return .init(routeID: "route", upstream: provider, method: method,
                     path: path ?? (provider == "chatgpt" ? "/backend-api/codex/responses" : "/v1/messages"), headers: headers,
                     routeIdentity: identity ? .init(kind: kind, session: "default", paneID: "w1:p1", terminalID: "term", cliVersion: "test-version") : nil)
    }
    static func body(_ kind: String?, native: String? = "native", parent: String? = nil,
                     extra: [String: Any] = [:], flatExtra: [String: Any] = [:]) throws -> Data {
        var canonical = extra
        if let kind { canonical["request_kind"] = kind }
        if let native { canonical["thread_id"] = native }
        if let parent { canonical["parent_thread_id"] = parent }
        var flat = flatExtra
        if let native { flat["thread_id"] = native }
        flat["x-codex-turn-metadata"] = String(data: try JSONSerialization.data(withJSONObject: canonical), encoding: .utf8)!
        return try JSONSerialization.data(withJSONObject: ["input": [], "client_metadata": flat])
    }

    static func run(check: (Bool, String) -> Void) throws {
        let empty = Data("{}".utf8)
        let claudeHeaders = [["X-Claude-Code-Session-Id", "native"], ["x-claude-code-request-class", "main"],
                             ["x-claude-code-agent-id", "agent"], ["x-claude-code-prompt-id", "prompt"],
                             ["Authorization", "PRIVATE_AUTH"], ["x-claude-code-future-token", "PRIVATE_FUTURE"]]
        let main = RequestClassification.classify(open(.claude, headers: claudeHeaders), body: empty)
        check(main.kind == .main && main.mainConversationKey?.nativeSession == "native" && main.context?.terminalID == "term", "Claude verified main class and route identity")
        check(main.agentID == "agent" && main.promptID == "prompt", "Claude bounded native classification IDs selected")
        check(!String(describing: main).contains("PRIVATE_"), "classifier retains no raw credential/unreviewed header values")
        let classes: [(String, ClassifiedRequest.Kind)] = [("subagent", .subagent), ("workflow", .subagent), ("compaction", .compaction), ("auxiliary", .auxiliary), ("side_reply", .auxiliary)]
        for (label, kind) in classes {
            let result = RequestClassification.classify(open(.claude, headers: [["x-claude-code-session-id", "native"], ["x-claude-code-request-class", label], ["x-claude-code-parent-agent-id", "parent"]]), body: empty)
            check(result.kind == kind && result.mainConversationKey == nil && result.parentAgentID == "parent", "Claude non-main \(label) cannot produce a main key")
        }
        for headers in [[["x-claude-code-session-id", "native"]], [["x-claude-code-session-id", "native"], ["x-claude-code-request-class", "future"]]] {
            let result = RequestClassification.classify(open(.claude, headers: headers), body: empty)
            check(result.kind == .unknown && result.mainConversationKey == nil, "missing/unknown class not guessed as main")
        }
        let duplicate = RequestClassification.classify(open(.claude, headers: claudeHeaders + [["X-Claude-Code-Request-Class", "auxiliary"]]), body: empty)
        check(duplicate.reason == .ambiguousHeaders && duplicate.mainConversationKey == nil, "case-insensitive duplicate classification rejected")
        let missingRoute = RequestClassification.classify(open(.claude, headers: claudeHeaders, identity: false), body: empty)
        check(missingRoute.reason == .missingRouteIdentity && missingRoute.context == nil, "legacy frames cannot fabricate identity")
        let mismatch = RequestClassification.classify(open(.claude, headers: claudeHeaders, upstream: "chatgpt"), body: empty)
        check(mismatch.reason == .unsupportedProvider, "route/provider mismatch rejected")
        for kind: AgentProxyRouteKind in [.claude, .codex] {
            let side = RequestClassification.classify(open(kind, method: "GET"), body: Data())
            check(side.kind == .auxiliary && side.reason == .nonConversationEndpoint && side.mainConversationKey == nil, "non-model request does not parse or capture conversation")
        }
        let countTokens = RequestClassification.classify(open(.claude, headers: claudeHeaders, path: "/v1/messages/count_tokens"), body: empty)
        check(countTokens.kind == .auxiliary, "count_tokens is not a main conversation")
        let invalidHeader = RequestClassification.classify(open(.claude, headers: [["x-claude-code-session-id", "bad\n"], ["x-claude-code-request-class", "main"]]), body: empty)
        check(invalidHeader.reason == .invalidMetadata, "control characters rejected")
        let malformedPair = RequestClassification.classify(open(.claude, headers: [["x-claude-code-request-class"]]), body: empty)
        check(malformedPair.reason == .invalidMetadata, "malformed header pair rejected")
        let flood = RequestClassification.classify(open(.claude, headers: Array(repeating: ["x-unknown", "x"], count: 65)), body: empty)
        check(flood.reason == .invalidMetadata, "header processing count bounded")

        let codex = RequestClassification.classify(open(.codex, headers: [["thread-id", "native"], ["session-id", "different-cache-key"]]), body: try body("turn", extra: ["extra": "PRIVATE_EXTRA", "tool_namespaces_info": ["PRIVATE_INVENTORY": "hidden"]]))
        check(codex.kind == .main && codex.mainConversationKey?.nativeSession == "native", "Codex native thread, not cache-affinity session")
        check(!String(describing: codex).contains("PRIVATE_"), "only selected metadata fields escape Codex body parse")
        let conflict = RequestClassification.classify(open(.codex, headers: [["thread-id", "another-thread"]]), body: try body("turn"))
        check(conflict.reason == .conflictingMetadata && conflict.mainConversationKey == nil, "contradictory native identities fail closed")
        let unicodeConflict = RequestClassification.classify(open(.codex, headers: [["thread-id", "\u{E9}"]]), body: try body("turn", native: "e\u{301}"))
        check(unicodeConflict.reason == .conflictingMetadata, "native IDs compared as opaque bytes")
        for label in ["prewarm", "memory"] {
            let side = RequestClassification.classify(open(.codex), body: try body(label, native: nil))
            check(side.kind == .auxiliary && side.mainConversationKey == nil, "Codex \(label) is auxiliary even without native thread")
        }
        let compact = RequestClassification.classify(open(.codex), body: try body("compaction", extra: ["compaction": ["phase": "before_turn"]]))
        check(compact.kind == .compaction && compact.mainConversationKey == nil, "root /responses compaction identified from canonical metadata")
        let sub = RequestClassification.classify(open(.codex, headers: [["x-openai-subagent", "collab_spawn"], ["x-codex-parent-thread-id", "parent"]]), body: try body("turn", parent: "parent"))
        check(sub.kind == .subagent && sub.parentSessionID == "parent" && sub.mainConversationKey == nil, "Codex child request and explicit parent linkage")
        let parentConflict = RequestClassification.classify(open(.codex, headers: [["x-openai-subagent", "review"], ["x-codex-parent-thread-id", "wrong"]]), body: try body("turn", parent: "parent"))
        check(parentConflict.reason == .conflictingMetadata, "contradictory parent linkage rejected")
        let legacyCompact = RequestClassification.classify(open(.codex, headers: [["thread-id", "native"], ["x-openai-subagent", "compact"]]), body: empty)
        check(legacyCompact.kind == .compaction && legacyCompact.mainConversationKey == nil, "verified legacy compact class remains non-main")
        let memgen = RequestClassification.classify(open(.codex, headers: [["x-openai-memgen-request", "true"]]), body: try body("turn"))
        check(memgen.kind == .auxiliary, "memory signal cannot masquerade as main turn")
        let rawHeaderOnly = RequestClassification.classify(open(.codex, headers: [["thread-id", "native"], ["x-codex-turn-metadata", "{\"request_kind\":\"turn\"}"]]), body: empty)
        check(rawHeaderOnly.kind == .unknown && rawHeaderOnly.mainConversationKey == nil, "raw turn metadata header not copied or trusted as a fallback")
        let cacheOnly = RequestClassification.classify(open(.codex, headers: [["session-id", "cache"], ["session_id", "legacy"]]), body: try body("turn", native: nil))
        check(cacheOnly.kind == .unknown, "cache session spelling never substitutes for missing native thread")
        let orphan = RequestClassification.classify(open(.codex), body: try body("turn", parent: "parent"))
        check(orphan.kind == .unknown, "parent linkage without verified child class not guessed as main")
        let futureSub = RequestClassification.classify(open(.codex, headers: [["x-openai-subagent", "new-purpose"]]), body: try body("turn"))
        check(futureSub.kind == .unknown, "future subagent/internal class not silently treated as main")
        let malformedBody = RequestClassification.classify(open(.codex), body: Data("invalid JSON".utf8))
        check(malformedBody.reason == .invalidMetadata, "malformed body cannot classify as main")
        let tooLargeMetadata = try JSONSerialization.data(withJSONObject: ["client_metadata": ["x-codex-turn-metadata": String(repeating: "x", count: (1 << 20) + 1)]])
        check(RequestClassification.classify(open(.codex), body: tooLargeMetadata).reason == .invalidMetadata, "canonical metadata parse bounded independently")
        let pi = RequestClassification.classify(open(.pi, headers: [["x-3rdr-pi-session", "pi-session"], ["x-3rdr-pi-class", "main"]]), body: empty)
        check(pi.kind == .unknown && pi.reason == .unverifiedPiTag && pi.mainConversationKey == nil, "unconditional legacy Pi main tag not trusted")
    }
}
