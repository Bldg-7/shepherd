import Foundation
import AgentProxyProtocol

/// Versioned read-only wire values. No headers, tokens, ciphertext or parser
/// objects. Snapshot paging uses stable item IDs, not offsets into a live array.
public nonisolated enum ConversationReadAPI {
    public static let protocolVersion = 1
    public static let maximumRequestBytes = 64 << 10
    public static let maximumReplyBytes = 2 << 20
    public static let pageBytes = 256 << 10

    public struct Summary: Codable, Equatable, Sendable {
        public let id: String
        public let agent: String
        public let herdrSession: String
        public let nativeSession: String
        public let paneID: String
        public let terminalID: String
        public let revision: UInt64
        public let historyRevision: UInt64
        public let itemCount: Int
        public let truncated: Bool
        public let status: String
        public let subagents: ConversationSubagents
        init(_ source: ConversationSummary) {
            id = source.id; agent = source.key.agent; herdrSession = source.key.herdrSession
            nativeSession = source.key.nativeSession; paneID = source.context.paneID; terminalID = source.context.terminalID
            subagents = source.subagents
            revision = source.revision; historyRevision = source.historyRevision; itemCount = source.itemCount; truncated = source.truncated; status = Self.status(source.status)
        }
        static func status(_ value: CapturedResponse.Status) -> String {
            switch value { case .streaming: return "streaming"; case .complete: return "complete"; case .incomplete: return "incomplete" }
        }
    }
    public struct Block: Codable, Equatable, Sendable {
        public let kind: String
        public let text: String
        public let callID: String?
        public let toolName: String?
        init(_ source: CapturedBlock) {
            kind = source.kind.rawValue; text = source.text; callID = source.callID; toolName = source.toolName
        }
    }
    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let role: String
        public let origin: String
        public let compaction: String?
        public let subagentID: String?
        public let subagentDepth: Int?
        public let status: String
        public let truncated: Bool
        public let blocks: [Block]
        init(_ source: ConversationItem) {
            id = source.id; role = source.message.role.rawValue; status = Summary.status(source.status)
            truncated = source.message.truncated; blocks = source.message.blocks.map(Block.init)
            if case .subagent(let id, let depth) = source.origin { subagentID = id; subagentDepth = depth }
            else { subagentID = nil; subagentDepth = nil }
            switch source.origin {
            case .reconstructed: origin = "reconstructed"; compaction = nil
            case .observed: origin = "observed"; compaction = nil
            case .response: origin = "response"; compaction = nil
            case .summary: origin = "summary"; compaction = nil
            case .subagent: origin = "subagent"; compaction = nil
            case .discontinuity: origin = "discontinuity"; compaction = nil
            case .compaction(let value):
                origin = "compaction"
                switch value {
                case .plaintext: compaction = "plaintext"
                case .opaque: compaction = "opaque"
                case .noText: compaction = "no_text"
                case .incomplete: compaction = "incomplete"
                }
            }
        }
    }
    public struct Result: Codable, Equatable, Sendable {
        public let protocolVersion: Int
        public let epoch: String
        public let seq: UInt64
        public var reset = false
        public var reason: String?
        public var conversations: [Summary]?
        public var summary: Summary?
        public var items: [Item]?
        /// Send this as beforeItemID to read the preceding page. nil means the
        /// oldest retained item was included, not that earlier history existed.
        public var nextBeforeItemID: String?
        /// A live update replaces the cached suffix starting at this item.
        /// Missing anchors/base sequence or reset=true require a fresh window.
        public var replaceFromItemID: String?
        public var baseSeq: UInt64?
        init(store: ConversationStore) { protocolVersion = ConversationReadAPI.protocolVersion; epoch = store.epoch; seq = store.sequence }
    }
    public struct Reply: Codable, Sendable {
        public let id: String?
        public let result: Result?
        public let error: AgentProxyControlError?
    }
    private struct Request: Decodable {
        let id: String
        let method: String
        let params: Params?
    }
    private struct Params: Decodable {
        let epoch: String?
        let conversationID: String?
        let beforeItemID: String?
        let limit: Int?
        let terminalID: String?
        let herdrSession: String?
        let nativeSession: String?
        let agent: String?
    }

    /// Caller must reserve request/encoding/write capacity before invoking and
    /// must never log the line or encoded reply. Returns one NDJSON line.
    public static func answer(_ line: Data, store: ConversationStore) -> Data {
        var id: String?
        do {
            guard line.count <= maximumRequestBytes else { throw AgentProxyControlError(code: .invalidParams, message: "Request too large.") }
            _ = try RequestProjection.decodeObject(line)
            let request = try JSONDecoder().decode(Request.self, from: line)
            guard RequestProjection.identifier(request.id) != nil else { throw AgentProxyControlError(code: .invalidParams, message: "Invalid request id.") }
            id = request.id
            let p = request.params
            for field in [p?.epoch, p?.conversationID, p?.beforeItemID, p?.terminalID, p?.herdrSession, p?.nativeSession, p?.agent] {
                if let field, RequestProjection.identifier(field) == nil { throw AgentProxyControlError(code: .invalidParams, message: "Invalid identifier.") }
            }
            if let epoch = p?.epoch, !same(epoch, store.epoch) { return encode(id, reset(store, "epoch_changed")) }
            var result = Result(store: store)
            switch request.method {
            case "conversations.list":
                result.conversations = store.list().filter { summary in
                    (p?.terminalID.map { same($0, summary.context.terminalID) } ?? true)
                    && (p?.herdrSession.map { same($0, summary.key.herdrSession) } ?? true)
                    && (p?.nativeSession.map { same($0, summary.key.nativeSession) } ?? true)
                    && (p?.agent.map { same($0, summary.key.agent) } ?? true)
                }.map(Summary.init)
            case "conversation.read", "conversation.subscribe":
                guard let conversationID = p?.conversationID, (1...64).contains(p?.limit ?? 16) else {
                    throw AgentProxyControlError(code: .invalidParams, message: "A conversation ID and limit 1...64 are required.")
                }
                guard request.method != "conversation.subscribe" || p?.beforeItemID == nil else {
                    throw AgentProxyControlError(code: .invalidParams, message: "Subscribe starts at the latest page.")
                }
                result = page(conversationID, before: p?.beforeItemID, limit: p?.limit ?? 16, store: store)
            default: throw AgentProxyControlError(code: .unknownMethod, message: "Unknown read method.")
            }
            let encoded = encode(id, result)
            return encoded.count <= maximumReplyBytes ? encoded : encode(id, reset(store, "reply_too_large"))
        } catch let error as AgentProxyControlError { return encodeError(id, error) }
        catch { return encodeError(id, AgentProxyControlError(code: .parseError, message: "Invalid JSON request.")) }
    }
    /// Only bounded identifiers/counters, never a retained snapshot per client.
    public struct Cursor: Sendable {
        public let conversationID: String
        public let epoch: String
        public let seq: UInt64
        public let revision: UInt64
        public let historyRevision: UInt64
        public let lastItemID: String?
        public init?(_ result: Result) {
            guard let summary = result.summary, result.items != nil else { return nil }
            conversationID = summary.id; epoch = result.epoch; seq = result.seq
            revision = summary.revision; historyRevision = summary.historyRevision
            lastItemID = result.items?.last?.id
        }
    }

    private static func page(_ id: String, before: String? = nil, limit: Int = 16, store: ConversationStore) -> Result {
        guard let snapshot = store.read(id: id) else { return reset(store, "not_found") }
        var end = snapshot.items.count
        if let before {
            guard let index = snapshot.items.firstIndex(where: { same($0.id, before) }) else { return reset(store, "anchor_removed") }
            end = index
        }
        var start = end, bytes = 0
        while start > 0 && end - start < limit {
            let item = snapshot.items[start - 1]
            if start < end && item.cost > pageBytes - min(pageBytes, bytes) { break }
            bytes += item.cost; start -= 1
        }
        var result = Result(store: store)
        result.summary = Summary(snapshot.summary)
        result.items = snapshot.items[start..<end].map(Item.init)
        result.nextBeforeItemID = start > 0 ? snapshot.items[start].id : nil
        return result
    }

    /// Coalesce any number of upstream changes into one bounded suffix patch.
    /// Host invokes at most once per 100ms, only after admitting encoding space.
    public static func update(after cursor: Cursor, store: ConversationStore) -> Result? {
        if !same(cursor.epoch, store.epoch) { return reset(store, "epoch_changed") }
        guard let snapshot = store.read(id: cursor.conversationID) else { return reset(store, "not_found") }
        guard snapshot.summary.revision != cursor.revision else { return nil }
        if snapshot.summary.historyRevision == cursor.historyRevision, let anchor = cursor.lastItemID,
           let index = snapshot.items.firstIndex(where: { same($0.id, anchor) }) {
            let suffix = snapshot.items[index...]
            if suffix.count <= 64 && (suffix.count == 1 || suffix.reduce(0, { $0 + $1.cost }) <= pageBytes) {
                var result = Result(store: store); result.summary = Summary(snapshot.summary)
                result.items = suffix.map(Item.init); result.replaceFromItemID = anchor; result.baseSeq = cursor.seq
                return result
            }
        }
        var result = page(cursor.conversationID, store: store)
        result.reset = true; result.reason = "history_changed"; result.baseSeq = cursor.seq
        return result
    }

    /// Shared client-side parser boundary: completed lines are bounded too,
    /// with the same depth/token/UTF-8 preflight as capture before Foundation.
    public static func decodeWire<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumReplyBytes else { throw RequestProjection.Failure.resourceLimit }
        _ = try RequestProjection.decodeObject(data)
        return try JSONDecoder().decode(type, from: data)
    }

    public static func encodeUpdate(_ result: Result) -> Data {
        struct Update: Encodable { let method = "conversation.update"; let params: Result }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = (try? encoder.encode(Update(params: result))) ?? Data("{}".utf8)
        bytes.append(10); return bytes
    }

    public static func reset(_ store: ConversationStore, _ reason: String) -> Result {
        var result = Result(store: store); result.reset = true; result.reason = reason; return result
    }
    public static func encode(_ id: String?, _ result: Result) -> Data {
        encodeReply(Reply(id: id, result: result, error: nil))
    }
    private static func encodeError(_ id: String?, _ error: AgentProxyControlError) -> Data {
        encodeReply(Reply(id: id, result: nil, error: error))
    }
    private static func encodeReply(_ reply: Reply) -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(reply)) ?? Data("{}".utf8)
        data.append(10); return data
    }
    private static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
}
