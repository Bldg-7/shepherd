import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Crypto
import X509
import SwiftASN1

// What the forwarder tests stand on: a certificate authority of their own,
// TLS upstreams on 127.0.0.1 that record what reaches them and answer as a
// test scripts them, and plain-socket clients for the listener and ap.sock.
// Nothing here resolves a name or leaves 127.0.0.1.

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String) throws {
    if try !condition() { throw TestFailure(description: message()) }
}

func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty else { return true }
    return Data(haystack).range(of: Data(needle)) != nil
}

func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

// MARK: - Certificates

struct TestIdentity {
    let leaf: NIOSSLCertificate
    let key: NIOSSLPrivateKey
}

final class TestCA {
    private let key = P256.Signing.PrivateKey()
    private let certificate: Certificate
    let root: NIOSSLCertificate

    init(name: String) throws {
        let now = Date()
        let subject = try DistinguishedName { CommonName(name) }
        certificate = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(key.publicKey),
                                      notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(86400),
                                      issuer: subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
                                      extensions: try Certificate.Extensions {
                                          Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                                          Critical(KeyUsage(keyCertSign: true))
                                      }, issuerPrivateKey: .init(key))
        root = try NIOSSLCertificate(bytes: Self.der(certificate), format: .der)
    }

    func issue(host: String) throws -> TestIdentity {
        let now = Date()
        let leafKey = P256.Signing.PrivateKey()
        let leaf = try Certificate(version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
                                   notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(86400),
                                   issuer: certificate.subject, subject: try DistinguishedName { CommonName(host) },
                                   signatureAlgorithm: .ecdsaWithSHA256,
                                   extensions: try Certificate.Extensions {
                                       Critical(BasicConstraints.notCertificateAuthority)
                                       Critical(KeyUsage(digitalSignature: true))
                                       try ExtendedKeyUsage([.serverAuth])
                                       SubjectAlternativeNames([.dnsName(host)])
                                   }, issuerPrivateKey: .init(key))
        return TestIdentity(leaf: try NIOSSLCertificate(bytes: Self.der(leaf), format: .der),
                            key: try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem))
    }

    private static func der(_ certificate: Certificate) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }
}

// MARK: - Fake upstream

struct FakeRequest {
    let requestLine: String
    let headers: [(String, String)]
    let body: [UInt8]
    let chunked: Bool

    func header(_ name: String) -> [String] { headers.filter { $0.0.lowercased() == name.lowercased() }.map(\.1) }
}

/// A connection to a fake upstream, for the test's script to answer on.
final class FakeConnection: @unchecked Sendable {
    let channel: Channel
    private let lock = NSLock()
    private var closedAtValue: Date?

    init(channel: Channel) {
        self.channel = channel
        channel.closeFuture.whenComplete { [self] _ in lock.withLock { closedAtValue = Date() } }
    }

    var closedAt: Date? { lock.withLock { closedAtValue } }

    func send(_ data: [UInt8]) {
        try? channel.writeAndFlush(ByteBuffer(bytes: data)).wait()
    }

    func send(_ text: String) { send(bytes(text)) }

    func sendChunk(_ text: String) { sendChunk(bytes(text)) }

    func sendChunk(_ data: [UInt8]) {
        send(bytes(String(data.count, radix: 16) + "\r\n") + data + bytes("\r\n"))
    }

    func close() { try? channel.close().wait() }
}

/// A TLS server on 127.0.0.1 that stands in for api.anthropic.com or
/// chatgpt.com. It counts connections and handshakes, keeps every request it
/// reads (in memory only) and hands each to the script.
final class FakeUpstream: @unchecked Sendable {
    typealias Script = @Sendable (FakeRequest, FakeConnection) -> Void

    private let lock = NSLock()
    private var acceptedValue = 0
    private var handshakesValue = 0
    private var receivedBytesValue = 0
    private var requestsValue: [FakeRequest] = []
    private var connectionsValue: [FakeConnection] = []
    private let script: Script
    private var channel: Channel!
    private(set) var port = 0

    var accepted: Int { lock.withLock { acceptedValue } }
    var handshakes: Int { lock.withLock { handshakesValue } }
    var receivedBytes: Int { lock.withLock { receivedBytesValue } }
    var requests: [FakeRequest] { lock.withLock { requestsValue } }
    var connections: [FakeConnection] { lock.withLock { connectionsValue } }

    /// `identity` nil: plain TCP that never answers (for the handshake
    /// deadline).
    init(group: EventLoopGroup, identity: TestIdentity?, script: @escaping Script) throws {
        self.script = script
        let context = try identity.map {
            try NIOSSLContext(configuration: TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate($0.leaf)],
                                                                                      privateKey: .privateKey($0.key)))
        }
        let bound = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                lock.withLock { acceptedValue += 1 }
                return channel.eventLoop.makeCompletedFuture {
                    guard let context else { return }
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(FakeUpstreamHandler(upstream: self))
                }
            }
            .bind(to: try SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        channel = bound
        port = bound.localAddress!.port!
    }

    var address: SocketAddress { try! SocketAddress(ipAddress: "127.0.0.1", port: port) }

    fileprivate func handshook() { lock.withLock { handshakesValue += 1 } }

    fileprivate func received(_ count: Int) { lock.withLock { receivedBytesValue += count } }

    fileprivate func connected(_ channel: Channel) -> FakeConnection {
        let connection = FakeConnection(channel: channel)
        lock.withLock { connectionsValue.append(connection) }
        return connection
    }

    fileprivate func handle(_ request: FakeRequest, on connection: FakeConnection, queue: DispatchQueue) {
        lock.withLock { requestsValue.append(request) }
        let script = script
        queue.async { script(request, connection) }
    }

    func stop() { try? channel.close().wait() }
}

private final class FakeUpstreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let upstream: FakeUpstream
    private var buffer: [UInt8] = []
    private var connection: FakeConnection?
    private let queue = DispatchQueue(label: "fake-upstream-connection")

    init(upstream: FakeUpstream) { self.upstream = upstream }

    func handlerAdded(context: ChannelHandlerContext) {
        connection = upstream.connected(context.channel)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { upstream.handshook() }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let incoming = unwrapInboundIn(data)
        upstream.received(incoming.readableBytes)
        buffer.append(contentsOf: incoming.readableBytesView)
        while let request = Self.parse(&buffer) {
            upstream.handle(request, on: connection!, queue: queue)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    static func parse(_ buffer: inout [UInt8]) -> FakeRequest? {
        guard let headEnd = range(of: bytes("\r\n\r\n"), in: buffer, from: 0) else { return nil }
        let head = String(decoding: buffer[0..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let headers: [(String, String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let bodyStart = headEnd + 4
        let chunked = headers.contains { $0.0.lowercased() == "transfer-encoding" && $0.1.lowercased() == "chunked" }
        if chunked {
            var body: [UInt8] = []
            var position = bodyStart
            while true {
                guard let lineEnd = range(of: bytes("\r\n"), in: buffer, from: position) else { return nil }
                let sizeText = String(decoding: buffer[position..<lineEnd], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                position = lineEnd + 2
                if size == 0 {
                    guard buffer.count >= position + 2 else { return nil }
                    position += 2
                    break
                }
                guard buffer.count >= position + size + 2 else { return nil }
                body += buffer[position..<(position + size)]
                position += size + 2
            }
            buffer.removeFirst(position)
            return FakeRequest(requestLine: requestLine, headers: headers, body: body, chunked: true)
        }
        let length = headers.first { $0.0.lowercased() == "content-length" }.flatMap { Int($0.1) } ?? 0
        guard buffer.count >= bodyStart + length else { return nil }
        let body = Array(buffer[bodyStart..<(bodyStart + length)])
        buffer.removeFirst(bodyStart + length)
        return FakeRequest(requestLine: requestLine, headers: headers, body: body, chunked: false)
    }

    static func range(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        let data = Data(haystack)
        return data.range(of: Data(needle), in: start..<data.count)?.lowerBound
    }
}

// MARK: - Clients

struct RawResponse {
    let status: Int
    let headers: [(String, String)]
    let body: [UInt8]
    /// A chunked body that ended with its last chunk.
    let complete: Bool

    func header(_ name: String) -> [String] { headers.filter { $0.0.lowercased() == name.lowercased() }.map(\.1) }
}

/// A plain TCP client, so the test sends exactly the bytes it means and sees
/// exactly the bytes that come back, framing included.
final class RawClient {
    let descriptor: Int32
    private(set) var pending: [UInt8] = []
    private(set) var eof = false

    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(descriptor); throw TestFailure(description: "connect to the listener failed") }
    }

    deinit { close(descriptor) }

    func send(_ data: [UInt8]) throws {
        var sent = 0
        while sent < data.count {
            let count = data[sent...].withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { throw TestFailure(description: "send failed") }
            sent += count
        }
    }

    func send(_ text: String) throws { try send(bytes(text)) }

    func shutdown() { Darwin.shutdown(descriptor, SHUT_RDWR); close(descriptor) }

    /// Reads once, waiting up to `timeout`. False on timeout.
    @discardableResult
    func fill(timeout: Double) -> Bool {
        guard !eof else { return false }
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
        if count <= 0 { eof = true; return true }
        pending += chunk[0..<count]
        return true
    }

    /// Waits until the bytes received so far contain `needle`.
    func waitFor(_ needle: String, timeout: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !contains(pending, bytes(needle)) {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, !eof else { return false }
            fill(timeout: left)
        }
        return true
    }

    func waitForEOF(timeout: Double = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !eof {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            fill(timeout: left)
        }
        return true
    }

    private func take(_ count: Int) -> [UInt8] {
        let taken = Array(pending.prefix(count))
        pending.removeFirst(min(count, pending.count))
        return taken
    }

    private func needBytes(_ count: Int, deadline: Date) -> Bool {
        while pending.count < count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, !eof, fill(timeout: left) else { return pending.count >= count }
        }
        return true
    }

    private func line(deadline: Date) -> String? {
        while true {
            if let index = FakeUpstreamHandler_range(bytes("\r\n"), pending) {
                let text = String(decoding: take(index), as: UTF8.self)
                _ = take(2)
                return text
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0, !eof, fill(timeout: left) else { return nil }
        }
    }

    /// One response, read to its end (or to the connection's end).
    func response(timeout: Double = 10, head: Bool = false) throws -> RawResponse {
        let deadline = Date().addingTimeInterval(timeout)
        guard let statusLine = line(deadline: deadline) else { throw TestFailure(description: "no response") }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "HTTP/1.1", let status = Int(parts[1]) else { throw TestFailure(description: "bad status line") }
        var headers: [(String, String)] = []
        while let next = line(deadline: deadline), !next.isEmpty {
            guard let colon = next.firstIndex(of: ":") else { continue }
            headers.append((String(next[..<colon]), next[next.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let value = { (name: String) in headers.first { $0.0.lowercased() == name }?.1 }
        if head || status == 204 || status == 304 { return RawResponse(status: status, headers: headers, body: [], complete: true) }
        if value("transfer-encoding")?.lowercased() == "chunked" {
            var body: [UInt8] = []
            while true {
                guard let sizeLine = line(deadline: deadline), let size = Int(sizeLine, radix: 16) else {
                    return RawResponse(status: status, headers: headers, body: body, complete: false)
                }
                if size == 0 {
                    _ = line(deadline: deadline)
                    return RawResponse(status: status, headers: headers, body: body, complete: true)
                }
                guard needBytes(size + 2, deadline: deadline) else {
                    body += take(pending.count)
                    return RawResponse(status: status, headers: headers, body: body, complete: false)
                }
                body += take(size)
                _ = take(2)
            }
        }
        if let length = value("content-length").flatMap({ Int($0) }) {
            let enough = needBytes(length, deadline: deadline)
            return RawResponse(status: status, headers: headers, body: take(min(length, pending.count)), complete: enough)
        }
        _ = waitForEOF(timeout: deadline.timeIntervalSinceNow)
        return RawResponse(status: status, headers: headers, body: take(pending.count), complete: true)
    }
}

private func FakeUpstreamHandler_range(_ needle: [UInt8], _ haystack: [UInt8]) -> Int? {
    FakeUpstreamHandler.range(of: needle, in: haystack, from: 0)
}

/// ap.sock, one line at a time. Every answer is kept, so the test can look
/// through them all afterwards.
final class ControlClient {
    private let descriptor: Int32
    private var pending: [UInt8] = []
    private(set) var answers: [[UInt8]] = []
    private var next = 0

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
            raw[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(descriptor); throw TestFailure(description: "connect to ap.sock failed") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(descriptor) }

    func sendRaw(_ text: String) {
        let data = bytes(text)
        _ = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    }

    func readLine() throws -> [String: Any] {
        while true {
            if let index = pending.firstIndex(of: 0x0A) {
                let line = Array(pending[0..<index])
                pending.removeFirst(index + 1)
                answers.append(line)
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw TestFailure(description: "answer is not an object")
                }
                return object
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { throw TestFailure(description: "ap.sock closed or timed out") }
            pending += chunk[0..<count]
        }
    }

    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        next += 1
        let id = "t\(next)"
        let line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        sendRaw(String(decoding: line, as: UTF8.self) + "\n")
        let answer = try readLine()
        try check(answer["id"] as? String == id, "answer id")
        return answer
    }

    func result(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let answer = try call(method, params)
        guard let result = answer["result"] as? [String: Any] else {
            throw TestFailure(description: "\(method) answered with an error: \((answer["error"] as? [String: Any])?["code"] ?? "?")")
        }
        return result
    }
}

// MARK: - Files

func listFiles(_ root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    return enumerator.compactMap { $0 as? String }.map { root + "/" + $0 }.filter {
        var info = stat()
        return lstat($0, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}

func mode(_ path: String) -> mode_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0o7777
}

func fileBytesCount(_ path: String) -> Int {
    var info = stat()
    return stat(path, &info) == 0 ? Int(info.st_size) : 0
}

func fileBytes(_ path: String) -> [UInt8] { (FileManager.default.contents(atPath: path).map { Array($0) }) ?? [] }
