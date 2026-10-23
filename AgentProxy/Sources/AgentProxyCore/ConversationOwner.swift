import Foundation

/// Selected, non-secret identity of an observed main request. Native session
/// equality alone is not enough for Claude: its subagents can share that ID.
/// This is capture correlation, not browser/credential authorization.
public nonisolated struct ConversationOwner: Sendable {
    public let key: ConversationKey
    public let context: ConversationContext
    public let agentID: String?
    private let knownOmittedRootIDs: Bool

    public init?(classification: ClassifiedRequest) {
        guard let key = classification.mainConversationKey, let context = classification.context,
              classification.parentSessionID == nil, classification.parentAgentID == nil else { return nil }
        self.key = key; self.context = context; self.agentID = classification.agentID
        // Verified in the installed 2.1.309 header builder: it deliberately
        // excludes agent/parent IDs when agentType == main. Do not generalize
        // that absence convention to other builds or fabricate a root agent ID.
        self.knownOmittedRootIDs = key.agent == "claude" && classification.agentID == nil
            && classification.route?.cliVersion == "2.1.309"
    }

    public func ownsCompaction(_ request: ClassifiedRequest) -> Bool {
        guard request.kind == .compaction, sameLocation(request),
              Self.same(request.nativeSessionID, key.nativeSession),
              request.parentSessionID == nil, request.parentAgentID == nil else { return false }
        switch key.agent {
        case "claude":
            if Self.same(agentID, request.agentID) { return true }
            return knownOmittedRootIDs && request.agentID == nil && request.route?.cliVersion == "2.1.309"
        case "codex": return true // native thread identity is independently scoped
        case "pi": return true // verified contract2 operation signal, not an inferred main flag
        default: return false
        }
    }

    /// A directly linked child's native identifier, not a guessed count from
    /// tool names/arguments. Nested ancestry still needs explicit correlation.
    public func directSubagentID(_ request: ClassifiedRequest) -> String? {
        guard request.kind == .subagent, sameLocation(request) else { return nil }
        switch key.agent {
        case "claude":
            guard Self.same(request.nativeSessionID, key.nativeSession),
                  Self.same(request.parentAgentID, agentID), let child = request.agentID,
                  !Self.same(child, agentID) else { return nil }
            return child
        case "codex":
            guard Self.same(request.parentSessionID, key.nativeSession), let child = request.nativeSessionID,
                  !Self.same(child, key.nativeSession) else { return nil }
            return child
        default: return nil
        }
    }

    public var canLinkSubagents: Bool { key.agent == "codex" || (key.agent == "claude" && (agentID != nil || knownOmittedRootIDs)) }

    /// Exact-build root omission can establish membership in this managed
    /// native session, NOT a direct-parent identity. Keep its ancestry unknown;
    /// this never authorizes a child's compaction to mutate main history.
    func scopedSubagentID(_ request: ClassifiedRequest) -> String? {
        guard knownOmittedRootIDs, request.route?.cliVersion == "2.1.309",
              request.kind == .subagent, sameLocation(request), Self.same(request.nativeSessionID, key.nativeSession),
              let child = request.agentID, !Self.same(child, request.parentAgentID) else { return nil }
        return child
    }

    func matches(_ other: ConversationOwner) -> Bool {
        key == other.key && Self.same(context.routeID, other.context.routeID)
            && Self.same(context.paneID, other.context.paneID) && Self.same(context.terminalID, other.context.terminalID)
            && agentID.map({ Data($0.utf8) }) == other.agentID.map({ Data($0.utf8) })
            && knownOmittedRootIDs == other.knownOmittedRootIDs
    }

    /// Only an already linked parent may extend ancestry; no orphan guessing.
    func descendantSubagentID(_ request: ClassifiedRequest, parent: String) -> String? {
        guard request.kind == .subagent, sameLocation(request) else { return nil }
        if key.agent == "claude" {
            guard Self.same(request.nativeSessionID, key.nativeSession), Self.same(request.parentAgentID, parent),
                  let child = request.agentID, !Self.same(child, parent), !Self.same(child, agentID) else { return nil }
            return child
        }
        if key.agent == "codex" {
            guard Self.same(request.parentSessionID, parent), let child = request.nativeSessionID,
                  !Self.same(child, parent), !Self.same(child, key.nativeSession) else { return nil }
            return child
        }
        return nil
    }

    private func sameLocation(_ request: ClassifiedRequest) -> Bool {
        guard let route = request.route, let candidate = request.context else { return false }
        return Self.same(route.kind.rawValue, key.agent) && Self.same(route.session, key.herdrSession)
            && Self.same(candidate.routeID, context.routeID) && Self.same(candidate.paneID, context.paneID)
            && Self.same(candidate.terminalID, context.terminalID)
    }

    private static func same(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return false }
        return left.utf8.elementsEqual(right.utf8)
    }
}
