import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS

/// Connections to the two upstreams: TLS 1.2 or later, verified in full
/// against the system's roots for the upstream's own name (which is also the
/// server name sent), HTTP/1.1 only. A connection is made when a request
/// needs one and no idle one is left; it is kept for the next request after a
/// clean exchange, at most four idle per upstream, each for 30 seconds. The
/// proxy connects for no other reason: no health checks, no retries, nothing
/// made ahead.
///
/// Used on the proxy's event loop only.
final class UpstreamPool {
    enum Addressing {
        /// The upstream's name, port 443, through the system's resolver.
        case production
        /// Tests: every upstream at a 127.0.0.1 address of the test's.
        case fixed([AgentProxyUpstream: SocketAddress])
    }

    struct Timing {
        /// From the start of the connection to the end of the TLS handshake.
        var connect: TimeAmount = .seconds(10)
        var idle: TimeAmount = .seconds(30)
        var maximumIdle = 4
    }

    enum Failure: Error {
        case timedOut, closed, unreachable
    }

    private let loop: EventLoop
    private let tls: NIOSSLContext
    private let addressing: Addressing
    private let timing: Timing
    private var idle: [AgentProxyUpstream: [UpstreamConnection]] = [:]
    private var closed = false

    init(loop: EventLoop, trustRoots: NIOSSLTrustRoots, addressing: Addressing, timing: Timing) throws {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        configuration.trustRoots = trustRoots
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = ["http/1.1"]
        tls = try NIOSSLContext(configuration: configuration)
        self.loop = loop; self.addressing = addressing; self.timing = timing
    }

    func acquire(_ upstream: AgentProxyUpstream) -> EventLoopFuture<UpstreamConnection> {
        loop.assertInEventLoop()
        while let connection = idle[upstream]?.popLast() {
            connection.unpark()
            if connection.channel.isActive { return loop.makeSucceededFuture(connection) }
            connection.channel.close(promise: nil)
        }
        return connect(upstream)
    }

    /// After a clean exchange.
    func release(_ connection: UpstreamConnection) {
        loop.assertInEventLoop()
        guard !closed, connection.reusable, connection.channel.isActive,
              idle[connection.upstream, default: []].count < timing.maximumIdle else { discard(connection); return }
        idle[connection.upstream, default: []].append(connection)
        connection.park(for: timing.idle) { [weak self] in self?.discard(connection) }
    }

    func discard(_ connection: UpstreamConnection) {
        remove(connection)
        connection.unpark()
        connection.channel.close(promise: nil)
    }

    func remove(_ connection: UpstreamConnection) {
        idle[connection.upstream]?.removeAll { $0 === connection }
    }

    func closeAll() {
        closed = true
        for connection in idle.values.flatMap({ $0 }) { discard(connection) }
        idle.removeAll()
    }

    private func connect(_ upstream: AgentProxyUpstream) -> EventLoopFuture<UpstreamConnection> {
        var fixedAddress: SocketAddress?
        if case .fixed(let addresses) = addressing {
            guard let address = addresses[upstream] else { return loop.makeFailedFuture(Failure.unreachable) }
            fixedAddress = address
        }
        let handshake = Handshake(promise: loop.makePromise(of: Void.self))
        let handler = UpstreamHandler(handshake: handshake)
        let tls = tls
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(timing.connect)
            .channelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 64 << 10, high: 256 << 10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    var noFraming = HTTPRequestEncoder.Configuration()
                    noFraming.automaticallySetFramingHeaders = false
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: upstream.host))
                    try channel.pipeline.syncOperations.addHTTPClientHandlers(leftOverBytesStrategy: .dropBytes,
                                                                            enableOutboundHeaderValidation: true,
                                                                            encoderConfiguration: noFraming)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
        let connecting = fixedAddress.map { bootstrap.connect(to: $0) } ?? bootstrap.connect(host: upstream.host, port: 443)
        var connected: Channel?
        let deadline = loop.scheduleTask(in: timing.connect) {
            handshake.complete(.failure(Failure.timedOut))
            connected?.close(promise: nil)
        }
        connecting.whenComplete { result in
            switch result {
            case .success(let channel): connected = channel
            case .failure(let error): handshake.complete(.failure(error))
            }
        }
        return connecting.and(handshake.promise.futureResult).flatMapError { [loop] error in
            connected?.close(promise: nil)
            return loop.makeFailedFuture(error)
        }.map { channel, _ in
            let connection = UpstreamConnection(channel: channel, upstream: upstream, pool: self)
            handler.connection = connection
            return connection
        }.always { _ in deadline.cancel() }
    }
}

/// The TLS handshake's outcome, settled once by whichever comes first: the
/// handshake, an error, the connection closing or the deadline.
final class Handshake {
    let promise: EventLoopPromise<Void>
    private var settled = false

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    func complete(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        promise.completeWith(result)
    }
}

/// One upstream connection, lent to one exchange at a time.
final class UpstreamConnection {
    let channel: Channel
    let upstream: AgentProxyUpstream
    private weak var pool: UpstreamPool?
    var exchange: Exchange?
    /// False once the upstream said it closes, answered with a body that ends
    /// when the connection does, or an exchange didn't end cleanly.
    var reusable = true
    private var idleTimer: Scheduled<Void>?

    init(channel: Channel, upstream: AgentProxyUpstream, pool: UpstreamPool) {
        self.channel = channel; self.upstream = upstream; self.pool = pool
    }

    func park(for time: TimeAmount, expired: @escaping () -> Void) {
        idleTimer = channel.eventLoop.scheduleTask(in: time, expired)
    }

    func unpark() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    func received(_ part: HTTPClientResponsePart) {
        guard let exchange else {
            // Nothing is asked of an idle connection.
            pool?.discard(self)
            return
        }
        exchange.upstreamPart(part)
    }

    func closed() {
        unpark()
        pool?.remove(self)
        let exchange = exchange
        self.exchange = nil
        exchange?.upstreamClosed()
    }
}

final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let handshake: Handshake
    var connection: UpstreamConnection?

    init(handshake: Handshake) { self.handshake = handshake }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { handshake.complete(.success(())) }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        connection?.received(unwrapInboundIn(data))
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        connection?.exchange?.upstreamWritabilityChanged(context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        handshake.complete(.failure(UpstreamPool.Failure.closed))
        let connection = connection
        self.connection = nil
        connection?.closed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        handshake.complete(.failure(error))
        context.close(promise: nil)
    }
}
