import Foundation
import CryptoKit

/// Reconciles requests already classified as MAIN by a trusted capture layer.
/// It does not classify provider headers or make auxiliary requests into main
/// conversations. Full request histories replace the previous response's
/// provisional representation; Responses continuations append incremental input.
///
/// Tickets bind response updates to one request and store epoch. Superseded,
/// finished or evicted requests cannot overwrite/recreate a conversation.
/// Metadata is bounded by the store's <=256 conversations and <=200 SHA-256
/// message fingerprints per conversation. No raw requests/responses/headers
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
    public enum Failure: Error { case invalidProjection, invalidResponse }
    private struct State: Sendable {
        var requestID: String?
        let signature: Data
        let fingerprints: [Data]
        let truncated: Bool
        let responseItemID: String
        var lastResponseID: String?
    }
    public private(set) var store: ConversationStore
    private var states: [String: State] = [:]

    public init(limits: ConversationStore.Limits = .init()) { store = ConversationStore(limits: limits) }
    public var trackedConversationCount: Int { states.count }
    public var retainedFingerprintCount: Int { states.values.reduce(0) { $0 + $1.fingerprints.count } }

    public mutating func beginMain(key: ConversationKey, context: ConversationContext, request: CapturedRequest) throws -> Begin {
        guard request.messages.count <= ConversationCaptureLimits.reconstructedHistoryItems,
              request.messages.reduce(0, { $0 + $1.cost }) <= ConversationCaptureLimits.conversation,
              request.previousResponseID == nil || RequestProjection.identifier(request.previousResponseID) != nil else {
            throw Failure.invalidProjection
        }
        let fingerprints = request.messages.map(Self.fingerprint)
        let signature = Self.signature(fingerprints, previous: request.previousResponseID)
        let old = store.read(key: key)
        let prior = old.flatMap { states[$0.summary.id] }
        let retry = prior.map { $0.signature == signature && !$0.truncated && !request.truncated } ?? false
        var items = old?.items ?? []
        var suffix = request.messages[...]
        var discontinuity = prior == nil && request.previousResponseID != nil
        var reconstructed = prior == nil
        var responseItemID = UUID().uuidString

        if let prior {
            if retry {
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
                                      historyTruncated: request.truncated || discontinuity)
        prune(update.evictedConversationIDs)
        let ticket = Ticket(conversationID: update.conversationID, requestID: UUID().uuidString, epoch: store.epoch)
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

    private mutating func prune(_ ids: [String]) {
        for id in ids { states.removeValue(forKey: id) }
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
