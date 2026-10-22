import Foundation
import NIOHTTP1
import AgentProxyProtocol

/// The two places a request may go. Nothing else is ever connected to.
public enum AgentProxyUpstream: String, Sendable, CaseIterable {
    case anthropic
    case chatgpt

    /// The Host header, the TLS server name and the name the certificate has
    /// to be valid for.
    public var host: String {
        switch self {
        case .anthropic: "api.anthropic.com"
        case .chatgpt: "chatgpt.com"
        }
    }
}

/// A request the forwarder takes, after every check.
struct ForwardDecision {
    let upstream: AgentProxyUpstream
    /// The path and query after `/p/<token>`, as they came.
    let target: String
    /// The path alone, for the recorder.
    let path: String
    let token: String
    let route: RouteTable.Entry?
}

/// A request the forwarder answers itself, without connecting anywhere.
struct Rejection: Error {
    enum Reason: String {
        case version, host, origin, method, upgrade, path, kind, framing, oauth
    }
    let status: HTTPResponseStatus
    let reason: Reason
    /// The provider whose error format the body is in, when the path told.
    let provider: AgentProxyUpstream?
    let message: String
    /// The route a request turned away for its sign-in came on.
    var routeID: String? = nil
}

/// What is checked before a request is forwarded, and how its headers are
/// changed on the way. Pure: no I/O, no state.
enum ForwardingRules {
    static let tokenLength = 32

    static func admit(_ head: HTTPRequestHead, port: Int, lookup: (String) -> RouteTable.Entry?) -> Result<ForwardDecision, Rejection> {
        guard head.version == .http1_1 else {
            return .failure(Rejection(status: .httpVersionNotSupported, reason: .version, provider: nil, message: "HTTP/1.1 only."))
        }
        // The exact Host the agents are given. Anything else is not one of
        // them: a page that rebinds a name to 127.0.0.1 sends its own name.
        let hosts = head.headers["host"]
        guard hosts.count == 1, hosts[0] == "127.0.0.1:\(port)" else {
            return .failure(Rejection(status: .forbidden, reason: .host, provider: nil, message: "Unexpected Host."))
        }
        // Agents don't send these; browsers do.
        if head.headers.contains(name: "origin") || head.headers.contains(where: { $0.name.lowercased().hasPrefix("sec-fetch-") }) {
            return .failure(Rejection(status: .forbidden, reason: .origin, provider: nil, message: "Requests from web pages are not forwarded."))
        }
        guard head.method == .GET || head.method == .POST || head.method == .HEAD else {
            return .failure(Rejection(status: .methodNotAllowed, reason: .method, provider: nil, message: "GET, POST and HEAD only."))
        }
        // Codex tries a WebSocket first and falls back to HTTP on 426.
        if head.headers.contains(name: "upgrade") {
            return .failure(Rejection(status: .upgradeRequired, reason: .upgrade, provider: nil, message: "Upgrades are not forwarded; use HTTP."))
        }
        guard let split = splitTarget(head.uri), let destination = upstream(for: split.target) else {
            return .failure(Rejection(status: .notFound, reason: .path, provider: nil, message: "Not found."))
        }
        let (token, target, path, upstream) = (split.token, split.target, destination.path, destination.upstream)
        let route = lookup(token)
        if let route, !allows(route.kind, upstream) {
            return .failure(Rejection(status: .notFound, reason: .kind, provider: upstream, message: "Not found."))
        }
        if let framing = framingProblem(head.headers) {
            return .failure(Rejection(status: .badRequest, reason: .framing, provider: upstream, message: framing))
        }
        if head.method == .POST, isInference(path, upstream), !hasSubscriptionShape(head.headers, upstream) {
            return .failure(Rejection(status: .forbidden, reason: .oauth, provider: upstream, message: oauthMessage, routeID: route?.routeID))
        }
        return .success(ForwardDecision(upstream: upstream, target: target, path: path, token: token, route: route))
    }

    static let oauthMessage = "hrdrhrdrhrdr's agent proxy forwards only requests signed in with a Claude or ChatGPT subscription, and this one used an API key or another sign-in. Open a new tab and start the agent again: it will run without the proxy."

    /// `/p/<token>/<rest>` into the token and `/<rest>`.
    static func splitTarget(_ uri: String) -> (token: String, target: String)? {
        guard uri.hasPrefix("/p/") else { return nil }
        let afterPrefix = uri.dropFirst(3)
        guard let slash = afterPrefix.firstIndex(of: "/") else { return nil }
        let token = String(afterPrefix[..<slash])
        guard isWellFormedToken(token) else { return nil }
        return (token, String(afterPrefix[slash...]))
    }

    static func isWellFormedToken(_ token: String) -> Bool {
        token.utf8.count == tokenLength && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The fixed list. The path has to be plain: no percent-encoding, no dot
    /// segments, no empty segments, visible ASCII only.
    static func upstream(for target: String) -> (path: String, upstream: AgentProxyUpstream)? {
        guard target.utf8.allSatisfy({ (0x21...0x7E).contains($0) }), !target.contains("#") else { return nil }
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        guard path.hasPrefix("/"), !path.contains("%"), !path.contains("\\"), !path.contains("//") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        if path.hasPrefix("/v1/"), path.count > 4 { return (path, .anthropic) }
        if path == "/api/hello" { return (path, .anthropic) }
        if path.hasPrefix("/backend-api/codex/"), path.count > "/backend-api/codex/".count { return (path, .chatgpt) }
        return nil
    }

    static func allows(_ kind: AgentProxyRouteKind, _ upstream: AgentProxyUpstream) -> Bool {
        switch kind {
        case .claude: upstream == .anthropic
        case .codex: upstream == .chatgpt
        case .pi: true
        }
    }

    /// The model requests: the only ones whose sign-in is checked.
    static func isInference(_ path: String, _ upstream: AgentProxyUpstream) -> Bool {
        switch upstream {
        case .anthropic: path == "/v1/messages" || path.hasPrefix("/v1/messages/")
        case .chatgpt: path == "/backend-api/codex/responses" || path.hasPrefix("/backend-api/codex/responses/")
        }
    }

    /// Anthropic: a Bearer token, an `oauth-` capability in `anthropic-beta`
    /// and no `x-api-key`. ChatGPT: a Bearer token shaped as a JWT. The values
    /// are looked at here and nowhere else.
    static func hasSubscriptionShape(_ headers: HTTPHeaders, _ upstream: AgentProxyUpstream) -> Bool {
        let authorization = headers["authorization"]
        guard authorization.count == 1, let bearer = bearerToken(authorization[0]) else { return false }
        switch upstream {
        case .anthropic:
            guard !headers.contains(name: "x-api-key") else { return false }
            let betas = headers["anthropic-beta"].flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
            return betas.contains { $0.hasPrefix("oauth-") }
        case .chatgpt:
            return isJWTShaped(bearer)
        }
    }

    static func bearerToken(_ value: String) -> Substring? {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].drop(while: { $0 == " " })
        return token.isEmpty || token.contains(" ") ? nil : token
    }

    static func isJWTShaped(_ token: Substring) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0].hasPrefix("eyJ"), !segments[1].isEmpty else { return false }
        return segments.allSatisfy { $0.utf8.allSatisfy { isBase64URL($0) } }
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }

    /// A body is framed by Content-Length or by `Transfer-Encoding: chunked`
    /// alone; anything else is not taken.
    static func framingProblem(_ headers: HTTPHeaders) -> String? {
        let encodings = headers["transfer-encoding"]
        if encodings.isEmpty { return nil }
        guard encodings.count == 1, encodings[0].lowercased() == "chunked" else { return "Unsupported Transfer-Encoding." }
        return headers.contains(name: "content-length") ? "Content-Length with Transfer-Encoding." : nil
    }

    static let hopByHop: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "te", "trailer", "upgrade",
        "proxy-authorization", "proxy-authenticate", "expect"
    ]

    /// The request headers sent upstream: in the order and the case they came,
    /// with Host set to the upstream's in its place, the hop-by-hop headers
    /// (and those Connection names) and `x-3rdr-*` left out, and nothing added.
    /// `Transfer-Encoding: chunked` stays (its value written in lowercase, as
    /// NIO's encoder matches it), since the body is sent framed as it came.
    static func upstreamHeaders(_ headers: HTTPHeaders, upstream: AgentProxyUpstream) -> HTTPHeaders {
        let named = connectionNamed(headers)
        var result = HTTPHeaders()
        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "host" { result.add(name: name, value: upstream.host); continue }
            if lower == "transfer-encoding" { result.add(name: name, value: "chunked"); continue }
            if hopByHop.contains(lower) || named.contains(lower) || lower.hasPrefix("x-3rdr-") { continue }
            result.add(name: name, value: value)
        }
        return result
    }

    /// The response headers passed back: as they came, less the hop-by-hop
    /// ones. The framing header stays and the body is framed the same way.
    static func downstreamHeaders(_ headers: HTTPHeaders) -> HTTPHeaders {
        let named = connectionNamed(headers)
        var result = HTTPHeaders()
        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "transfer-encoding" { result.add(name: name, value: "chunked"); continue }
            if hopByHop.contains(lower) || named.contains(lower) { continue }
            result.add(name: name, value: value)
        }
        return result
    }

    static func connectionNamed(_ headers: HTTPHeaders) -> Set<String> {
        Set(headers["connection"].flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && $0 != "host" && $0 != "transfer-encoding" })
    }

    static func wantsClose(_ headers: HTTPHeaders) -> Bool {
        headers["connection"].flatMap { $0.split(separator: ",") }.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "close" }
    }

    /// The recorder's copy of the classifying request headers.
    static func teeRequestHeaders(_ headers: HTTPHeaders) -> [[String]] {
        headers.compactMap { name, value in
            let lower = name.lowercased()
            return AgentProxyTeeFrame.allowedRequestHeader(lower) ? [lower, value] : nil
        }
    }

    static func teeResponseHeaders(_ headers: HTTPHeaders) -> [[String]] {
        headers.compactMap { name, value in
            let lower = name.lowercased()
            return AgentProxyTeeFrame.allowedResponseHeader(lower) ? [lower, value] : nil
        }
    }

    /// An error the agent shows, in the format of the provider it expected.
    static func errorBody(status: HTTPResponseStatus, provider: AgentProxyUpstream?, message: String) -> (contentType: String, body: [UInt8]) {
        func json(_ object: [String: Any]) -> [UInt8] {
            Array((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data())
        }
        switch provider {
        case .anthropic:
            let type = switch status.code {
            case 403: "permission_error"
            case 404: "not_found_error"
            case 400: "invalid_request_error"
            default: "api_error"
            }
            return ("application/json", json(["type": "error", "error": ["type": type, "message": message]]))
        case .chatgpt:
            let type = status.code == 403 ? "permission_error" : status.code >= 500 ? "server_error" : "invalid_request_error"
            return ("application/json", json(["error": ["message": message, "type": type, "param": NSNull(), "code": NSNull()]]))
        case nil:
            return ("text/plain; charset=utf-8", Array((message + "\n").utf8))
        }
    }
}
