import Foundation

public nonisolated enum CoreRPCFailure: Error, Equatable, Sendable {
    case invalidLimits, closed, capacityExceeded, requestTooLarge, invalidMethod, invalidParameters
    case requestIDsExhausted, invalidReply, unexpectedReply, staleEpoch
}

/// Do not expose the server's free-text message/hint in status or logs. They
/// can contain paths, commands or user content. Keep only the stable error kind.
public nonisolated struct CoreRPCRemoteFailure: Error, Decodable, Equatable, Sendable {
    public let code: Int
    public let kind: String?
    private enum CodingKeys: String, CodingKey { case code, message, data }
    private struct Details: Decodable { let kind: String? }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        code = try fields.decode(Int.self, forKey: .code)
        _ = try fields.decode(String.self, forKey: .message)
        kind = try fields.decodeIfPresent(Details.self, forKey: .data)?.kind
        if let kind, !Self.isIdentifier(kind) { throw CoreRPCFailure.invalidReply }
    }

    static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 128 && text.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 46
        }
    }
}

/// Keeps the original response bytes: do not round a core document version,
/// sequence or ID through Double/Any while routing it. Decode a typed result
/// only at the consumer. JSON null is a legitimate result, not a missing one.
public nonisolated struct CoreRPCReply: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UInt64
    public let error: CoreRPCRemoteFailure?
    private let bytes: Data
    public var description: String { "<core RPC reply \(id)>" }
    public var debugDescription: String { description }

    public init(frame: CoreFrame) throws {
        guard frame.channel == 0, frame.kind == .data else { throw CoreRPCFailure.invalidReply }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: frame.payload) }
        catch { throw CoreRPCFailure.invalidReply }
        id = header.id
        error = header.error
        bytes = frame.payload
    }

    public func result<Value: Decodable & Sendable>(as type: Value.Type = Value.self) throws -> Value {
        if let error { throw error }
        return try JSONDecoder().decode(ResultEnvelope<Value>.self, from: bytes).result
    }

    private struct ResultEnvelope<Value: Decodable>: Decodable { let result: Value }
    private struct Header: Decodable {
        let id: UInt64
        let error: CoreRPCRemoteFailure?
        enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error, method }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard try fields.decode(String.self, forKey: .jsonrpc) == "2.0",
                  !fields.contains(.method), fields.contains(.result) != fields.contains(.error) else {
                throw CoreRPCFailure.invalidReply
            }
            id = try fields.decode(UInt64.self, forKey: .id)
            error = fields.contains(.error) ? try fields.decode(CoreRPCRemoteFailure.self, forKey: .error) : nil
        }
    }
}

/// Pure bookkeeping for ONE negotiated connection. Its owner serializes access
/// (normally an actor) and supplies time, sends returned frames and completes
/// continuations. No I/O, tasks, timers, retries or automatic CREDIT here.
///
/// Canceled/expired calls retain a bounded tombstone until a reply or close.
/// That preserves the original method for late attach/subscription cleanup;
/// never guess that an arbitrary result's `channel` field owns a stream.
/// This quota is NOT an outbound writer budget: a writer must separately bound
/// bytes it still holds, even after a caller cancels or a reply arrives.
public nonisolated struct CoreRPCRequests: Sendable {
    public struct Token: Hashable, Sendable {
        public let epoch: UUID
        public let id: UInt64
    }
    public struct Context: Sendable {
        public let token: Token
        public let method: String
        public let deadline: ContinuousClock.Instant
        public let payloadBytes: Int
    }
    public struct Request: Sendable {
        public let context: Context
        public let frame: CoreFrame
    }
    public enum Retirement: Equatable, Sendable { case cancelled, timedOut }
    public enum Delivery: Sendable {
        case reply(Context, CoreRPCReply)
        case late(Context, CoreRPCReply, Retirement)
    }
    private struct Entry: Sendable {
        let context: Context
        var retirement: Retirement?
    }

    public let epoch: UUID
    public let maximumRequests: Int
    public let maximumPendingPayloadBytes: Int
    public private(set) var pendingPayloadBytes = 0
    public var occupiedSlots: Int { entries.count }
    public var activeCount: Int { entries.values.filter { $0.retirement == nil }.count }
    public var nextDeadline: ContinuousClock.Instant? {
        entries.values.filter { $0.retirement == nil }.map(\.context.deadline).min()
    }
    private var entries: [UInt64: Entry] = [:]
    private var nextID: UInt64?
    private var closed = false

    /// Reserve ID 0 for hello. A new connection must get a fresh epoch and
    /// never accept events dispatched with the previous connection's epoch.
    public init(epoch: UUID = UUID(), maximumRequests: Int = 64,
                maximumPendingPayloadBytes: Int = 1 << 20, startingRequestID: UInt64 = 1) throws {
        guard (1...4096).contains(maximumRequests),
              (1...CoreWire.maximumPayload).contains(maximumPendingPayloadBytes), startingRequestID > 0 else {
            throw CoreRPCFailure.invalidLimits
        }
        self.epoch = epoch
        self.maximumRequests = maximumRequests
        self.maximumPendingPayloadBytes = maximumPendingPayloadBytes
        nextID = startingRequestID
    }

    /// Admission happens before exposing a request to the writer. An admission
    /// error consumes neither an ID nor quota. Register before sending: a core
    /// can reply immediately. The default params object is empty, never null.
    public mutating func begin(method: String, parameters: Data = Data("{}".utf8),
                               deadline: ContinuousClock.Instant) throws -> Request {
        guard !closed else { throw CoreRPCFailure.closed }
        guard entries.count < maximumRequests else { throw CoreRPCFailure.capacityExceeded }
        guard let id = nextID else { throw CoreRPCFailure.requestIDsExhausted }
        guard CoreRPCRemoteFailure.isIdentifier(method) else { throw CoreRPCFailure.invalidMethod }
        guard parameters.count <= maximumPendingPayloadBytes else { throw CoreRPCFailure.requestTooLarge }
        do {
            guard try JSONSerialization.jsonObject(with: parameters) is [String: Any] else {
                throw CoreRPCFailure.invalidParameters
            }
        } catch { throw CoreRPCFailure.invalidParameters }
        var payload = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":".utf8)
        payload.append(try JSONEncoder().encode(method))
        payload.append(Data(",\"params\":".utf8))
        payload.append(parameters)
        payload.append(0x7d)
        guard payload.count <= maximumPendingPayloadBytes - pendingPayloadBytes else {
            throw CoreRPCFailure.requestTooLarge
        }
        let frame = try CoreFrame(channel: 0, kind: .data, payload: payload)
        let context = Context(token: Token(epoch: epoch, id: id), method: method,
                              deadline: deadline, payloadBytes: payload.count)
        entries[id] = Entry(context: context)
        pendingPayloadBytes += payload.count
        nextID = id == UInt64.max ? nil : id + 1
        return Request(context: context, frame: frame)
    }

    /// Local cancellation is not a remote rollback. Do not retry a mutating
    /// command just because the caller stopped waiting for it.
    @discardableResult
    public mutating func cancel(_ token: Token) -> Context? {
        guard !closed, token.epoch == epoch, var entry = entries[token.id], entry.retirement == nil else { return nil }
        entry.retirement = .cancelled
        entries[token.id] = entry
        return entry.context
    }

    /// Only the writer's owner may call this, after proving the frame has
    /// never left its local queue. Unlike cancellation, no remote reply can
    /// exist, so no tombstone is needed. The issued ID is still never reused.
    @discardableResult
    public mutating func discardUnsent(_ token: Token) -> Context? {
        guard !closed, token.epoch == epoch, let entry = entries.removeValue(forKey: token.id) else { return nil }
        pendingPayloadBytes -= entry.context.payloadBytes
        return entry.context
    }

    /// The owner calls this at its next deadline; returned calls should fail
    /// their waiters once, without removing the metadata needed by late replies.
    public mutating func expire(at now: ContinuousClock.Instant) -> [Context] {
        let expired = entries.values.filter { $0.retirement == nil && $0.context.deadline <= now }
            .map(\.context).sorted { $0.token.id < $1.token.id }
        for context in expired { entries[context.token.id]?.retirement = .timedOut }
        return expired
    }

    /// A timeout wins at the exact deadline even if the timer has not fired.
    /// A late outcome may therefore be the first notice of that timeout.
    /// Malformed/unknown responses throw without discarding active contexts:
    /// the connection owner must close and fail every remaining waiter.
    public mutating func receive(_ frame: CoreFrame, from receivedEpoch: UUID,
                                 at now: ContinuousClock.Instant) throws -> Delivery {
        guard !closed else { throw CoreRPCFailure.closed }
        guard receivedEpoch == epoch else { throw CoreRPCFailure.staleEpoch }
        let reply = try CoreRPCReply(frame: frame)
        guard let entry = entries.removeValue(forKey: reply.id) else { throw CoreRPCFailure.unexpectedReply }
        pendingPayloadBytes -= entry.context.payloadBytes
        if let retirement = entry.retirement { return .late(entry.context, reply, retirement) }
        if entry.context.deadline <= now { return .late(entry.context, reply, .timedOut) }
        return .reply(entry.context, reply)
    }

    /// Drain pending waiters once. Tombstones need no second completion. Never
    /// reset this ledger and reuse it: construct a new one for the new epoch.
    public mutating func close() -> [Context] {
        guard !closed else { return [] }
        closed = true
        let pending = entries.values.filter { $0.retirement == nil }.map(\.context).sorted { $0.token.id < $1.token.id }
        entries.removeAll()
        pendingPayloadBytes = 0
        return pending
    }
}
