import Foundation
import Darwin
import NIOCore
import NIOPosix
import AgentProxyProtocol

/// `ap.sock`: 0600, newline-delimited JSON as `AgentProxyControl` describes.
enum ControlServer {
    static let maximumConnections = 16

    /// Refuses a path that is too long, isn't a socket of ours, or has a proxy
    /// answering on it; removes a stale socket left by one that stopped.
    static func clear(_ path: String) throws {
        guard AgentProxyPaths.socketPathFits(path) else { throw AgentProxyStartError.socketPath("the path is longer than a socket's path can be") }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw AgentProxyStartError.socketPath("cannot be read (errno \(errno))")
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw AgentProxyStartError.socketPath("something else is at its path")
        }
        if answers(path) { throw AgentProxyStartError.alreadyRunning }
        guard unlink(path) == 0 || errno == ENOENT else { throw AgentProxyStartError.socketPath("the stale socket cannot be removed") }
    }

    private static func answers(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }

    static func bind(_ path: String, core: ProxyCore, group: EventLoopGroup) throws -> Channel {
        let connections = ConnectionCount()
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                guard connections.add(channel) else { return channel.close() }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDecoder()))
                    try channel.pipeline.syncOperations.addHandler(ControlHandler(core: core))
                }
            }
            .bind(unixDomainSocketPath: path).wait()
        guard chmod(path, 0o600) == 0 else {
            channel.close(promise: nil)
            throw AgentProxyStartError.socketPath("cannot be made private")
        }
        return channel
    }
}

private final class ConnectionCount: @unchecked Sendable {
    private var count = 0
    func add(_ channel: Channel) -> Bool {
        guard count < ControlServer.maximumConnections else { return false }
        count += 1
        channel.closeFuture.whenComplete { _ in self.count -= 1 }
        return true
    }
}

/// Lines of at most `AgentProxyControl.maximumLineBytes`; a longer one
/// closes the connection.
private struct LineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let newline = buffer.readableBytesView.firstIndex(of: 0x0A) {
            let length = newline - buffer.readerIndex
            guard length <= AgentProxyControl.maximumLineBytes, let line = buffer.readSlice(length: length) else { throw LineTooLong() }
            buffer.moveReaderIndex(forwardBy: 1)
            context.fireChannelRead(NIOAny(line))
            return .continue
        }
        guard buffer.readableBytes <= AgentProxyControl.maximumLineBytes else { throw LineTooLong() }
        return .needMoreData
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        // A last request without its newline is answered too.
        if buffer.readableBytes > 0, buffer.readableBytesView.firstIndex(of: 0x0A) == nil {
            guard buffer.readableBytes <= AgentProxyControl.maximumLineBytes else { throw LineTooLong() }
            let line = buffer.readSlice(length: buffer.readableBytes)!
            context.fireChannelRead(NIOAny(line))
            return .needMoreData
        }
        return try decode(context: context, buffer: &buffer)
    }

    struct LineTooLong: Error {}
}

private final class ControlHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let core: ProxyCore

    init(core: ProxyCore) { self.core = core }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let line = Data(unwrapInboundIn(data).readableBytesView)
        let (reply, afterwards) = answer(line)
        var buffer = context.channel.allocator.buffer(capacity: reply.count + 1)
        buffer.writeBytes(reply)
        buffer.writeInteger(UInt8(0x0A))
        let written = context.writeAndFlush(wrapOutboundOut(buffer))
        if let afterwards { written.whenComplete { _ in afterwards() } }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    private func answer(_ line: Data) -> (Data, (() -> Void)?) {
        guard let object = try? JSONSerialization.jsonObject(with: line), let request = object as? [String: Any] else {
            return (encode(id: nil, error: AgentProxyControlError(code: .parseError, message: "Not a JSON object.")), nil)
        }
        let id = request["id"] as? String
        guard let id, let name = request["method"] as? String else {
            return (encode(id: id, error: AgentProxyControlError(code: .parseError, message: "A request needs a string id and method.")), nil)
        }
        guard let method = AgentProxyControl.Method(rawValue: name) else {
            return (encode(id: id, error: AgentProxyControlError(code: .unknownMethod, message: "Unknown method.")), nil)
        }
        let params = request["params"] ?? [String: Any]()
        do {
            switch method {
            case .status:
                return (encode(id: id, result: core.status()), nil)
            case .restartWhenIdle:
                let result = core.restartWhenIdle()
                return (encode(id: id, result: result), { [core] in core.exitIfIdle() })
            case .routesCreate:
                let request = try decode(AgentProxyRouteCreate.self, params)
                let (entry, token) = try core.routes.create(request)
                core.log("routes: created one (\(core.routes.count) in all)")
                return (encode(id: id, result: AgentProxyRouteCreated(routeID: entry.routeID, baseURL: "http://127.0.0.1:\(core.port)/p/\(token)")), nil)
            case .routesRemove:
                let request = try decode(AgentProxyRouteRemove.self, params)
                let removed = try core.routes.remove(routeID: request.routeID)
                return (encode(id: id, result: AgentProxyRouteRemoved(removed: removed)), nil)
            case .routesList:
                return (encode(id: id, result: AgentProxyRouteList(routes: core.routes.list())), nil)
            }
        } catch let error as AgentProxyControlError {
            return (encode(id: id, error: error), nil)
        } catch {
            return (encode(id: id, error: AgentProxyControlError(code: .invalidParams, message: "The params don't fit the method.")), nil)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ params: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(params) else { throw AgentProxyControlError(code: .invalidParams, message: "params must be an object.") }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: params))
    }

    private struct Reply<Result: Encodable>: Encodable {
        let id: String?
        let result: Result?
        let error: AgentProxyControlError?
    }

    private func encode<Result: Encodable>(id: String?, result: Result) -> Data {
        (try? AgentProxyControl.encoder.encode(Reply(id: id, result: result, error: nil))) ?? Data("{}".utf8)
    }

    private func encode(id: String?, error: AgentProxyControlError) -> Data {
        (try? AgentProxyControl.encoder.encode(Reply<EmptyParams>(id: id, result: nil, error: error))) ?? Data("{}".utf8)
    }
}
