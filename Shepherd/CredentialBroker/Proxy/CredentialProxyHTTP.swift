#if os(macOS)
import Foundation
import NIOHTTP1

// Only finite HTTP/1 form requests are admitted. HTTP/2, streams and client-side
// password transformations are intentionally not part of this transport.
nonisolated enum CredentialProxyHTTP {
    static let provenanceHeader = "x-shepherd-credential-ticket"
    static let maximumBody = 65536

    static func authority(_ value: String) throws -> (host: String, port: Int) {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, let port = Int(pieces[1]), String(port) == pieces[1],
              (1...65535).contains(port) else { throw CredentialBrokerError.invalidRequest }
        let d = try CredentialDestination(url: "https://\(value)/", field: "password")
        return (d.host, d.effectivePort)
    }

    static func connect(_ head: HTTPRequestHead, expectedAuthorization: String) throws -> (host: String, port: Int) {
        guard head.version == .http1_1, head.method == .CONNECT,
              head.headers["proxy-authorization"] == [expectedAuthorization],
              head.headers["host"] == [head.uri],
              head.headers["content-length"].isEmpty,
              head.headers["transfer-encoding"].isEmpty else { throw CredentialBrokerError.denied }
        try validateHeaders(head.headers)
        return try authority(head.uri)
    }

    static func observed(_ head: HTTPRequestHead, body: Data, authority: String, field: String) throws -> (CredentialObservedRequest, CredentialRequestTicket) {
        try validateHeaders(head.headers)
        guard head.version == .http1_1, head.method == .POST,
              head.uri.hasPrefix("/"), !head.uri.hasPrefix("//"),
              hostMatches(head.headers, authority: authority),
              head.headers["content-type"] == ["application/x-www-form-urlencoded"],
              head.headers["content-encoding"].isEmpty,
              head.headers["transfer-encoding"].isEmpty,
              head.headers["expect"].isEmpty,
              head.headers["proxy-authorization"].isEmpty,
              head.headers["content-length"] == [String(body.count)],
              body.count <= maximumBody else { throw CredentialBrokerError.unsupported }
        let tickets = head.headers[provenanceHeader]
        guard tickets.count == 1, tickets[0].utf8.count == 64,
              tickets[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CredentialBrokerError.denied }
        let destination = try CredentialDestination(url: "https://" + authority + head.uri, field: field)
        _ = try CredentialForm.fields(body)
        return (CredentialObservedRequest(destination: destination, body: body), CredentialRequestTicket(opaqueID: tickets[0]))
    }

    static func validateHeaders(_ headers: HTTPHeaders) throws {
        guard headers.count <= 64 else { throw CredentialBrokerError.capacity }
        var size = 0
        var names = Set<String>()
        for (name, value) in headers {
            size += name.utf8.count + value.utf8.count
            guard names.insert(name.lowercased()).inserted,
                  name.utf8.allSatisfy({ (33...126).contains($0) }),
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { throw CredentialBrokerError.invalidRequest }
        }
        guard size <= 16384 else { throw CredentialBrokerError.capacity }
        // Reject, rather than reinterpret, hop-by-hop nominations and upgrades.
        guard (headers["connection"].isEmpty || headers["connection"] == ["keep-alive"] || headers["connection"] == ["close"]),
              (headers["proxy-connection"].isEmpty || headers["proxy-connection"] == ["keep-alive"]),
              headers["keep-alive"].isEmpty, headers["te"].isEmpty,
              headers["trailer"].isEmpty, headers["upgrade"].isEmpty else { throw CredentialBrokerError.invalidRequest }
    }

    static func hostMatches(_ headers: HTTPHeaders, authority: String) -> Bool {
        guard headers["host"].count == 1 else { return false }
        let host = headers["host"][0]
        return host == authority || (!host.contains(":") && host + ":443" == authority)
    }

    static func browsing(_ head: HTTPRequestHead, body: Data, authority: String) throws {
        try validateHeaders(head.headers)
        guard head.version == .http1_1, head.method == .GET || head.method == .HEAD,
              head.uri.hasPrefix("/"), !head.uri.hasPrefix("//"),
              hostMatches(head.headers, authority: authority), body.isEmpty,
              head.headers["content-length"].isEmpty || head.headers["content-length"] == ["0"],
              head.headers["transfer-encoding"].isEmpty, head.headers["content-encoding"].isEmpty,
              head.headers["proxy-authorization"].isEmpty, head.headers[provenanceHeader].isEmpty else { throw CredentialBrokerError.unsupported }
        _ = try CredentialDestination(url: "https://" + authority + head.uri, field: "password")
    }

    static func substituting(_ secret: Data, request: CredentialObservedRequest) throws -> Data {
        guard secret.count <= maximumBody, let value = String(data: secret, encoding: .utf8),
              !value.contains("\0") else { throw CredentialBrokerError.unsupported }
        let fields = try CredentialForm.fields(request.body)
        guard fields.filter({ $0.0 == request.destination.field }).count == 1 else { throw CredentialBrokerError.invalidRequest }
        func encode(_ text: String) -> String {
            text.utf8.map { byte in
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [42,45,46,95].contains(byte) {
                    return String(UnicodeScalar(byte))
                }
                return byte == 32 ? "+" : String(format: "%%%02X", byte)
            }.joined()
        }
        let body = Data(fields.map { encode($0.0) + "=" + encode($0.0 == request.destination.field ? value : $0.1) }.joined(separator: "&").utf8)
        guard body.count <= maximumBody else { throw CredentialBrokerError.capacity }
        return body
    }

    static func upstreamHead(_ head: HTTPRequestHead, bodyCount: Int) -> HTTPRequestHead {
        var head = head
        head.headers.remove(name: provenanceHeader)
        head.headers.remove(name: "proxy-authorization")
        head.headers.remove(name: "proxy-connection")
        head.headers.remove(name: "keep-alive")
        head.headers.replaceOrAdd(name: "content-length", value: String(bodyCount))
        head.headers.replaceOrAdd(name: "connection", value: "close")
        return head
    }
}
#endif
