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
        let identity = ControlSocketIdentity(path: path)
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                guard connections.add(channel) else { return channel.close() }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDecoder()))
                    try channel.pipeline.syncOperations.addHandler(ControlHandler(core: core, identity: identity))
                }
            }
            .bind(unixDomainSocketPath: path).wait()
        guard chmod(path, 0o600) == 0 else {
            channel.close(promise: nil)
            throw AgentProxyStartError.socketPath("cannot be made private")
        }
        let verified = try channel.eventLoop.submit { identity.install() }.wait()
        guard verified else { channel.close(promise: nil); throw AgentProxyStartError.socketPath("cannot verify private control socket") }
        return channel
    }
}

/// Captured on the control event loop; every destructive request rechecks the
/// bound inode, private socket and owner-only-writable parent before use.
private final class ControlSocketIdentity: @unchecked Sendable {
    private let path: String
    private var device: dev_t?
    private var inode: ino_t?
    init(path: String) { self.path = path }
    func install() -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { return false }
        device = info.st_dev; inode = info.st_ino
        return valid()
    }
    func valid() -> Bool {
        var file = stat(), parent = stat()
        let folder = (path as NSString).deletingLastPathComponent
        return lstat(folder, &parent) == 0 && parent.st_mode & S_IFMT == S_IFDIR &&
            parent.st_uid == geteuid() && parent.st_mode & 0o022 == 0 &&
            lstat(path, &file) == 0 && file.st_mode & S_IFMT == S_IFSOCK &&
            file.st_uid == geteuid() && file.st_mode & 0o077 == 0 &&
            file.st_dev == device && file.st_ino == inode
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
    private let identity: ControlSocketIdentity
    private var pendingRemovals = 0
    private var pendingClear = false
    private var processing = false
    private var queuedLines: [Data] = []

    init(core: ProxyCore, identity: ControlSocketIdentity) { self.core = core; self.identity = identity }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard queuedLines.count < 16 else { context.close(promise: nil); return }
        queuedLines.append(Data(unwrapInboundIn(data).readableBytesView))
        processNext(context: context)
    }

    private func processNext(context: ChannelHandlerContext) {
        guard !processing, !queuedLines.isEmpty, context.channel.isActive else { return }
        processing = true
        let line = queuedLines.removeFirst()
        if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
           let method = object["method"] as? String {
            if method == AgentProxyControl.Method.routesRemove.rawValue { removeRoute(object, context: context); return }
            if method == AgentProxyControl.Method.clearHistory.rawValue { clearHistory(object, context: context); return }
        }
        let (reply, afterwards) = answer(line)
        write(reply, context: context, afterwards: afterwards)
    }

    private func write(_ reply: Data, context: ChannelHandlerContext, afterwards: (() -> Void)? = nil) {
        var buffer = context.channel.allocator.buffer(capacity: reply.count + 1)
        buffer.writeBytes(reply)
        buffer.writeInteger(UInt8(0x0A))
        let written = context.writeAndFlush(wrapOutboundOut(buffer))
        written.whenComplete { [self] _ in
            afterwards?()
            processing = false
            processNext(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    private func clearHistory(_ object: [String: Any], context: ChannelHandlerContext) {
        guard !pendingClear, let id = object["id"] as? String,
              let request = try? decode(AgentProxyHistoryClearRequest.self, object["params"] ?? [String: Any]()),
              request.confirmed else {
            write(encode(id: object["id"] as? String, error: AgentProxyControlError(code: .invalidParams, message: "Explicit confirmation is required.")), context: context)
            return
        }
        guard geteuid() != 0, identity.valid(), let provider = context.channel as? any SocketOptionProvider else {
            write(encode(id: id, error: AgentProxyControlError(code: .unavailable, message: "Local control identity could not be verified.")), context: context)
            return
        }
        pendingClear = true
        let peer: EventLoopFuture<xucred> = provider.unsafeGetSocketOption(
            level: NIOBSDSocket.OptionLevel(rawValue: SOL_LOCAL), name: NIOBSDSocket.Option(rawValue: LOCAL_PEERCRED))
        peer.whenComplete { [self] result in
            guard context.channel.isActive else { pendingClear = false; return }
            guard case .success(let credentials) = result, credentials.cr_version == UInt32(XUCRED_VERSION),
                  credentials.cr_uid == geteuid(), identity.valid(), let recorder = core.recorder else {
                pendingClear = false
                write(encode(id: id, error: AgentProxyControlError(code: .unavailable, message: "Local recorder identity is unavailable.")), context: context)
                return
            }
            recorder.clearHistory().whenComplete { [self] outcome in
                pendingClear = false
                guard context.channel.isActive else { return }
                switch outcome {
                case .success: write(encode(id: id, result: AgentProxyHistoryCleared(cleared: true)), context: context)
                case .failure(let error):
                    let message = (error as? RecorderSupervisor.ClearError) == .partial
                        ? "History clear was incomplete; some data may already have been removed."
                        : "Clear is unavailable because all history producers cannot be safely fenced."
                    write(encode(id: id, error: AgentProxyControlError(code: .unavailable, message: message)), context: context)
                }
            }
        }
    }

    private func removeRoute(_ object: [String: Any], context: ChannelHandlerContext) {
        guard pendingRemovals < 16 else { context.close(promise: nil); return }
        guard let id = object["id"] as? String else {
            write(encode(id: nil, error: AgentProxyControlError(code: .parseError, message: "A request needs a string id and method.")), context: context)
            return
        }
        do {
            let request = try decode(AgentProxyRouteRemove.self, object["params"] ?? [String: Any]())
            let removed = try core.routes.remove(routeID: request.routeID)
            guard let recorder = core.recorder else {
                write(encode(id: id, result: AgentProxyRouteRemoved(removed: removed)), context: context)
                return
            }
            pendingRemovals += 1
            recorder.waitForAuthority().whenComplete { [self] result in
                pendingRemovals -= 1
                guard context.channel.isActive else { return }
                switch result {
                case .success:
                    write(encode(id: id, result: AgentProxyRouteRemoved(removed: removed)), context: context)
                case .failure:
                    write(encode(id: id, error: AgentProxyControlError(code: .unavailable, message: "Recorder authority could not be synchronized.")), context: context)
                }
            }
        } catch let error as AgentProxyControlError {
            write(encode(id: id, error: error), context: context)
        } catch {
            write(encode(id: id, error: AgentProxyControlError(code: .invalidParams, message: "The params don't fit the method.")), context: context)
        }
    }

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
                return (encode(id: id, error: AgentProxyControlError(code: .unavailable, message: "Route removal requires synchronization.")), nil)
            case .routesList:
                return (encode(id: id, result: AgentProxyRouteList(routes: core.routes.list())), nil)
            case .clearHistory:
                return (encode(id: id, error: AgentProxyControlError(code: .unavailable, message: "Local confirmation and peer verification are required.")), nil)
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
