import Foundation
import CryptoKit

/// Reconciles requests already classified as MAIN by a trusted capture layer.
/// It does not classify provider headers or make auxiliary requests into main
/// conversations. Full request histories replace the previous response's
/// provisional representation; Responses continuations append incremental input.
///
/// Tickets bind response updates to one request and store epoch. Superseded,
/// finished or evicted requests cannot overwrite/recreate a conversation.
/// Metadata is bounded by the store's <=256 conversations, <=200 SHA-256
/// message fingerprints, one selected owner and one pending compaction per
/// conversation. No raw requests/responses/headers
/// are retained outside the bounded store.
public nonisolated struct ConversationReconciler: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let conversationID: String
        public let requestID: String
        public let epoch: String
    }
    public struct Begin: Sendable {
        public let ticket: Ticket
        public let isRetry: Bool
        public let discontinuity: Bool
        public let evictedConversationIDs: [String]
    }
    public struct Applied: Sendable {
        public let evictedConversationIDs: [String]
    }
    public struct CompactionTicket: Equatable, Sendable {
        public let conversationID: String
        public let requestID: String
        public let epoch: String
    }
    public struct SubagentTicket: Equatable, Sendable {
        public let conversationID: String
        public let childID: String
        public let requestID: String
        public let epoch: String
    }
    public enum Failure: Error { case invalidProjection, invalidResponse, invalidClassification }
    private struct PendingCompaction: Sendable {
        let requestID: String
        let classification: ClassifiedRequest
    }
    private struct State: Sendable {
        var requestID: String?
        let signature: Data
        let fingerprints: [Data]
        let truncated: Bool
        let responseItemID: String
        var lastResponseID: String?
        var owner: ConversationOwner?
        var compaction: PendingCompaction?
        var didCompact = false
    }
    public private(set) var store: ConversationStore
    private var states: [String: State] = [:]
    private var childTrees: [String: ConversationSubagentTree] = [:]
    public var trackedSubagentCount: Int { childTrees.values.reduce(0) { $0 + $1.nodes.count } }

    public init(limits: ConversationStore.Limits = .init()) { store = ConversationStore(limits: limits) }
    public var trackedConversationCount: Int { states.count }
    public var retainedFingerprintCount: Int { states.values.reduce(0) { $0 + $1.fingerprints.count } }

    /// Preferred recorder entry point: validate main ownership and remember
    /// just the selected IDs required for later compaction/child correlation.
    public mutating func beginMain(classification: ClassifiedRequest, request: CapturedRequest) throws -> Begin {
        guard let owner = ConversationOwner(classification: classification) else { throw Failure.invalidClassification }
        let previous = store.read(key: owner.key).flatMap { childTrees[$0.summary.id] }
        let tree = previous.flatMap { $0.owner.matches(owner) ? $0 : nil } ?? ConversationSubagentTree(owner: owner)
        let begin = try beginMain(key: owner.key, context: owner.context, request: request, subagents: tree.stats)
        states[begin.ticket.conversationID]?.owner = owner
        childTrees[begin.ticket.conversationID] = tree
        return begin
    }

    /// Low-level entry point for already trusted projections. Without an
    /// observed classification it does NOT authorize auxiliary writes.
    public mutating func beginMain(key: ConversationKey, context: ConversationContext, request: CapturedRequest,
                                   subagents: ConversationSubagents? = nil) throws -> Begin {
        guard request.messages.count <= ConversationCaptureLimits.reconstructedHistoryItems,
              request.messages.reduce(0, { $0 + $1.cost }) <= ConversationCaptureLimits.conversation,
              request.previousResponseID == nil || RequestProjection.identifier(request.previousResponseID) != nil else {
            throw Failure.invalidProjection
        }
        let fingerprints = request.messages.map(Self.fingerprint)
        let signature = Self.signature(fingerprints, previous: request.previousResponseID)
        let old = store.read(key: key)
        let prior = old.flatMap { states[$0.summary.id] }
        let retry = prior.map { !$0.didCompact && $0.signature == signature && !$0.truncated && !request.truncated } ?? false
        var items = old?.items ?? []
        var suffix = request.messages[...]
        var discontinuity = prior == nil && request.previousResponseID != nil
        var reconstructed = prior == nil
        var responseItemID = UUID().uuidString

        if let prior {
            if prior.didCompact && prior.signature == signature {
                // A summary response does not prove the caller applied it. If
                // the next request still has identical context, preserve the
                // boundary without duplicating the entire old history.
                suffix = request.messages[request.messages.endIndex...]
            } else if prior.didCompact {
                // The old reply belongs BEFORE the compaction boundary. Do not
                // remove/move it as a provisional response or mistake a rebuilt
                // context for a retry. Preserve history and label reconstruction.
                discontinuity = true
                reconstructed = true
            } else if retry {
                suffix = request.messages[request.messages.endIndex...]
                responseItemID = prior.responseItemID
            } else if let previous = request.previousResponseID {
                // Do not drop the last response: this request contains only
                // new input, not its authoritative replacement history.
                discontinuity = prior.lastResponseID.map { !$0.utf8.elementsEqual(previous.utf8) } ?? true
                reconstructed = discontinuity
            } else if let end = Self.overlapEnd(previous: prior.fingerprints, current: fingerprints,
                                                 previousTruncated: prior.truncated, currentTruncated: request.truncated) {
                items.removeAll { $0.id == prior.responseItemID }
                suffix = request.messages[end...]
            } else {
                // Do not guess which repeated text is an old turn. Preserve
                // existing history and mark the new reconstruction boundary.
                discontinuity = true
                reconstructed = true
            }
            // A superseded provisional response cannot remain "streaming"
            // forever. A subsequent owned update can replace this item.
            items = items.map { item in
                guard item.id == prior.responseItemID, item.status == .streaming else { return item }
                return ConversationItem(id: item.id, message: item.message, origin: item.origin, status: .incomplete)
            }
        }
        if discontinuity {
            let marker = CapturedMessage(role: .assistant,
                                         blocks: [CapturedBlock(kind: .text, text: "", callID: nil, toolName: nil)], truncated: false)
            // UI renders a localized boundary from the typed origin, not a
            // hard-coded English message embedded in captured conversation text.
            items.append(ConversationItem(id: UUID().uuidString, message: marker, origin: .discontinuity, status: .complete))
        }
        for message in suffix {
            items.append(ConversationItem(id: UUID().uuidString, message: message,
                                          origin: reconstructed ? .reconstructed : .observed, status: .complete))
        }
        let update = try store.upsert(key: key, context: context, items: items, status: .streaming,
                                      historyTruncated: request.truncated || discontinuity, subagents: subagents)
        prune(update.evictedConversationIDs)
        let ticket = Ticket(conversationID: update.conversationID, requestID: UUID().uuidString, epoch: store.epoch)
        childTrees.removeValue(forKey: ticket.conversationID) // low-level callers do not confer ownership
        states[ticket.conversationID] = State(requestID: ticket.requestID, signature: signature, fingerprints: fingerprints,
                                              truncated: request.truncated, responseItemID: responseItemID,
                                              lastResponseID: prior?.lastResponseID)
        return Begin(ticket: ticket, isRetry: retry, discontinuity: discontinuity,
                     evictedConversationIDs: update.evictedConversationIDs)
    }

    /// Pass finished=true only after the tee ends and the assembler has been
    /// finalized with its transport outcome. A still-streaming snapshot on a
    /// finish is conservatively incomplete. nil means stale/unowned, not error.
    @discardableResult
    public mutating func apply(_ response: CapturedResponse, ticket: Ticket, finished: Bool = false) throws -> Applied? {
        guard ticket.epoch == store.epoch, var state = states[ticket.conversationID], state.requestID == ticket.requestID,
              let old = store.read(id: ticket.conversationID) else { return nil }
        guard response.responseID == nil || RequestProjection.identifier(response.responseID) != nil else { throw Failure.invalidResponse }
        var items = old.items.filter { $0.id != state.responseItemID }
        let status: CapturedResponse.Status = finished && response.status == .streaming ? .incomplete : response.status
        if !response.blocks.isEmpty {
            let message = CapturedMessage(role: .assistant, blocks: response.blocks, truncated: response.truncated)
            items.append(ConversationItem(id: state.responseItemID, message: message, origin: .response, status: status))
        }
        let update = try store.upsert(key: old.summary.key, context: old.summary.context, items: items,
                                      status: status, historyTruncated: response.truncated)
        prune(update.evictedConversationIDs)
        if response.responseID != nil { state.lastResponseID = response.responseID }
        if finished { state.requestID = nil }
        if update.conversationID == ticket.conversationID && ticket.epoch == store.epoch {
            states[ticket.conversationID] = state
        }
        return Applied(evictedConversationIDs: update.evictedConversationIDs)
    }

    /// No new conversation is created by a compaction. An active main request,
    /// absent owner, moved route, child context or unknown ID fails closed.
    /// A retry supersedes the previous compaction ticket without growing state.
    public mutating func beginCompaction(classification: ClassifiedRequest) -> CompactionTicket? {
        guard classification.kind == .compaction, let route = classification.route,
              let native = classification.nativeSessionID,
              let key = ConversationKey(agent: route.kind.rawValue, herdrSession: route.session, nativeSession: native),
              let old = store.read(key: key), var state = states[old.summary.id], state.requestID == nil,
              state.owner?.ownsCompaction(classification) == true else { return nil }
        let id = UUID().uuidString
        state.compaction = PendingCompaction(requestID: id, classification: classification)
        states[old.summary.id] = state
        return CompactionTicket(conversationID: old.summary.id, requestID: id, epoch: store.epoch)
    }

    /// Finalize exactly once at tee end. All existing visible history is kept
    /// subject to the existing store limits; opaque output never replaces it.
    @discardableResult
    public mutating func completeCompaction(_ response: CapturedResponse, ticket: CompactionTicket,
                                            transportComplete: Bool) throws -> Applied? {
        guard ticket.epoch == store.epoch, var state = states[ticket.conversationID],
              let pending = state.compaction, pending.requestID == ticket.requestID, state.requestID == nil,
              let old = store.read(id: ticket.conversationID),
              let summary = CompactionProjection.project(response, classification: pending.classification,
                                                         transportComplete: transportComplete) else { return nil }
        let marker = CapturedMessage(role: .assistant,
            blocks: [CapturedBlock(kind: .text, text: "", callID: nil, toolName: nil)], truncated: false)
        var items = old.items
        items.append(ConversationItem(id: UUID().uuidString, message: marker,
                                      origin: .compaction(summary.availability), status: summary.status))
        if let text = summary.text {
            let message = CapturedMessage(role: .assistant,
                blocks: [CapturedBlock(kind: .text, text: text, callID: nil, toolName: nil)], truncated: summary.truncated)
            items.append(ConversationItem(id: UUID().uuidString, message: message, origin: .summary, status: summary.status))
        }
        let update = try store.upsert(key: old.summary.key, context: old.summary.context, items: items,
                                      status: summary.status, historyTruncated: summary.truncated)
        prune(update.evictedConversationIDs)
        state.compaction = nil
        if summary.status == .complete {
            state.didCompact = true
            state.lastResponseID = nil
        }
        if update.conversationID == ticket.conversationID && ticket.epoch == store.epoch {
            states[ticket.conversationID] = state
        }
        return Applied(evictedConversationIDs: update.evictedConversationIDs)
    }

    /// Count only explicitly linked children. Unknown parents, cycles, moved
    /// routes and ambiguous roots are not guessed from shared native IDs.
    public mutating func beginSubagent(classification: ClassifiedRequest, requestBody: Data) throws -> SubagentTicket? {
        guard classification.kind == .subagent, requestBody.count <= ConversationCaptureLimits.decompressedRequest else { return nil }
        var candidates: [(String, ConversationSubagentTree.Link)] = []
        for (id, tree) in childTrees {
            guard let owner = states[id]?.owner, tree.owner.matches(owner), store.read(id: id) != nil,
                  let link = tree.link(classification) else { continue }
            candidates.append((id, link))
            if candidates.count > 1 { return nil }
        }
        guard let (id, link) = candidates.first, var tree = childTrees[id], let old = store.read(id: id) else { return nil }
        let node = tree.begin(link, signature: Data(SHA256.hash(data: requestBody)), totalNodes: trackedSubagentCount)
        let update = try store.upsert(key: old.summary.key, context: old.summary.context, items: old.items,
                                      status: old.summary.status, subagents: tree.stats)
        prune(update.evictedConversationIDs)
        guard update.conversationID == id, states[id] != nil else { return nil }
        childTrees[id] = tree
        guard let node, let requestID = node.requestID else { return nil }
        return SubagentTicket(conversationID: id, childID: node.id, requestID: requestID, epoch: store.epoch)
    }

    /// Child content is never streamed into main. Only provider-declared final
    /// text at successful tee completion is retained, capped at16KiB. A complete
    /// tool turn/HTTP response is not a final result and says nothing about exit.
    public mutating func completeSubagent(_ response: CapturedResponse, ticket: SubagentTicket,
                                          transportComplete: Bool) throws -> Applied? {
        guard ticket.epoch == store.epoch, var tree = childTrees[ticket.conversationID],
              let state = states[ticket.conversationID], let owner = state.owner, tree.owner.matches(owner),
              let old = store.read(id: ticket.conversationID) else { return nil }
        let final = transportComplete && response.status == .complete && response.isFinalAnswer
        guard let node = tree.finish(ticket.childID, requestID: ticket.requestID, final: final) else { return nil }
        var items = old.items
        if final {
            var text = "", truncated = response.truncated
            for block in response.blocks where block.kind == .text && !block.text.isEmpty {
                let candidate = (text.isEmpty ? "" : "\n") + block.text
                let prefix = ConversationCaptureLimits.textPrefix(candidate, maximumBytes: max(0, ConversationCaptureLimits.toolText - text.utf8.count))
                text += prefix
                if prefix.utf8.count < candidate.utf8.count { truncated = true }
            }
            let message = CapturedMessage(role: .assistant, blocks: [CapturedBlock(kind: .text, text: text, callID: nil, toolName: nil)], truncated: truncated)
            let item = ConversationItem(id: node.resultItemID, message: message,
                                        origin: .subagent(id: node.id, depth: tree.depth(Data(node.id.utf8))), status: .complete)
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
            else if state.requestID != nil, items.last?.id == state.responseItemID { items.insert(item, at: items.count - 1) }
            else { items.append(item) }
        }
        let update = try store.upsert(key: old.summary.key, context: old.summary.context, items: items,
                                      status: old.summary.status, subagents: tree.stats)
        prune(update.evictedConversationIDs)
        if update.conversationID == ticket.conversationID && store.epoch == ticket.epoch { childTrees[ticket.conversationID] = tree }
        return Applied(evictedConversationIDs: update.evictedConversationIDs)
    }

    public mutating func evictOldest() -> [String] {
        let ids = store.evictOldest()
        prune(ids)
        return ids
    }

    private mutating func prune(_ ids: [String]) {
        for id in ids { states.removeValue(forKey: id); childTrees.removeValue(forKey: id) }
    }

    private static func overlapEnd(previous: [Data], current: [Data], previousTruncated: Bool, currentTruncated: Bool) -> Int? {
        if !previousTruncated && !currentTruncated {
            return current.starts(with: previous) ? previous.count : nil
        }
        // A single repeated user message is not enough to establish a rolling
        // history anchor. Longer ambiguous tails also get a boundary, not a guess.
        let tail = Array(previous.suffix(8))
        guard tail.count >= 2, current.count >= tail.count else { return nil }
        var match: Int?
        for start in 0...(current.count - tail.count) where current[start..<(start + tail.count)].elementsEqual(tail) {
            guard match == nil else { return nil }
            match = start + tail.count
        }
        return match
    }

    private static func signature(_ fingerprints: [Data], previous: String?) -> Data {
        var data = Data()
        field(previous ?? "", to: &data)
        for fingerprint in fingerprints { data.append(fingerprint) }
        return Data(SHA256.hash(data: data))
    }

    private static func fingerprint(_ message: CapturedMessage) -> Data {
        var data = Data()
        field(message.role.rawValue, to: &data)
        field(message.truncated ? "truncated" : "complete", to: &data)
        for block in message.blocks {
            field(block.kind.rawValue, to: &data)
            field(block.callID ?? "", to: &data)
            field(block.toolName ?? "", to: &data)
            var text = block.text
            if block.kind == .toolCall, let object = try? RequestProjection.decodeObject(Data(text.utf8)),
               let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let canonical = CaptureUTF8.decode(encoded) { text = canonical }
            field(text, to: &data)
        }
        return Data(SHA256.hash(data: data))
    }

    private static func field(_ text: String, to data: inout Data) {
        var length = UInt64(text.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(contentsOf: text.utf8)
    }
}
