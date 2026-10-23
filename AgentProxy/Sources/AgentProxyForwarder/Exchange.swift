import Foundation
import NIOCore
import NIOHTTP1
import AgentProxyProtocol

/// One agent connection to the listener. Requests on it are taken one at a
/// time; each forwarded one is an `Exchange`.
///
/// Used on the proxy's event loop only.
final class DownstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// A connection with no request on it for this long is closed.
    static let idleTimeout: TimeAmount = .seconds(120)

    private let core: ProxyCore
    private var exchange: Exchange?
    private var discarding = false
    private var idleTimer: Scheduled<Void>?

    init(core: ProxyCore) { self.core = core }

    func channelActive(context: ChannelHandlerContext) {
        armIdleTimer(context.channel)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        idleTimer?.cancel()
        let exchange = exchange
        self.exchange = nil
        exchange?.downstreamClosed()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !discarding else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            // One request at a time; agents don't pipeline.
            guard exchange == nil else { context.close(promise: nil); return }
            idleTimer?.cancel()
            let port = context.channel.localAddress?.port ?? -1
            switch ForwardingRules.admit(head, port: port, lookup: { core.routes.lookup(token: $0) }) {
            case .failure(let rejection):
                reject(rejection, context: context)
            case .success(let decision):
                let exchange = Exchange(core: core, handler: self, downstream: context.channel, head: head, decision: decision)
                self.exchange = exchange
                exchange.start()
            }
        case .body(let buffer):
            exchange?.requestBody(buffer)
        case .end:
            exchange?.requestEnd()
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        exchange?.downstreamWritabilityChanged(context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A request the decoder can't read.
        if exchange == nil && !discarding {
            discarding = true
            core.rejected(status: .badRequest, reason: "malformed")
            Self.respond(status: .badRequest, provider: nil, message: "Malformed request.", on: context.channel)
        } else {
            context.close(promise: nil)
        }
    }

    private func reject(_ rejection: Rejection, context: ChannelHandlerContext) {
        discarding = true
        core.rejected(status: rejection.status, reason: rejection.reason.rawValue)
        if rejection.reason == .oauth, let routeID = rejection.routeID { core.routes.markRejected(routeID: routeID, log: core.log) }
        Self.respond(status: rejection.status, provider: rejection.provider, message: rejection.message, on: context.channel)
    }

    /// The exchange is over; the connection takes the next request, or closes.
    func exchangeFinished(keepAlive: Bool, channel: Channel) {
        exchange = nil
        if !keepAlive { discarding = true }
        if keepAlive {
            armIdleTimer(channel)
            try? channel.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
        }
    }

    private func armIdleTimer(_ channel: Channel) {
        idleTimer?.cancel()
        idleTimer = channel.eventLoop.scheduleTask(in: Self.idleTimeout) { channel.close(promise: nil) }
    }

    /// An answer of the proxy's own, after which the connection closes.
    static func respond(status: HTTPResponseStatus, provider: AgentProxyUpstream?, message: String, on channel: Channel,
                        extraHeaders: [(String, String)] = []) {
        let (contentType, body) = ForwardingRules.errorBody(status: status, provider: provider, message: message)
        var headers = HTTPHeaders([("content-type", contentType), ("content-length", String(body.count)), ("connection", "close")])
        if status == .methodNotAllowed { headers.add(name: "allow", value: "GET, POST, HEAD") }
        for (name, value) in extraHeaders { headers.add(name: name, value: value) }
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
}

/// One forwarded request and its response. The request goes upstream as it
/// came (the headers as `ForwardingRules.upstreamHeaders` leaves them, the
/// body byte for byte, framed the same way), and the response comes back the
/// same way, each piece flushed to the agent as soon as it arrives. If the
/// agent goes away the upstream connection is closed at once; if the
/// upstream goes away mid-response, the agent's connection is closed without
/// the response's end, so the agent sees it cut off.
///
/// Used on the proxy's event loop only.
final class Exchange {
    enum Outcome { case complete, aborted }

    let id: UInt64
    private let core: ProxyCore
    private let handler: DownstreamHandler
    private let downstream: Channel
    private let decision: ForwardDecision
    private let method: HTTPMethod
    private let upstreamHead: HTTPRequestHead
    private let clientWantsClose: Bool
    private var connection: UpstreamConnection?
    private var pending: [ByteBuffer] = []
    private var requestComplete = false
    private var requestSent = false
    private var responseStarted = false
    private var responseStatus: UInt = 0
    private var closeDelimited = false
    private var finished = false
    private var copied = false
    private var lastWrite: EventLoopFuture<Void>?

    init(core: ProxyCore, handler: DownstreamHandler, downstream: Channel, head: HTTPRequestHead, decision: ForwardDecision) {
        self.core = core; self.handler = handler; self.downstream = downstream; self.decision = decision
        id = core.nextExchangeID()
        method = head.method
        clientWantsClose = ForwardingRules.wantsClose(head.headers)
        upstreamHead = HTTPRequestHead(version: .http1_1, method: head.method, uri: decision.target,
                                       headers: ForwardingRules.upstreamHeaders(head.headers, upstream: decision.upstream))
        if let route = decision.route {
            copied = core.tee.open(id, AgentProxyTeeFrame.Open(routeID: route.routeID, upstream: decision.upstream.rawValue,
                                                                method: head.method.rawValue, path: decision.path,
                                                                headers: ForwardingRules.teeRequestHeaders(head.headers),
                                                                routeIdentity: AgentProxyRouteCreate(kind: route.kind, session: route.session,
                                                                                                     paneID: route.paneID, terminalID: route.terminalID,
                                                                                                     cliVersion: route.cliVersion)))
        }
    }

    func start() {
        core.began(routeID: decision.route?.routeID)
        // Hold the agent's body until there is somewhere to send it.
        try? downstream.syncOptions?.setOption(ChannelOptions.autoRead, value: false)
        core.pool.acquire(decision.upstream).whenComplete { [self] result in
            switch result {
            case .success(let connection):
                guard !finished else { core.pool.discard(connection); return }
                self.connection = connection
                connection.exchange = self
                connection.channel.write(HTTPClientRequestPart.head(upstreamHead), promise: nil)
                for buffer in pending { connection.channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil) }
                pending.removeAll()
                if requestComplete { sendEnd(connection) }
                connection.channel.flush()
                try? downstream.syncOptions?.setOption(ChannelOptions.autoRead, value: requestComplete || connection.channel.isWritable)
            case .failure:
                guard !finished else { return }
                core.upstreamFailed()
                DownstreamHandler.respond(status: .badGateway, provider: decision.upstream,
                                          message: "hrdrhrdrhrdr's agent proxy couldn't reach \(decision.upstream.host).", on: downstream)
                finish(.aborted, keepAlive: false)
            }
        }
    }

    func requestBody(_ buffer: ByteBuffer) {
        guard !finished else { return }
        if copied { core.tee.requestBody(id, buffer) }
        if let connection {
            connection.channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
        } else {
            pending.append(buffer)
        }
    }

    func requestEnd() {
        guard !finished else { return }
        requestComplete = true
        if copied { core.tee.requestEnd(id) }
        if let connection {
            sendEnd(connection)
            connection.channel.flush()
        }
        // Keep reading, so an agent that goes away is noticed at once.
        try? downstream.syncOptions?.setOption(ChannelOptions.autoRead, value: true)
    }

    private func sendEnd(_ connection: UpstreamConnection) {
        connection.channel.write(HTTPClientRequestPart.end(nil), promise: nil)
        requestSent = true
    }

    func upstreamWritabilityChanged(_ writable: Bool) {
        guard !finished, !requestComplete else { return }
        try? downstream.syncOptions?.setOption(ChannelOptions.autoRead, value: writable)
    }

    func downstreamWritabilityChanged(_ writable: Bool) {
        guard !finished, let connection else { return }
        try? connection.channel.syncOptions?.setOption(ChannelOptions.autoRead, value: writable)
    }

    func upstreamPart(_ part: HTTPClientResponsePart) {
        guard !finished, let connection else { return }
        switch part {
        case .head(let head):
            guard !responseStarted else { upstreamClosed(); return }
            let encodings = head.headers["transfer-encoding"]
            guard encodings.isEmpty || (encodings.count == 1 && encodings[0].lowercased() == "chunked") else {
                connection.reusable = false
                upstreamClosed()
                return
            }
            let code = head.status.code
            let bodyless = method == .HEAD || code == 204 || code == 304 || (100..<200).contains(code)
            closeDelimited = !bodyless && encodings.isEmpty && !head.headers.contains(name: "content-length")
            if closeDelimited || head.version != .http1_1 || ForwardingRules.wantsClose(head.headers) { connection.reusable = false }
            responseStarted = true
            responseStatus = code
            let out = HTTPResponseHead(version: .http1_1, status: head.status, headers: ForwardingRules.downstreamHeaders(head.headers))
            lastWrite = downstream.writeAndFlush(HTTPServerResponsePart.head(out))
            if copied { core.tee.responseHead(id, .init(status: Int(code), headers: ForwardingRules.teeResponseHeaders(head.headers))) }
        case .body(let buffer):
            if copied { core.tee.responseBody(id, buffer) }
            lastWrite = downstream.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        case .end:
            let keepAlive = requestComplete && !clientWantsClose && !closeDelimited
            let downstream = downstream
            downstream.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                if !keepAlive { downstream.close(promise: nil) }
            }
            finish(.complete, keepAlive: keepAlive)
        }
    }

    /// The upstream connection closed or failed before the response ended.
    func upstreamClosed() {
        guard !finished else { return }
        core.upstreamFailed()
        if responseStarted {
            // Cut off: no end of the chunked body, so the agent sees it as
            // incomplete. What was already written goes out first.
            let downstream = downstream
            if let lastWrite { lastWrite.whenComplete { _ in downstream.close(promise: nil) } } else { downstream.close(promise: nil) }
        } else {
            DownstreamHandler.respond(status: .badGateway, provider: decision.upstream,
                                      message: "hrdrhrdrhrdr's agent proxy lost its connection to \(decision.upstream.host).", on: downstream)
        }
        finish(.aborted, keepAlive: false)
    }

    /// The agent closed its connection.
    func downstreamClosed() {
        guard !finished else { return }
        finish(.aborted, keepAlive: false)
    }

    private func finish(_ outcome: Outcome, keepAlive: Bool) {
        guard !finished else { return }
        finished = true
        pending.removeAll()
        if copied { core.tee.end(id, outcome == .complete ? .complete : .aborted) }
        if let connection {
            connection.exchange = nil
            if outcome == .complete && requestSent && connection.reusable {
                core.pool.release(connection)
            } else {
                core.pool.discard(connection)
            }
        }
        connection = nil
        core.ended(routeID: decision.route?.routeID, status: outcome == .complete ? responseStatus : nil, upstream: decision.upstream)
        handler.exchangeFinished(keepAlive: keepAlive, channel: downstream)
    }
}
