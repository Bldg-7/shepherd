import Foundation
import AgentProxyCore
import AgentProxyProtocol

public typealias ConversationPage = ConversationReadAPI.Result
public typealias ConversationHeader = ConversationReadAPI.Summary
public typealias ConversationMessage = ConversationReadAPI.Item

public nonisolated enum ConversationClientError: Error {
    case invalidReply, reset, unsupportedVersion, scopeMismatch
}

/// Native identity takes precedence. A terminal is only a fallback when herdr
/// has no usable native ID; never select a different session just because the
/// requested native session has not been captured yet.
public nonisolated struct ConversationSelection: Sendable, Equatable {
    public let terminalID: String
    public let herdrSession: String
    public let agent: String?
    public let nativeSession: String?
    public init(terminalID: String, herdrSession: String, agent: String?, nativeSession: String?) {
        self.terminalID = terminalID; self.herdrSession = herdrSession.isEmpty ? "default" : herdrSession
        self.agent = agent; self.nativeSession = nativeSession
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        wireEqual(lhs.terminalID, rhs.terminalID) && wireEqual(lhs.herdrSession, rhs.herdrSession)
            && lhs.agent.map({ Data($0.utf8) }) == rhs.agent.map({ Data($0.utf8) })
            && lhs.nativeSession.map({ Data($0.utf8) }) == rhs.nativeSession.map({ Data($0.utf8) })
    }
    var params: [String: String] {
        var params = ["herdrSession": herdrSession]
        if let agent { params["agent"] = agent }
        if let nativeSession, agent != nil { params["nativeSession"] = nativeSession }
        else { params["terminalID"] = terminalID }
        return params
    }
    public func matches(_ header: ConversationHeader) -> Bool {
        guard header.origin == nil, header.hc == nil, wireEqual(herdrSession, header.herdrSession), agent.map({ wireEqual($0, header.agent) }) ?? true else { return false }
        if let nativeSession, agent != nil { return wireEqual(nativeSession, header.nativeSession) }
        return wireEqual(terminalID, header.terminalID)
    }
}

/// Read-only hc selection after the coordinator has an exact known binding.
/// Native ID, when explicit, never falls back to another terminal's archive.
/// This value is capture correlation only, never native input/resume authority.
public nonisolated struct HcConversationSelection: Sendable, Equatable {
    public let binding: AgentProxyHcCaptureBinding
    public let agent: String
    public let nativeSession: String?
    public init?(binding: AgentProxyHcCaptureBinding, agent: String, nativeSession: String? = nil) {
        guard AgentProxyRouteKind(rawValue:agent) != nil, nativeSession.map(ConversationWire.validID) ?? true else { return nil }
        self.binding = binding; self.agent = agent; self.nativeSession = nativeSession
    }
    public static func == (left: Self, right: Self) -> Bool {
        left.binding == right.binding && left.agent == right.agent && left.nativeSession.map { Data($0.utf8) } == right.nativeSession.map { Data($0.utf8) }
    }
    var params: [String:String] {
        var p = ["hcCoreID":binding.intent.originCoreID,"agent":agent]
        if let nativeSession { p["nativeSession"] = nativeSession }
        else { p["hcLaunchID"] = binding.intent.launchID.uuidString }
        return p
    }
    public func matches(_ header: ConversationHeader) -> Bool {
        guard header.herdrSession == nil, header.origin?.backend == .hc,
              header.origin?.value == binding.intent.originCoreID, header.agent == agent, let hc = header.hc,
              hc.intent.originCoreID == binding.intent.originCoreID, hc.kind.rawValue == agent,
              header.paneID == hc.intent.paneID.uuidString, header.terminalID == hc.binding?.terminalID else { return false }
        if let nativeSession { return wireEqual(nativeSession,header.nativeSession) }
        return hc.intent == binding.intent && (hc.binding == nil || hc.binding == binding)
    }
}

/// Exact record selected from an explicit archive list. Epoch/opaque record ID
/// remain distinct from native session identity or any terminal routing grant.
public nonisolated struct ConversationArchiveSelection: Sendable, Equatable {
    public let id: String
    public let epoch: String
    public let key: ConversationKey
    public init?(header: ConversationHeader, epoch: String) {
        guard ConversationWire.validID(header.id), ConversationWire.validID(epoch), let key = ConversationWire.key(header) else { return nil }
        id = header.id; self.epoch = epoch; self.key = key
    }
    public static func == (left: Self, right: Self) -> Bool { wireEqual(left.id,right.id) && wireEqual(left.epoch,right.epoch) && left.key == right.key }
    public func matches(_ header: ConversationHeader) -> Bool { wireEqual(id,header.id) && ConversationWire.key(header) == key }
}

public actor ConversationClient {
    private let transport: any ConversationLineTransport
    private let endpoint: HerdrLineEndpoint
    public init(transport: any ConversationLineTransport, endpoint: HerdrLineEndpoint = .conversations) {
        self.transport = transport; self.endpoint = endpoint
    }
    /// Explicit history browsing, never a label/terminal-ID match to a new core.
    public func list() async throws -> (conversations: [ConversationHeader], epoch: String) {
        let result = try await query("conversations.list", [:])
        guard let headers = result.conversations else { throw ConversationClientError.invalidReply }
        return (headers, result.epoch)
    }
    public func select(_ selection: ConversationSelection) async throws -> (header: ConversationHeader, epoch: String)? {
        let result = try await query("conversations.list", selection.params)
        guard let headers = result.conversations, headers.allSatisfy(selection.matches) else { throw ConversationClientError.scopeMismatch }
        guard let latest = headers.max(by: { $0.revision < $1.revision }) else { return nil }
        return (latest, result.epoch)
    }
    public func select(_ selection: HcConversationSelection) async throws -> (header: ConversationHeader, epoch: String)? {
        let result = try await query("conversations.list",selection.params)
        guard let headers = result.conversations, headers.allSatisfy(selection.matches) else { throw ConversationClientError.scopeMismatch }
        guard let latest = headers.max(by:{ $0.revision < $1.revision }) else { return nil }
        return (latest,result.epoch)
    }
    public func read(id: String, epoch: String, before: String? = nil) async throws -> ConversationPage {
        var params = ["conversationID": id, "epoch": epoch]
        if let before { params["beforeItemID"] = before }
        let result = try await query("conversation.read", params)
        guard wireEqual(result.epoch, epoch), let summary = result.summary, wireEqual(summary.id, id), result.items != nil else { throw ConversationClientError.scopeMismatch }
        return result
    }
    public func subscribe(id: String, epoch: String) async throws -> ConversationUpdates {
        let requestID = UUID().uuidString
        let stream = try await transport.openLineStream(endpoint: endpoint,
            request: Self.request(requestID, "conversation.subscribe", ["conversationID": id, "epoch": epoch]))
        return ConversationUpdates(stream: stream, requestID: requestID, conversationID: id, epoch: epoch)
    }
    private func query(_ method: String, _ params: [String: String]) async throws -> ConversationPage {
        let id = UUID().uuidString
        let stream = try await transport.openLineStream(endpoint: endpoint, request: Self.request(id, method, params))
        defer { stream.close() }
        var iterator = stream.lines.makeAsyncIterator()
        guard let line = try await iterator.next() else { throw HerdrLineStreamError.closed }
        try Task.checkCancellation()
        let result = try ConversationWire.reply(line, id: id)
        guard !result.reset else { throw ConversationClientError.reset }
        return result
    }
    private static func request(_ id: String, _ method: String, _ params: [String: String]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        bytes.append(10)
        guard bytes.count <= 64 << 10 else { throw HerdrLineStreamError.invalidRequest }
        return bytes
    }
}

/// Lazy decoding avoids another producer task/queue of full conversation pages.
/// Cancel iteration or call close when the view/session/connection changes.
public nonisolated struct ConversationUpdates: AsyncSequence, Sendable {
    public typealias Element = ConversationPage
    let stream: HerdrLineStream
    let requestID: String
    let conversationID: String
    let epoch: String
    public func close() { stream.close() }
    public func makeAsyncIterator() -> Iterator {
        Iterator(inner: stream.lines.makeAsyncIterator(), requestID: requestID, conversationID: conversationID, epoch: epoch)
    }
    public struct Iterator: AsyncIteratorProtocol {
        var inner: AsyncThrowingStream<Data, any Error>.Iterator
        let requestID: String
        let conversationID: String
        let epoch: String
        var initial = true
        // The iOS 17 AsyncThrowingStream iterator uses the generic executor.
        // Keep this value-owned iterator there too; don't send an actor-isolated
        // stored iterator out of a caller-inheriting next() under Swift 6.
        @concurrent public mutating func next() async throws -> ConversationPage? {
            guard let line = try await inner.next() else { return nil }
            try Task.checkCancellation()
            let result: ConversationPage
            if initial { result = try ConversationWire.reply(line, id: requestID); initial = false }
            else {
                struct Event: Decodable { let method: String; let params: ConversationPage }
                let event = try ConversationReadAPI.decodeWire(Event.self, from: line)
                guard event.method == "conversation.update" else { throw ConversationClientError.invalidReply }
                result = event.params; try ConversationWire.validate(result)
            }
            guard wireEqual(result.epoch, epoch), let summary = result.summary, wireEqual(summary.id, conversationID), result.items != nil else {
                throw ConversationClientError.reset
            }
            return result
        }
    }
}

nonisolated func wireEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
nonisolated func wireEqual(_ a: String, _ b: String?) -> Bool { guard let b else { return false }; return wireEqual(a,b) }

nonisolated enum ConversationWire {
    static func reply(_ data: Data, id: String) throws -> ConversationPage {
        let reply = try ConversationReadAPI.decodeWire(ConversationReadAPI.Reply.self, from: data)
        guard let echoed = reply.id, wireEqual(echoed, id), reply.error == nil, let result = reply.result else { throw ConversationClientError.invalidReply }
        try validate(result); return result
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func key(_ header: ConversationHeader) -> ConversationKey? {
        if let hc = header.hc {
            guard let origin = header.origin, origin.backend == .hc, header.herdrSession == nil,
                  origin.value == hc.intent.originCoreID, header.agent == hc.kind.rawValue,
                  header.paneID == hc.intent.paneID.uuidString, header.terminalID == hc.binding?.terminalID else { return nil }
            return ConversationKey(agent:header.agent,origin:origin,nativeSession:header.nativeSession)
        }
        guard header.origin == nil, let legacy = header.herdrSession, let terminal = header.terminalID,validID(terminal) else { return nil }
        return ConversationKey(agent:header.agent,herdrSession:legacy,nativeSession:header.nativeSession)
    }
    static func validate(_ result: ConversationPage) throws {
        guard result.protocolVersion == ConversationReadAPI.protocolVersion else { throw ConversationClientError.unsupportedVersion }
        guard validID(result.epoch), result.reason.map({ $0.utf8.count <= 64 }) ?? true,
              result.nextBeforeItemID.map(validID) ?? true, result.replaceFromItemID.map(validID) ?? true else { throw ConversationClientError.invalidReply }
        let headers = (result.conversations ?? []) + (result.summary.map { [$0] } ?? [])
        guard headers.count <= 256 else { throw ConversationClientError.invalidReply }
        for header in headers {
            guard [header.id,header.agent,header.nativeSession,header.paneID].allSatisfy(validID),
                  ["claude", "codex", "pi"].contains(header.agent), (0...4096).contains(header.itemCount),
                  header.revision <= result.seq, header.historyRevision <= header.revision,
                  (0...128).contains(header.subagents.observed), (0...header.subagents.observed).contains(header.subagents.withFinalResult),
                  ["streaming", "complete", "incomplete"].contains(header.status) else { throw ConversationClientError.invalidReply }
            guard key(header) != nil else { throw ConversationClientError.invalidReply }
        }
        let items = result.items ?? []
        guard items.count <= 64, Set(items.map { Data($0.id.utf8) }).count == items.count else { throw ConversationClientError.invalidReply }
        for item in items {
            guard validID(item.id), ["user", "assistant", "tool"].contains(item.role),
                  ["observed", "reconstructed", "response", "summary", "discontinuity", "compaction", "subagent"].contains(item.origin),
                  ["streaming", "complete", "incomplete"].contains(item.status), !item.blocks.isEmpty, item.blocks.count <= 64,
                  item.compaction.map({ ["plaintext", "opaque", "no_text", "incomplete"].contains($0) }) ?? true else { throw ConversationClientError.invalidReply }
            guard (item.origin == "compaction") == (item.compaction != nil) else { throw ConversationClientError.invalidReply }
            if item.origin == "subagent" {
                guard let id = item.subagentID, validID(id), item.subagentDepth.map({ (1...16).contains($0) }) ?? true,
                      item.role == "assistant", item.blocks.reduce(0, { $0 + $1.text.utf8.count }) <= 16 << 10 else { throw ConversationClientError.invalidReply }
            } else if item.subagentID != nil || item.subagentDepth != nil { throw ConversationClientError.invalidReply }
            let limit = item.role == "assistant" ? 256 << 10 : (item.role == "tool" ? 16 << 10 : 64 << 10)
            var textBytes = 0
            for block in item.blocks {
                guard ["text", "image", "toolCall", "toolResult"].contains(block.kind), block.callID.map(validID) ?? true,
                      block.toolName.map(validID) ?? true, block.text.utf8.count <= limit - textBytes else { throw ConversationClientError.invalidReply }
                textBytes += block.text.utf8.count
                if block.kind == "image" && !block.text.isEmpty { throw ConversationClientError.invalidReply }
                if block.kind == "toolCall" || block.kind == "toolResult" {
                    guard block.callID != nil, block.text.utf8.count <= 16 << 10,
                          block.kind != "toolCall" || block.toolName != nil else { throw ConversationClientError.invalidReply }
                }
            }
        }
    }
}
