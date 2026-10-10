#if os(macOS)
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// The NIO channel is the transport only. All pane/CEF ownership lives on the
/// main actor. No token, URL parameters, or protocol payload is logged here.
nonisolated final class CDPWebSocket: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private let channel: Channel
    private let received: @Sendable (CDPWebSocket, String?) -> Void
    private var fragments = ByteBuffer()
    private var fragmented = false
    private let maximumMessageBytes: Int
    private let singleRequest: Bool
    private var delivered = false

    init(channel: Channel, maximumMessageBytes: Int = CDPPolicy.maximumMessageBytes,
         singleRequest: Bool = false, received: @escaping @Sendable (CDPWebSocket, String?) -> Void) {
        self.channel = channel
        self.received = received
        self.maximumMessageBytes = maximumMessageBytes
        self.singleRequest = singleRequest
    }

    func send(_ text: String, closeAfterWrite: Bool = false) {
        channel.eventLoop.execute {
            var bytes = self.channel.allocator.buffer(capacity: text.utf8.count)
            bytes.writeString(text)
            let future = self.channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: bytes))
            if closeAfterWrite { future.whenComplete { _ in self.channel.close(promise: nil) } }
        }
    }
    func close() { channel.close(promise: nil) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.maskKey != nil else { close(); return }
        var bytes = frame.unmaskedData
        switch frame.opcode {
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: bytes)), promise: nil)
        case .pong: break
        case .connectionClose: close()
        case .text, .continuation:
            guard (frame.opcode == .text && !fragmented) || (frame.opcode == .continuation && fragmented),
                  (!singleRequest || !delivered), fragments.readableBytes + bytes.readableBytes <= maximumMessageBytes else { close(); return }
            fragments.writeBuffer(&bytes)
            fragmented = !frame.fin
            if frame.fin {
                guard let data = fragments.readBytes(length: fragments.readableBytes),
                      let text = String(bytes: data, encoding: .utf8) else { close(); return }
                fragments.clear()
                delivered = true
                received(self, text)
            }
        default: close()
        }
    }
    func channelInactive(context: ChannelHandlerContext) { received(self, nil); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { close() }
}

nonisolated private final class CDPHTTPRejection: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head = unwrapInboundIn(data) {
            let head = HTTPResponseHead(version: .http1_1, status: .unauthorized,
                                        headers: HTTPHeaders([("Content-Length", "0"), ("Connection", "close")]))
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
        }
    }
}

@MainActor
final class CDPListener {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var server: Channel?
    private var children: [CDPWebSocket] = []

    func start(port: Int, token: String,
               authorizeRoute: @escaping @MainActor @Sendable (CDPRoute) -> Bool,
               accept: @escaping @MainActor @Sendable (CDPRoute, CDPWebSocket, String?) -> Void,
               credentialService: CredentialCLIService? = nil) async throws -> Int {
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: CDPPolicy.maximumMessageBytes,
            automaticErrorHandling: true, shouldUpgrade: { channel, head in
                guard head.method == .GET, (CDPRoute(head.uri) != nil || CredentialRoute(head.uri) != nil),
                      head.headers["origin"].isEmpty,
                      CDPPolicy.authenticated(head.headers["authorization"], token: token) else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                let route = CDPRoute(head.uri)
                let credentialRoute = CredentialRoute(head.uri)
                let leaseHeaders = head.headers["x-shepherd-credential-lease"]
                Task { @MainActor in
                    let accepted: Bool
                    if let route { accepted = authorizeRoute(route) }
                    else if let credentialRoute, let credentialService {
                        accepted = authorizeRoute(credentialRoute.paneRoute) && credentialService.authenticated(credentialRoute, headers: leaseHeaders)
                    } else { accepted = false }
                    channel.eventLoop.execute { promise.succeed(accepted ? HTTPHeaders() : nil) }
                }
                return promise.futureResult
            }, upgradePipelineHandler: { channel, head in
                let route = CDPRoute(head.uri)
                let credentialRoute = CredentialRoute(head.uri)
                let leaseHeaders = head.headers["x-shepherd-credential-lease"]
                // Assign the socket before any frames can arrive on its pipeline.
                let socket = CDPWebSocket(channel: channel, maximumMessageBytes: credentialRoute == nil ? CDPPolicy.maximumMessageBytes : 16384,
                                          singleRequest: credentialRoute != nil) { socket, text in
                    Task { @MainActor in
                        if let route { accept(route, socket, text) }
                        else if let credentialRoute, let credentialService, let text {
                            guard authorizeRoute(credentialRoute.paneRoute) else { socket.close(); return }
                            socket.send(await credentialService.receive(credentialRoute, headers: leaseHeaders, text: text), closeAfterWrite: true)
                        } else { socket.close() }
                    }
                }
                Task { @MainActor in
                    self.children.append(socket)
                    channel.closeFuture.whenComplete { _ in Task { @MainActor in self.children.removeAll { $0 === socket } } }
                }
                return channel.pipeline.addHandler(socket)
            })
        server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (
                    upgraders: [upgrader], completionHandler: { context in
                        context.pipeline.removeHandler(name: "reject", promise: nil)
                    })).flatMap { channel.pipeline.addHandler(CDPHTTPRejection(), name: "reject") }
            }.bind(host: "127.0.0.1", port: port).get()
        return server!.localAddress!.port!
    }

    func stop() async {
        children.forEach { $0.close() }
        children = []
        try? await server?.close().get()
        server = nil
    }
    deinit { group.shutdownGracefully { _ in } }
}

#endif
