import Foundation

/// The frames the forwarder sends its recorder over their socketpair: a copy
/// of each exchange of a known route, as it passes.
///
/// A frame is a 4-byte big-endian length (of everything after it), a 1-byte
/// kind, the 8-byte big-endian exchange number, and the payload:
///
/// - `open`: JSON `Open` — the route, the upstream, the method, the path
///   without the token or the query, and only the request headers that tell
///   kinds of request apart (`allowedRequestHeader`). Never a credential.
/// - `requestBody`, `responseBody`: the body's bytes as they passed, still
///   compressed if they were.
/// - `requestEnd`: nothing.
/// - `responseHead`: JSON `ResponseHead` — the status and the response's
///   `content-type` and `content-encoding`.
/// - `end`: JSON `End`.
///
/// The forwarder never waits for the recorder. When the socket is full, or an
/// exchange's copy passes `exchangeLimitBytes`, that exchange alone is
/// dropped: nothing more of it is sent but its `end`, with outcome `dropped`.
/// If the recorder exits, the exchanges it had are gone, and the next
/// recorder gets the exchanges that start after it.
public nonisolated enum AgentProxyTeeFrame {
    public enum Kind: UInt8, Sendable {
        case open = 1
        case requestBody = 2
        case requestEnd = 3
        case responseHead = 4
        case responseBody = 5
        case end = 6
    }

    /// Length, kind and exchange.
    public static let headerBytes = 13
    /// A body is sent in frames of at most this much.
    public static let maximumPayloadBytes = 1 << 20
    /// The most of one exchange (request and response bodies together) that
    /// is copied.
    public static let exchangeLimitBytes = 64 << 20

    public struct Open: Codable, Sendable, Equatable {
        public let routeID: String
        /// `anthropic` or `chatgpt`.
        public let upstream: String
        public let method: String
        public let path: String
        /// `[name, value]` pairs, names lowercased, in the order they came.
        public let headers: [[String]]
        /// Only the app-supplied non-secret route identity. No token, token
        /// hash, base URL or credential is included. Optional when decoding
        /// older frames; a recorder must not invent identity if it is absent.
        public let routeIdentity: AgentProxyRouteCreate?

        public init(routeID: String, upstream: String, method: String, path: String, headers: [[String]],
                    routeIdentity: AgentProxyRouteCreate? = nil) {
            self.routeID = routeID; self.upstream = upstream; self.method = method
            self.path = path; self.headers = headers; self.routeIdentity = routeIdentity
        }
    }

    public struct ResponseHead: Codable, Sendable, Equatable {
        public let status: Int
        public let headers: [[String]]

        public init(status: Int, headers: [[String]]) { self.status = status; self.headers = headers }
    }

    public struct End: Codable, Sendable, Equatable {
        public enum Outcome: String, Codable, Sendable {
            /// The response came to its end and was passed on.
            case complete
            /// The copy was cut off; the exchange itself went on.
            case dropped
            /// The agent or the upstream closed the connection first.
            case aborted
        }
        public let outcome: Outcome

        public init(outcome: Outcome) { self.outcome = outcome }
    }

    /// Request headers whose values the recorder may have: what it needs to
    /// tell a main request from a subagent's, a compaction or a side request,
    /// and to read the body. Matched on the lowercased name.
    public static func allowedRequestHeader(_ name: String) -> Bool {
        if credentialHeaders.contains(name) { return false }
        return requestMetadataHeaders.contains(name)
    }

    // Prefixes are not safe allowlists: newer Claude builds also have
    // x-claude-code-signature and tunnel credential metadata. New fields must
    // be reviewed individually. Codex 0.162.1 uses hyphenated thread-id for
    // identity; session-id may instead be a cache-affinity override. Keep the
    // historical session_id spelling for compatible clients, not as proof of
    // native identity. Raw x-codex-turn-metadata is deliberately not copied.
    private static let requestMetadataHeaders: Set<String> = [
        "content-type", "content-encoding",
        "x-claude-code-session-id", "x-claude-code-request-class",
        "x-claude-code-agent-id", "x-claude-code-parent-agent-id",
        "x-claude-code-agent-type", "x-claude-code-prompt-id",
        "session_id", "session-id", "thread-id",
        "x-openai-subagent", "x-openai-memgen-request", "x-codex-parent-thread-id",
        "x-3rdr-pi-session", "x-3rdr-pi-class", "x-3rdr-pi-contract"
    ]

    public static func allowedResponseHeader(_ name: String) -> Bool {
        name == "content-type" || name == "content-encoding"
    }

    /// Never copied, whatever the lists above say.
    public static let credentialHeaders: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "cookie", "set-cookie", "chatgpt-account-id"
    ]

    public static func header(kind: Kind, exchange: UInt64, payloadCount: Int) -> [UInt8] {
        let length = UInt32(1 + 8 + payloadCount)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerBytes)
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: length >> UInt32(shift))) }
        bytes.append(kind.rawValue)
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: exchange >> UInt64(shift))) }
        return bytes
    }

    public struct Frame: Sendable, Equatable {
        public let kind: Kind
        public let exchange: UInt64
        public let payload: [UInt8]
    }

    public enum DecodeError: Error, Equatable {
        case oversized
        case unknownKind(UInt8)
    }

    /// Splits a byte stream into frames.
    public struct Decoder: Sendable {
        private var buffer: [UInt8] = []
        private var start = 0

        public init() {}

        public mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
            if start > 0 && start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
            buffer.append(contentsOf: bytes)
        }

        public mutating func next() throws -> Frame? {
            guard buffer.count - start >= 4 else { compact(); return nil }
            var length = 0
            for index in 0..<4 { length = length << 8 | Int(buffer[start + index]) }
            guard length >= 9, length <= 9 + maximumPayloadBytes else { throw DecodeError.oversized }
            guard buffer.count - start >= 4 + length else { compact(); return nil }
            guard let kind = Kind(rawValue: buffer[start + 4]) else { throw DecodeError.unknownKind(buffer[start + 4]) }
            var exchange: UInt64 = 0
            for index in 5..<13 { exchange = exchange << 8 | UInt64(buffer[start + index]) }
            let payload = Array(buffer[(start + 13)..<(start + 4 + length)])
            start += 4 + length
            return Frame(kind: kind, exchange: exchange, payload: payload)
        }

        private mutating func compact() {
            if start > 0 { buffer.removeFirst(start); start = 0 }
        }
    }
}
