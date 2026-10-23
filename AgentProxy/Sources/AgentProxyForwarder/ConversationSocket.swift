import Foundation
import Darwin
import NIOCore
import NIOPosix
import AgentProxyCore
import AgentProxyProtocol

/// One event loop owns tee ingestion, history and all read clients. The parent
/// forwarder never waits for this process. No raw request/error/transcript logs.
enum ConversationSocket {
    static func run(descriptor: Int32, path: String) -> Int32 {
        let lease: SocketLease
        do { lease = try SocketLease(path) } catch { return 4 }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = ReadState(loop: group.next())
        var listener: Channel?
        var tee: Channel?
        defer {
            try? state.loop.submit { state.stop() }.wait()
            try? listener?.close().wait()
            try? tee?.close().wait()
            try? group.syncShutdownGracefully()
            lease.cleanup()
        }
        do {
            // NIO-created Unix listeners unconditionally unlink their pathname
            // on close. Adopt our bound descriptor instead, so only the lease's
            // inode-checked cleanup can remove a socket.
            let boundDescriptor = try lease.bindDescriptor()
            listener = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 64 << 10))
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 64 << 10, high: 2 << 20))
                .childChannelInitializer { channel in state.add(channel) }
                .withBoundSocket(boundDescriptor).wait()
            tee = try ClientBootstrap(group: group)
                .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 64 << 10))
                .channelInitializer { channel in channel.pipeline.addHandler(TeeInput(state)) }
                .withConnectedSocket(descriptor).wait()
            try state.loop.submit { state.start() }.wait()
            try tee!.closeFuture.wait()
            return try state.loop.submit { state.exitCode }.wait()
        } catch { return 4 }
    }
}

/// A private lock prevents two cooperating recorders from unlinking each
/// other's listener. Never unlink a file/symlink, an active socket or a path
/// whose inode changed after bind. Only an empty coordination file persists.
private final class SocketLease {
    let path: String
    private let lock: Int32
    private var inode: ino_t?
    private var device: dev_t?
    init(_ path: String) throws {
        guard AgentProxyPaths.socketPathFits(path) else { throw UnsafePath() }
        try StateDirectory.prepareSocketFolder(for: path)
        let folder = (path as NSString).deletingLastPathComponent
        // This is our app's own support folder, not Library/Application Support
        // or an arbitrary caller's home/tmp folder. Custom paths must already
        // use a private folder; never chmod those on the caller's behalf.
        if (folder as NSString).lastPathComponent == AgentProxyPaths.applicationFolder {
            _ = try StateDirectory.prepare(folder)
        }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw UnsafePath() }
        let fd = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw UnsafePath() }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw UnsafePath()
        }
        do { try Self.clearStale(path) } catch { Darwin.close(fd); throw error }
        self.path = path; lock = fd
    }
    deinit { Darwin.close(lock) }
    func bindDescriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnsafePath() }
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw UnsafePath() }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for (i, byte) in path.utf8.enumerated() { bytes[i] = byte }
                bytes[path.utf8.count] = 0
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw UnsafePath() }
            try bound()
            guard listen(fd, 16) == 0 else { throw UnsafePath() }
            return fd // ownership transfers to NIO, including close on failure
        } catch { Darwin.close(fd); throw error }
    }
    private func bound() throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw UnsafePath() }
        inode = info.st_ino; device = info.st_dev
        guard chmod(path, 0o600) == 0 else { throw UnsafePath() }
    }
    func cleanup() {
        var info = stat()
        if let inode, let device, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
           info.st_uid == getuid(), info.st_ino == inode, info.st_dev == device { unlink(path) }
    }
    private static func clearStale(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { if errno == ENOENT { return }; throw UnsafePath() }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw UnsafePath() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnsafePath() }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UnsafePath() }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (i, byte) in path.utf8.enumerated() { bytes[i] = byte }
            bytes[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // In-progress/backlog-full/permission failures are NOT stale evidence.
        guard result < 0, errno == ECONNREFUSED else { throw UnsafePath() }
        var current = stat()
        guard lstat(path, &current) == 0, current.st_ino == info.st_ino, current.st_dev == info.st_dev,
              current.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else { throw UnsafePath() }
    }
    struct UnsafePath: Error {}
}

private final class ReadState: @unchecked Sendable {
    let loop: EventLoop
    let capture = ConversationCapture(makeDecoder: AgentProxyBodyDecoder.make)
    var exitCode: Int32 = 0
    var clients: [ObjectIdentifier: ReadClient] = [:]
    private var ticker: RepeatedTask?
    init(loop: EventLoop) { self.loop = loop }
    func start() {
        loop.assertInEventLoop()
        ticker = loop.scheduleRepeatedTask(initialDelay: .milliseconds(100), delay: .milliseconds(100)) { [weak self] _ in
            guard let self else { return }
            for client in Array(self.clients.values) { client.tick() }
        }
    }
    func add(_ channel: Channel) -> EventLoopFuture<Void> {
        loop.assertInEventLoop()
        guard clients.count < 16, let reservation = capture.reserve(bytes: 4 << 20) else { return channel.close() }
        let key = ObjectIdentifier(channel)
        let client = ReadClient(state: self, channel: channel)
        clients[key] = client
        channel.closeFuture.whenComplete { _ in
            self.clients.removeValue(forKey: key)
            self.capture.release(reservation)
        }
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ReadLine()))
            try channel.pipeline.syncOperations.addHandler(client)
        }
    }
    func stop() {
        loop.assertInEventLoop(); ticker?.cancel(); ticker = nil
        capture.finishAll()
        for client in Array(clients.values) { client.channel.close(promise: nil) }
    }
}

private final class TeeInput: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let state: ReadState
    var decoder = AgentProxyTeeFrame.Decoder()
    init(_ state: ReadState) { self.state = state }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        decoder.append(unwrapInboundIn(data).readableBytesView)
        do { while let frame = try decoder.next() { state.capture.consume(frame) } }
        catch { state.exitCode = 3; context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { state.capture.finishAll(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.exitCode = 3; context.close(promise: nil) }
}

private struct ReadLine: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let newline = buffer.readableBytesView.firstIndex(of: 10) {
            let size = newline - buffer.readerIndex
            guard size <= ConversationReadAPI.maximumRequestBytes, let line = buffer.readSlice(length: size) else { throw TooLong() }
            buffer.moveReaderIndex(forwardBy: 1); context.fireChannelRead(NIOAny(line)); return .continue
        }
        guard buffer.readableBytes <= ConversationReadAPI.maximumRequestBytes else { throw TooLong() }
        return .needMoreData
    }
    struct TooLong: Error {}
}

private final class ReadClient: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let state: ReadState
    let channel: Channel
    private var requested = false
    private var cursor: ConversationReadAPI.Cursor?
    private var pendingSince: NIODeadline?
    private var initialDeadline: Scheduled<Void>?
    init(state: ReadState, channel: Channel) { self.state = state; self.channel = channel }
    func channelActive(context: ChannelHandlerContext) {
        initialDeadline = channel.eventLoop.scheduleTask(in: .seconds(15)) { [weak self] in
            guard let self, !self.requested else { return }; self.channel.close(promise: nil)
        }
        context.fireChannelActive()
    }
    func channelInactive(context: ChannelHandlerContext) { initialDeadline?.cancel(); context.fireChannelInactive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // One query per channel; a subscribe query turns it into an event stream.
        // Never accumulate pipelined replies or retain unbounded request state.
        guard !requested else { context.close(promise: nil); return }
        requested = true; initialDeadline?.cancel()
        guard let reservation = state.capture.reserve(bytes: 8 << 20) else { context.close(promise: nil); return }
        defer { state.capture.release(reservation) }
        let line = Data(unwrapInboundIn(data).readableBytesView)
        let bytes = ConversationReadAPI.answer(line, store: state.capture.reconciler.store)
        struct Method: Decodable { let method: String }
        if (try? JSONDecoder().decode(Method.self, from: line).method) == "conversation.subscribe",
           let result = try? JSONDecoder().decode(ConversationReadAPI.Reply.self, from: bytes).result, !result.reset {
            cursor = ConversationReadAPI.Cursor(result)
        }
        write(bytes, closeAfter: cursor == nil)
    }
    func tick() {
        if let since = pendingSince {
            if NIODeadline.now() - since >= .seconds(5) { channel.close(promise: nil) }
            return // coalesce, don't queue intermediate snapshots
        }
        guard let cursor else { return }
        guard let reservation = state.capture.reserve(bytes: 8 << 20) else { channel.close(promise: nil); return }
        defer { state.capture.release(reservation) }
        guard let update = ConversationReadAPI.update(after: cursor, store: state.capture.reconciler.store) else { return }
        self.cursor = ConversationReadAPI.Cursor(update)
        write(ConversationReadAPI.encodeUpdate(update), closeAfter: self.cursor == nil)
    }
    private func write(_ bytes: Data, closeAfter: Bool) {
        guard pendingSince == nil, bytes.count <= ConversationReadAPI.maximumReplyBytes else { channel.close(promise: nil); return }
        pendingSince = .now()
        var buffer = channel.allocator.buffer(capacity: bytes.count); buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer).whenComplete { result in
            self.pendingSince = nil
            if closeAfter { self.channel.close(promise: nil) }
            else if case .failure = result { self.channel.close(promise: nil) }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
