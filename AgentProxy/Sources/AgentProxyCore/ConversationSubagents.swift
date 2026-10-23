import Foundation

/// Counts of identities actually observed under this managed native session,
/// not live processes. A final answer does not prove that a child process exited.
public nonisolated struct ConversationSubagents: Codable, Equatable, Sendable {
    public let observed: Int
    public let withFinalResult: Int
    public let limited: Bool
    public let linkAvailable: Bool
    public let ancestryIncomplete: Bool
    public init(observed: Int = 0, withFinalResult: Int = 0, limited: Bool = false,
                linkAvailable: Bool = false, ancestryIncomplete: Bool = false) {
        self.observed = observed; self.withFinalResult = withFinalResult; self.limited = limited
        self.linkAvailable = linkAvailable; self.ancestryIncomplete = ancestryIncomplete
    }
    var valid: Bool { (0...128).contains(observed) && (0...observed).contains(withFinalResult) }
}

/// Metadata only: <=128 children/root, <=16 observed ancestry levels, <=1024
/// nodes globally. No child transcript/reasoning. Missing root IDs are never
/// synthesized: exact-build scoped membership may retain an unresolved parent
/// edge and nil depth, while compaction keeps its stricter owner requirement.
nonisolated struct ConversationSubagentTree: Sendable {
    struct Link {
        let id: String
        let parent: Data?
        let directRoot: Bool
    }
    struct Node: Sendable {
        let id: String
        let parent: Data?
        let directRoot: Bool
        var signature: Data
        var requestID: String?
        var resultItemID: String
        var hasFinal = false
    }
    let owner: ConversationOwner
    var nodes: [Data: Node] = [:]
    var limited = false
    var stats: ConversationSubagents {
        .init(observed: nodes.count, withFinalResult: nodes.values.filter(\.hasFinal).count,
              limited: limited, linkAvailable: owner.canLinkSubagents,
              ancestryIncomplete: nodes.keys.contains { depth($0) == nil })
    }
    func link(_ request: ClassifiedRequest) -> Link? {
        if let id = owner.directSubagentID(request) { return Link(id: id, parent: nil, directRoot: true) }
        let parent = owner.key.agent == "claude" ? request.parentAgentID : request.parentSessionID
        if let parent, let node = nodes[Data(parent.utf8)],
           let id = owner.descendantSubagentID(request, parent: node.id) {
            return Link(id: id, parent: Data(parent.utf8), directRoot: false)
        }
        if let id = owner.scopedSubagentID(request) {
            return Link(id: id, parent: parent.map { Data($0.utf8) }, directRoot: false)
        }
        return nil
    }
    /// Absolute depth exists only when the chain reaches an observed root.
    func depth(_ key: Data) -> Int? {
        var current = key, visited = Set<Data>(), level = 0
        while let node = nodes[current] {
            guard visited.insert(current).inserted, level < 16 else { return nil }
            level += 1
            if node.directRoot { return level }
            guard let parent = node.parent else { return nil }; current = parent
        }
        return nil
    }
    /// New ancestors can extend previously unresolved edges, so validate every
    /// bounded chain, not just the newly inserted node. Reject cycles and >16
    /// observed hops without guessing who an unknown endpoint represents.
    private func validGraph() -> Bool {
        for key in nodes.keys {
            var current = key, visited = Set<Data>(), level = 0
            while let node = nodes[current] {
                guard visited.insert(current).inserted, level < 16 else { return false }
                level += 1
                guard let parent = node.parent else { break }; current = parent
            }
        }
        return true
    }
    mutating func begin(_ link: Link, signature: Data, totalNodes: Int) -> Node? {
        let key = Data(link.id.utf8)
        if var previous = nodes[key] {
            guard previous.parent == link.parent, previous.directRoot == link.directRoot else { return nil }
            if previous.signature != signature { previous.resultItemID = UUID().uuidString }
            previous.signature = signature; previous.requestID = UUID().uuidString
            nodes[key] = previous; return previous
        }
        guard nodes.count < 128, totalNodes < 1024 else { limited = true; return nil }
        let node = Node(id: link.id, parent: link.parent, directRoot: link.directRoot, signature: signature,
                        requestID: UUID().uuidString, resultItemID: UUID().uuidString)
        nodes[key] = node
        guard validGraph() else { nodes.removeValue(forKey: key); limited = true; return nil }
        return node
    }
    mutating func finish(_ id: String, requestID: String, final: Bool) -> Node? {
        let key = Data(id.utf8)
        guard var node = nodes[key], node.requestID == requestID else { return nil }
        node.requestID = nil; node.hasFinal = node.hasFinal || final; nodes[key] = node
        return node
    }
}
