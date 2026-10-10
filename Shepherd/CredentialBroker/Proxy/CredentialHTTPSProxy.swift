#if os(macOS)
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS

// One authenticated context route per listener. No unauthenticated CONNECT,
// retries, redirects, shared proxy credentials or logging of HTTP payloads.
nonisolated final class CredentialHTTPSProxy: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var stopped = false
    private var listener: Channel?
    let route: CredentialProxyRoute
    let consumer: any CredentialProxyConsuming
    let tls: CredentialProxyTLS
    let identities: [String: (context: NIOSSLContext, leafDER: Data)]
    private let upstreamTLS: NIOSSLContext

    init(route: CredentialProxyRoute, consumer: any CredentialProxyConsuming, upstreamTrustRoots: NIOSSLTrustRoots = .default) throws {
        self.route = route; self.consumer = consumer
        tls = try CredentialProxyTLS()
        var identities: [String: (context: NIOSSLContext, leafDER: Data)] = [:]
        for d in route.destinations where identities[d.host] == nil { identities[d.host] = try tls.identity(host: d.host) }
        self.identities = identities
        // On macOS NIOSSL .default uses SecTrust + SSL hostname policy.
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = .fullVerification
        config.trustRoots = upstreamTrustRoots
        upstreamTLS = try NIOSSLContext(configuration: config)
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func start() async throws -> Int {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 16384, high: 65536))
            .childChannelInitializer { channel in
                guard self.track(channel) else { return channel.close() }
                do {
                    try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder(), name: "http-response-encoder")
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)), name: "http-request-decoder")
                    try channel.pipeline.syncOperations.addHandler(ProxyIngress(proxy: self))
                    return channel.setOption(ChannelOptions.autoRead, value: true)
                } catch { return channel.eventLoop.makeFailedFuture(CredentialBrokerError.unavailable) }
            }.bind(host: "127.0.0.1", port: 0).get()
        lock.withLock { listener = channel }
        guard let port = channel.localAddress?.port else { throw CredentialBrokerError.unavailable }
        return port
    }

    func stop() async throws {
        route.revoke() // Fail closed before disconnecting sockets or provider teardown.
        let owned = lock.withLock { () -> [Channel] in
            stopped = true
            return Array(channels.values) + (listener.map { [$0] } ?? [])
        }
        for channel in owned { try? await channel.close().get() }
        try await group.shutdownGracefully()
    }

    private func track(_ channel: Channel) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard !stopped, channels.count < 32 else { return false }
            channels[ObjectIdentifier(channel)] = channel; return true
        }
        if accepted { channel.closeFuture.whenComplete { _ in self.lock.withLock { _ = self.channels.removeValue(forKey: ObjectIdentifier(channel)) } } }
        return accepted
    }

    func tunnel(host: String, port: Int, downstream: Channel) -> EventLoopFuture<Channel> {
        do { try route.check(host: host, port: port) }
        catch { return group.next().makeFailedFuture(CredentialBrokerError.unsupported) }
        return ClientBootstrap(group: group).connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { channel in
                guard self.track(channel) else { return channel.close() }
                return channel.pipeline.addHandler(ProxyRelay(peer: downstream, validate: { try self.route.check(host: host, port: port) }))
            }.connect(host: host, port: port)
    }

    func connect(host: String, port: Int, handler: any ChannelHandler & Sendable) -> EventLoopFuture<Channel> {
        do { try route.check(host: host, port: port) }
        catch { return group.next().makeFailedFuture(CredentialBrokerError.unsupported) }
        return ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 16384, high: 65536))
            .channelInitializer { channel in
                guard self.track(channel) else { return channel.close() }
                do {
                    let ssl = try NIOSSLClientHandler(context: self.upstreamTLS, serverHostname: host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) ? nil : host)
                    try channel.pipeline.syncOperations.addHandlers([ssl, HTTPRequestEncoder(), ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)), handler])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(CredentialBrokerError.unavailable) }
            }.connect(host: host, port: port)
    }
}

private nonisolated final class ProxyIngress: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let proxy: CredentialHTTPSProxy
    private var head: HTTPRequestHead?
    private var body = Data()
    private var authority: String?
    private var done = false
    private var task: Task<Void, Never>?
    private var deadline: Scheduled<Void>?
    private var upstream: Channel?

    init(proxy: CredentialHTTPSProxy, authority: String? = nil) { self.proxy = proxy; self.authority = authority }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel(); task?.cancel(); upstream?.close(promise: nil)
        body.resetBytes(in: 0..<body.count)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { context.close(promise: nil); return }
        switch unwrapInboundIn(data) {
        case .head(let value):
            guard head == nil else { context.close(promise: nil); return }
            head = value
        case .body(var buffer):
            guard head != nil, authority != nil, body.count + buffer.readableBytes <= CredentialProxyHTTP.maximumBody else { context.close(promise: nil); return }
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end(let trailers):
            guard trailers == nil, let head else { context.close(promise: nil); return }
            done = true
            if let authority { submit(head: head, authority: authority, context: context) }
            else { acceptCONNECT(head: head, context: context) }
        }
    }

    private func acceptCONNECT(head: HTTPRequestHead, context: ChannelHandlerContext) {
        do {
            let target = try CredentialProxyHTTP.connect(head, expectedAuthorization: proxy.route.authorization)
            try proxy.route.check(host: target.host, port: target.port)
            let authority = target.host + ":" + String(target.port)
            guard proxy.route.destinations.contains(where: { $0.host == target.host && $0.effectivePort == target.port }),
                  let identity = proxy.identities[target.host] else {
                acceptTunnel(host: target.host, port: target.port, context: context)
                return
            }
            let channel = context.channel
            let promise = context.eventLoop.makePromise(of: Void.self)
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "0")])))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
            promise.futureResult.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: false)
            }.flatMap {
                channel.pipeline.removeHandler(self)
            }.flatMap {
                channel.pipeline.removeHandler(name: "http-request-decoder")
            }.flatMap {
                channel.pipeline.removeHandler(name: "http-response-encoder")
            }.flatMap {
                do {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: identity.context))
                    try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder(), name: "http-response-encoder")
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes)), name: "http-request-decoder")
                    try channel.pipeline.syncOperations.addHandler(ProxyIngress(proxy: self.proxy, authority: authority))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(CredentialBrokerError.unavailable) }
            }.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: true)
            }.whenFailure { _ in channel.close(promise: nil) }
        } catch {
            let head = HTTPResponseHead(version: .http1_1, status: .proxyAuthenticationRequired,
                headers: HTTPHeaders([("proxy-authenticate", "Basic realm=\"Shepherd\""), ("content-length", "0"), ("connection", "close")]))
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
    }

    private func acceptTunnel(host: String, port: Int, context: ChannelHandlerContext) {
        let downstream = context.channel
        proxy.tunnel(host: host, port: port, downstream: downstream).flatMap { upstream in
            self.upstream = upstream
            let promise = downstream.eventLoop.makePromise(of: Void.self)
            downstream.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "0")]))), promise: nil)
            downstream.writeAndFlush(HTTPServerResponsePart.end(nil), promise: promise)
            return promise.futureResult.flatMap { downstream.setOption(ChannelOptions.autoRead, value: false) }
                .flatMap { downstream.pipeline.removeHandler(self) }
                .flatMap { downstream.pipeline.removeHandler(name: "http-request-decoder") }
                .flatMap { downstream.pipeline.removeHandler(name: "http-response-encoder") }
                .flatMap { downstream.pipeline.addHandler(ProxyRelay(peer: upstream, validate: { try self.proxy.route.check(host: host, port: port) })) }
                .map { downstream.read(); upstream.read() }
        }.whenFailure { _ in downstream.close(promise: nil) }
    }

    private func submit(head: HTTPRequestHead, authority: String, context: ChannelHandlerContext) {
        do {
            if head.method == .GET || head.method == .HEAD {
                try CredentialProxyHTTP.browsing(head, body: body, authority: authority)
                let target = try CredentialProxyHTTP.authority(authority)
                let channel = context.channel
                let response = ProxyResponse(downstream: channel)
                task = Task {
                    do {
                        let upstream = try await proxy.connect(host: target.host, port: target.port, handler: response).get()
                        try await channel.eventLoop.submit { self.upstream = upstream }.get()
                        try await response.verified.futureResult.get()
                        try Task.checkCancellation()
                        try proxy.route.check(host: target.host, port: target.port)
                        upstream.write(HTTPClientRequestPart.head(CredentialProxyHTTP.upstreamHead(head, bodyCount: 0)), promise: nil)
                        upstream.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                    } catch { channel.close(promise: nil) }
                }
                return
            }
            let approved = try proxy.route.destination(authority: authority, path: head.uri)
            let (observed, ticket) = try CredentialProxyHTTP.observed(head, body: body, authority: authority, field: approved.field)
            guard observed.destination == approved else { throw CredentialBrokerError.denied }
            try proxy.route.check(host: approved.host, port: approved.effectivePort)
            let channel = context.channel
            let response = ProxyResponse(downstream: channel)
            task = Task {
                do {
                    let upstream = try await proxy.connect(host: approved.host, port: approved.effectivePort, handler: response).get()
                    try await channel.eventLoop.submit { self.upstream = upstream }.get()
                    try await response.verified.futureResult.get()
                    try Task.checkCancellation()
                    try proxy.route.check(host: approved.host, port: approved.effectivePort)
                    let transport = ProxyWrite(channel: upstream, head: head, route: proxy.route)
                    try await proxy.consumer.consumeRequest(ticket, observed: observed, transport: transport)
                } catch { channel.eventLoop.execute { channel.close(promise: nil); self.upstream?.close(promise: nil) } }
            }
        } catch { context.close(promise: nil) }
    }
}

nonisolated final class ProxyWrite: CredentialSecretTransport, @unchecked Sendable {
    let channel: Channel
    let head: HTTPRequestHead
    let route: CredentialProxyRoute
    init(channel: Channel, head: HTTPRequestHead, route: CredentialProxyRoute) { self.channel = channel; self.head = head; self.route = route }
    func beginWrite(_ secret: consuming CredentialSecretLease, request: CredentialObservedRequest) throws {
        try route.check(host: request.destination.host, port: request.destination.effectivePort)
        guard channel.isActive, channel.isWritable else { throw CredentialBrokerError.cancelled }
        let authorization = secret.authorization
        try secret.consumeForTransport { bytes in
            let body = try CredentialProxyHTTP.substituting(bytes, request: request)
            // Channel.write called from another executor only queues work. Check
            // authority on the NIO loop immediately before the pipeline sees it.
            channel.eventLoop.execute { [self] in
                var payload = body
                defer { payload.resetBytes(in: 0..<payload.count) }
                do {
                    try authorization.withCommit {
                        try route.withWrite(host: request.destination.host, port: request.destination.effectivePort) {
                            guard channel.isActive, channel.isWritable else { throw CredentialBrokerError.cancelled }
                            var buffer = channel.allocator.buffer(capacity: payload.count)
                            buffer.writeBytes(payload)
                            channel.write(HTTPClientRequestPart.head(CredentialProxyHTTP.upstreamHead(head, bodyCount: payload.count)), promise: nil)
                            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
                            channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                        }
                    }
                } catch { channel.close(promise: nil) }
            }
        }
    }
}

private nonisolated final class ProxyResponse: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    private let downstream: Channel
    let verified: EventLoopPromise<Void>
    private var ready = false
    private var bytes = 0
    init(downstream: Channel) { self.downstream = downstream; verified = downstream.eventLoop.makePromise(of: Void.self) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { ready = true; verified.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !ready { verified.fail(CredentialBrokerError.unavailable) }
        downstream.close(promise: nil)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !ready { ready = true; verified.fail(CredentialBrokerError.unavailable) }
        downstream.close(promise: nil); context.close(promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(var head):
            // Never follow redirects or auth challenges. The grant is already
            // consumed; browser retries have no reusable ticket/authority.
            head.headers.remove(name: "proxy-authenticate")
            head.headers.remove(name: CredentialProxyHTTP.provenanceHeader)
            downstream.write(HTTPServerResponsePart.head(head), promise: nil)
        case .body(let body):
            bytes += body.readableBytes
            guard bytes <= 1048576 else { context.close(promise: nil); downstream.close(promise: nil); return }
            downstream.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        case .end:
            let channel = context.channel
            downstream.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil); self.downstream.close(promise: nil)
            }
        }
    }
}

private nonisolated final class ProxyRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    private var transferred = 0
    private var deadline: Scheduled<Void>?
    private let validate: @Sendable () throws -> Void
    init(peer: Channel, validate: @escaping @Sendable () throws -> Void) { self.peer = peer; self.validate = validate }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: .seconds(30)) {
            self.peer.close(promise: nil); channel.close(promise: nil)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do { try validate() }
        catch { context.close(promise: nil); peer.close(promise: nil); return }
        let buffer = unwrapInboundIn(data)
        transferred += buffer.readableBytes
        guard transferred <= 16777216, peer.isActive else { context.close(promise: nil); peer.close(promise: nil); return }
        let source = context.channel
        peer.writeAndFlush(buffer).whenComplete { result in
            switch result {
            case .success: source.read()
            case .failure: source.close(promise: nil); self.peer.close(promise: nil)
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) { deadline?.cancel(); peer.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil); peer.close(promise: nil) }
}
#endif
