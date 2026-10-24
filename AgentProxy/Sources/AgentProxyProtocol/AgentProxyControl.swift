import Foundation

/// What the app says to the forwarder over `ap.sock`, in herdr's shape:
/// newline-delimited JSON, one request object per line,
/// `{"id":"req_1","method":"routes.create","params":{…}}`, answered by one line
/// that echoes the `id` and has either `result` or `error`
/// (`{"code":"invalid_params","message":"…"}`). Several requests can be sent on
/// one connection; they are answered in order.
///
/// The route token is in the `baseURL` of the `routes.create` answer and
/// nowhere else: no other answer, file or log line has it.
public nonisolated enum AgentProxyControl {
    /// Raised when a message changes in a way an older app or proxy would
    /// misread. `proxy.status` reports the proxy's.
    public static let protocolVersion = 1
    /// A request line longer than this closes the connection.
    public static let maximumLineBytes = 64 * 1024
    /// A route's text fields (session, pane, terminal, CLI version).
    public static let maximumFieldBytes = 256

    public enum Method: String, Codable, Sendable, CaseIterable {
        case status = "proxy.status"
        case restartWhenIdle = "proxy.restartWhenIdle"
        case routesCreate = "routes.create"
        case routesRemove = "routes.remove"
        case routesList = "routes.list"
    }

    public enum ErrorCode: String, Codable, Sendable {
        case parseError = "parse_error"
        case unknownMethod = "unknown_method"
        case invalidParams = "invalid_params"
        case unavailable = "unavailable"
    }

    /// One request line, newline included.
    public static func requestLine<Params: Encodable>(id: String, method: Method, params: Params) throws -> Data {
        var data = try encoder.encode(RequestEnvelope(id: id, method: method.rawValue, params: params))
        data.append(0x0A)
        return data
    }

    public static func requestLine(id: String, method: Method) throws -> Data {
        try requestLine(id: id, method: method, params: EmptyParams())
    }

    /// One answer line, without its newline.
    public static func decodeResponse<Result: Decodable>(_ line: Data, as type: Result.Type) throws -> ResponseEnvelope<Result> {
        try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: line)
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

public nonisolated struct EmptyParams: Codable, Sendable, Equatable {
    public init() {}
}

public nonisolated struct RequestEnvelope<Params: Encodable>: Encodable {
    public let id: String
    public let method: String
    public let params: Params
}

public nonisolated struct ResponseEnvelope<Result: Decodable>: Decodable {
    public let id: String?
    public let result: Result?
    public let error: AgentProxyControlError?
}

public nonisolated struct AgentProxyControlError: Codable, Sendable, Error, Equatable {
    public let code: String
    public let message: String

    public init(code: AgentProxyControl.ErrorCode, message: String) {
        self.code = code.rawValue; self.message = message
    }
}

/// Which agent a route is for. It decides which upstreams the route may use:
/// Claude Code only api.anthropic.com, Codex only chatgpt.com, and Pi those
/// plus the exact api.openai.com Responses endpoint for ChatGPT direct sign-in.
/// Pi's API-key and custom-endpoint calls keep their original SDK transport.
public nonisolated enum AgentProxyRouteKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case pi
}

/// `routes.create`: made by the app once it knows the pane the agent will run
/// in, before the agent starts.
public nonisolated struct AgentProxyRouteCreate: Codable, Sendable, Equatable {
    public let kind: AgentProxyRouteKind
    /// herdr's session the pane belongs to.
    public let session: String
    public let paneID: String
    public let terminalID: String
    /// The agent CLI's version, as the launcher read it.
    public let cliVersion: String

    public init(kind: AgentProxyRouteKind, session: String, paneID: String, terminalID: String, cliVersion: String) {
        self.kind = kind; self.session = session; self.paneID = paneID
        self.terminalID = terminalID; self.cliVersion = cliVersion
    }
}

public nonisolated struct AgentProxyRouteCreated: Codable, Sendable, Equatable {
    /// Names the route in `routes.remove`, `routes.list` and the recorder's
    /// frames. Not a secret.
    public let routeID: String
    /// `http://127.0.0.1:PORT/p/<token>`. Claude Code and Pi's `anthropic`
    /// provider take it as it is; Codex gets `<baseURL>/backend-api/codex`
    /// and Pi's `openai-codex` provider `<baseURL>/backend-api`. Pi's current
    /// `openai` provider retains its model URL and redirects only an eligible
    /// final fetch through `<baseURL>/openai/v1/responses`.
    public let baseURL: String

    public init(routeID: String, baseURL: String) { self.routeID = routeID; self.baseURL = baseURL }
}

public nonisolated struct AgentProxyRouteRemove: Codable, Sendable, Equatable {
    public let routeID: String
    public init(routeID: String) { self.routeID = routeID }
}

public nonisolated struct AgentProxyRouteRemoved: Codable, Sendable, Equatable {
    public let removed: Bool

    public init(removed: Bool) { self.removed = removed }
}

public nonisolated struct AgentProxyRoute: Codable, Sendable, Equatable {
    public let routeID: String
    public let kind: AgentProxyRouteKind
    public let session: String
    public let paneID: String
    public let terminalID: String
    public let cliVersion: String
    /// ISO 8601, UTC.
    public let createdAt: String
    /// A request on this route was turned away because it wasn't signed in
    /// with a subscription (an API key, or no OAuth capability). The app stops
    /// giving the proxy to this kind of agent.
    public let oauthRejected: Bool
    /// Requests of this route being forwarded now.
    public let inFlight: Int

    public init(routeID: String, kind: AgentProxyRouteKind, session: String, paneID: String, terminalID: String,
                cliVersion: String, createdAt: String, oauthRejected: Bool, inFlight: Int) {
        self.routeID = routeID; self.kind = kind; self.session = session; self.paneID = paneID
        self.terminalID = terminalID; self.cliVersion = cliVersion; self.createdAt = createdAt
        self.oauthRejected = oauthRejected; self.inFlight = inFlight
    }
}

public nonisolated struct AgentProxyRouteList: Codable, Sendable, Equatable {
    public let routes: [AgentProxyRoute]

    public init(routes: [AgentProxyRoute]) { self.routes = routes }
}

public nonisolated struct AgentProxyStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Forwarding.
        case running
        /// `proxy.restartWhenIdle` was asked for: still forwarding, and it
        /// exits the first time no request is in flight.
        case draining
    }

    public struct Recorder: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable {
            case running
            /// It exited and is started again after a pause that grows while
            /// it keeps exiting.
            case restarting
            /// No recorder is configured, or the proxy is stopping.
            case stopped
        }
        public let state: State
        public let pid: Int32?
        public let restarts: Int

        public init(state: State, pid: Int32?, restarts: Int) { self.state = state; self.pid = pid; self.restarts = restarts }
    }

    /// Counts since the proxy started; nothing else about a request is kept.
    public struct Counters: Codable, Sendable, Equatable {
        public let exchanges: Int
        public let rejected: Int
        public let upstreamFailures: Int
        public let recorderDropped: Int

        public init(exchanges: Int, rejected: Int, upstreamFailures: Int, recorderDropped: Int) {
            self.exchanges = exchanges; self.rejected = rejected
            self.upstreamFailures = upstreamFailures; self.recorderDropped = recorderDropped
        }
    }

    public let protocolVersion: Int
    /// SHA-256 of the proxy's executable as it was when it started. The app
    /// compares it with the executable in its own bundle and asks for
    /// `proxy.restartWhenIdle` when they differ.
    public let build: String
    public let port: Int
    public let state: State
    public let routeCount: Int
    public let inFlight: Int
    public let recorder: Recorder
    public let counters: Counters

    public init(protocolVersion: Int, build: String, port: Int, state: State, routeCount: Int, inFlight: Int,
                recorder: Recorder, counters: Counters) {
        self.protocolVersion = protocolVersion; self.build = build; self.port = port; self.state = state
        self.routeCount = routeCount; self.inFlight = inFlight; self.recorder = recorder; self.counters = counters
    }
}

public nonisolated struct AgentProxyRestartWhenIdle: Codable, Sendable, Equatable {
    public let accepted: Bool
    /// Requests still in flight; the proxy exits when this reaches 0.
    public let inFlight: Int

    public init(accepted: Bool, inFlight: Int) { self.accepted = accepted; self.inFlight = inFlight }
}
