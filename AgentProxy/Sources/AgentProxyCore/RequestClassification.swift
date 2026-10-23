import Foundation
import AgentProxyProtocol

public nonisolated struct ClassifiedRequest: Sendable {
    public enum Kind: Sendable { case main, subagent, compaction, auxiliary, unknown }
    public enum Reason: Sendable {
        case missingRouteIdentity, invalidRouteIdentity, unsupportedProvider, nonConversationEndpoint
        case ambiguousHeaders, missingClassification, conflictingMetadata, invalidMetadata, unverifiedPiTag
    }
    public let kind: Kind
    public let reason: Reason?
    public let route: AgentProxyRouteCreate?
    public let context: ConversationContext?
    public let provider: RequestProjection.Provider?
    public let nativeSessionID: String?
    public let parentSessionID: String?
    public let agentID: String?
    public let parentAgentID: String?
    public let promptID: String?

    /// No caller can obtain a main key from a compaction/subagent/unknown result
    /// by merely checking whether a native ID was present.
    public var mainConversationKey: ConversationKey? {
        guard kind == .main, let route, let nativeSessionID else { return nil }
        return ConversationKey(agent: route.kind.rawValue, herdrSession: route.session, nativeSession: nativeSessionID)
    }
}

/// Selects only bounded identity/classification fields, never retaining raw
/// header maps or client_metadata. Evidence: Claude2.1.309 static header mapping
/// and Codex rust-v0.162.1 source. Absent/unknown metadata is NOT a main request.
/// Pi contract2 uses request-local operation signals and SDK call options,
/// verified in1.3.0/1.4.0. Legacy unconditional tags and unknown builds fail closed.
public nonisolated enum RequestClassification {
    private enum Invalid: Error { case field, conflict, duplicate, missing }

    /// body must already be decompressed within the recorder's admission budget.
    /// Integration can call classifyObject after one shared bounded JSON parse.
    public static func classify(_ open: AgentProxyTeeFrame.Open, body: Data) -> ClassifiedRequest {
        guard body.count <= ConversationCaptureLimits.decompressedRequest else { return unknown(.invalidMetadata) }
        var object: [String: Any]?
        if open.routeIdentity?.kind == .codex, open.method == "POST", open.upstream == "chatgpt",
           ["/backend-api/codex/responses", "/backend-api/codex/responses/compact"].contains(open.path) {
            do { object = try RequestProjection.decodeObject(body) }
            catch { return unknown(.invalidMetadata) }
        }
        return classifyObject(open, object: object)
    }

    static func classifyObject(_ open: AgentProxyTeeFrame.Open, object: [String: Any]?) -> ClassifiedRequest {
        guard let route = open.routeIdentity else { return unknown(.missingRouteIdentity) }
        guard RequestProjection.identifier(route.session) != nil, RequestProjection.identifier(route.cliVersion) != nil,
              let context = ConversationContext(routeID: open.routeID, paneID: route.paneID, terminalID: route.terminalID) else {
            return unknown(.invalidRouteIdentity)
        }
        let provider: RequestProjection.Provider
        if open.upstream == "anthropic" { provider = .anthropic }
        else if open.upstream == "chatgpt" { provider = .responses }
        else { return unknown(.unsupportedProvider) }
        guard !(route.kind == .claude && provider != .anthropic), !(route.kind == .codex && provider != .responses) else {
            return unknown(.unsupportedProvider)
        }
        let conversational = open.method == "POST" && ((provider == .anthropic && open.path == "/v1/messages") ||
            (provider == .responses && ["/backend-api/codex/responses", "/backend-api/codex/responses/compact"].contains(open.path)))
        guard conversational else {
            return result(.auxiliary, reason: .nonConversationEndpoint, route: route, context: context, provider: provider)
        }
        do {
            let headers = try headerMap(open.headers)
            if route.kind == .pi {
                guard ["1.3.0", "1.4.0"].contains(route.cliVersion), headers["x-3rdr-pi-contract"] == "2" else { return unknown(.unverifiedPiTag) }
                let kind: ClassifiedRequest.Kind
                switch headers["x-3rdr-pi-class"] {
                case "main": kind = .main
                case "compaction": kind = .compaction
                case "auxiliary": kind = .auxiliary
                default: throw Invalid.missing
                }
                let native = try unique([headers["x-3rdr-pi-session"]])
                if kind != .auxiliary {
                    guard let native, native.utf8.count <= 128,
                          native.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                          headers["x-claude-code-parent-agent-id"] == nil,
                          headers["x-codex-parent-thread-id"] == nil, headers["x-openai-subagent"] == nil else { throw Invalid.field }
                }
                return result(kind, route: route, context: context, provider: provider, native: native)
            }
            if route.kind == .claude {
                guard let label = headers["x-claude-code-request-class"] else { throw Invalid.missing }
                let kind: ClassifiedRequest.Kind
                switch label {
                case "main": kind = .main
                case "subagent", "workflow": kind = .subagent
                case "compaction": kind = .compaction
                case "auxiliary", "side_reply": kind = .auxiliary
                default: throw Invalid.missing
                }
                let native = try unique([headers["x-claude-code-session-id"]])
                guard native != nil || kind == .auxiliary else { throw Invalid.missing }
                return result(kind, route: route, context: context, provider: provider, native: native,
                              agent: try unique([headers["x-claude-code-agent-id"]]),
                              parentAgent: try unique([headers["x-claude-code-parent-agent-id"]]),
                              prompt: try unique([headers["x-claude-code-prompt-id"]]))
            }
            return try codex(open: open, route: route, context: context, provider: provider, headers: headers, object: object)
        } catch Invalid.duplicate { return unknown(.ambiguousHeaders) }
        catch Invalid.conflict { return unknown(.conflictingMetadata) }
        catch Invalid.missing { return unknown(.missingClassification) }
        catch { return unknown(.invalidMetadata) }
    }

    private static func codex(open: AgentProxyTeeFrame.Open, route: AgentProxyRouteCreate, context: ConversationContext,
                              provider: RequestProjection.Provider, headers: [String: String], object: [String: Any]?) throws -> ClassifiedRequest {
        guard let object else { throw Invalid.field }
        let flat: [String: Any]
        if let value = object["client_metadata"] {
            guard let dictionary = value as? [String: Any] else { throw Invalid.field }
            flat = dictionary
        } else { flat = [:] }
        var canonical: [String: Any] = [:]
        if let value = flat["x-codex-turn-metadata"] {
            guard let text = value as? String, text.utf8.count <= 1 << 20 else { throw Invalid.field }
            // This includes caller-supplied extra metadata/tool inventory. Only
            // the selected fields below escape this local parse.
            canonical = try RequestProjection.decodeObject(Data(text.utf8))
        }
        let native = try unique([headers["thread-id"], flat["thread_id"], canonical["thread_id"]])
        let parent = try unique([headers["x-codex-parent-thread-id"], flat["x-codex-parent-thread-id"], canonical["parent_thread_id"]])
        let subagent = try unique([headers["x-openai-subagent"], flat["x-openai-subagent"]])
        let requestKind = try unique([canonical["request_kind"]])
        let memgen = headers["x-openai-memgen-request"]
        guard memgen == nil || memgen == "true" || memgen == "false" else { throw Invalid.field }
        let kind: ClassifiedRequest.Kind
        switch requestKind {
        case "prewarm", "memory": kind = .auxiliary
        case "compaction": kind = .compaction
        case "turn", nil:
            if memgen == "true" { kind = .auxiliary }
            else if let subagent {
                switch subagent {
                case "review", "collab_spawn": kind = .subagent
                case "compact": kind = .compaction
                case "memory_consolidation": kind = .auxiliary
                default: throw Invalid.missing
                }
            } else if requestKind == "turn", parent == nil, open.path == "/backend-api/codex/responses" {
                kind = .main
            } else { throw Invalid.missing }
        default: throw Invalid.missing
        }
        // session-id/session_id are intentionally NOT candidates for native
        // identity: cache affinity can differ from the active Codex thread.
        guard native != nil || kind == .auxiliary else { throw Invalid.missing }
        return result(kind, route: route, context: context, provider: provider, native: native, parent: parent)
    }

    private static func headerMap(_ pairs: [[String]]) throws -> [String: String] {
        guard pairs.count <= 64 else { throw Invalid.field }
        var result: [String: String] = [:]
        for pair in pairs {
            guard pair.count == 2, pair[0].utf8.count <= 128 else { throw Invalid.field }
            let name = pair[0].lowercased()
            guard AgentProxyTeeFrame.allowedRequestHeader(name) else { continue }
            guard pair[1].utf8.count <= 4_096,
                  !pair[1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Invalid.field }
            guard result[name] == nil else { throw Invalid.duplicate }
            result[name] = pair[1]
        }
        return result
    }

    private static func unique(_ values: [Any?]) throws -> String? {
        var result: String?
        for value in values {
            guard let value else { continue }
            guard let string = RequestProjection.identifier(value) else { throw Invalid.field }
            if let previous = result, !previous.utf8.elementsEqual(string.utf8) { throw Invalid.conflict }
            result = string
        }
        return result
    }

    private static func unknown(_ reason: ClassifiedRequest.Reason) -> ClassifiedRequest {
        ClassifiedRequest(kind: .unknown, reason: reason, route: nil, context: nil, provider: nil,
                          nativeSessionID: nil, parentSessionID: nil, agentID: nil, parentAgentID: nil, promptID: nil)
    }

    private static func result(_ kind: ClassifiedRequest.Kind, reason: ClassifiedRequest.Reason? = nil,
                               route: AgentProxyRouteCreate, context: ConversationContext, provider: RequestProjection.Provider,
                               native: String? = nil, parent: String? = nil, agent: String? = nil,
                               parentAgent: String? = nil, prompt: String? = nil) -> ClassifiedRequest {
        ClassifiedRequest(kind: kind, reason: reason, route: route, context: context, provider: provider,
                          nativeSessionID: native, parentSessionID: parent, agentID: agent, parentAgentID: parentAgent, promptID: prompt)
    }
}
