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
        public let itemCount: Int
        public let truncated: Bool
        public let status: String
        init(_ source: ConversationSummary) {
            id = source.id; agent = source.key.agent; herdrSession = source.key.herdrSession
            nativeSession = source.key.nativeSession; paneID = source.context.paneID; terminalID = source.context.terminalID
            revision = source.revision; itemCount = source.itemCount; truncated = source.truncated; status = Self.status(source.status)
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
        public let status: String
        public let truncated: Bool
        public let blocks: [Block]
        init(_ source: ConversationItem) {
            id = source.id; role = source.message.role.rawValue; status = Summary.status(source.status)
            truncated = source.message.truncated; blocks = source.message.blocks.map(Block.init)
            switch source.origin {
            case .reconstructed: origin = "reconstructed"; compaction = nil
            case .observed: origin = "observed"; compaction = nil
            case .response: origin = "response"; compaction = nil
            case .summary: origin = "summary"; compaction = nil
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
            case "conversation.read":
                guard let conversationID = p?.conversationID, (1...64).contains(p?.limit ?? 16) else {
                    throw AgentProxyControlError(code: .invalidParams, message: "A conversation ID and limit 1...64 are required.")
                }
                guard let snapshot = store.read(id: conversationID) else { return encode(id, reset(store, "not_found")) }
                var end = snapshot.items.count
                if let before = p?.beforeItemID {
                    guard let index = snapshot.items.firstIndex(where: { same($0.id, before) }) else { return encode(id, reset(store, "anchor_removed")) }
                    end = index
                }
                var start = end, bytes = 0
                while start > 0 && end - start < (p?.limit ?? 16) {
                    let item = snapshot.items[start - 1]
                    // A single maximum-size assistant item may exceed pageBytes
                    // by its bounded metadata allowance; never split its text.
                    if start < end && item.cost > pageBytes - min(pageBytes, bytes) { break }
                    bytes += item.cost; start -= 1
                }
                result.summary = Summary(snapshot.summary)
                result.items = snapshot.items[start..<end].map(Item.init)
                result.nextBeforeItemID = start > 0 ? snapshot.items[start].id : nil
            default: throw AgentProxyControlError(code: .unknownMethod, message: "Unknown read method.")
            }
            let encoded = encode(id, result)
            return encoded.count <= maximumReplyBytes ? encoded : encode(id, reset(store, "reply_too_large"))
        } catch let error as AgentProxyControlError { return encodeError(id, error) }
        catch { return encodeError(id, AgentProxyControlError(code: .parseError, message: "Invalid JSON request.")) }
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
