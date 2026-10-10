#if os(macOS)
import Foundation
import Darwin
import NIOCore
import NIOPosix

/// One bounded JSON request per Unix connection. The peer PID is read by the
/// kernel; no claimed PID or bearer token is logged by the transport.
nonisolated private final class PiBridgeChannel: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var input = Data()
    private var delivered = false
    private var deadline: Scheduled<Void>?
    private let peerPID: Int32
    private let receive: @MainActor @Sendable (Int32, Data) async -> Data
    init(peerPID: Int32, receive: @escaping @MainActor @Sendable (Int32, Data) async -> Data) {
        self.peerPID = peerPID; self.receive = receive
    }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = channel.eventLoop.scheduleTask(in: .seconds(12)) { channel.close(promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard !delivered, input.count + bytes.readableBytes <= 32769,
              let value = bytes.readBytes(length: bytes.readableBytes) else { context.close(promise: nil); return }
        input.append(contentsOf: value)
        guard let newline = input.firstIndex(of: 10) else { return }
        guard newline == input.count - 1 else { context.close(promise: nil); return }
        delivered = true
        let request = Data(input.prefix(newline)), channel = context.channel, receive = receive, peerPID = peerPID
        input.removeAll(keepingCapacity: false)
        Task { @MainActor in
            let reply = await receive(peerPID, request)
            channel.eventLoop.execute {
                guard reply.count <= 32768 else { channel.close(promise: nil); return }
                var bytes = channel.allocator.buffer(capacity: reply.count + 1)
                bytes.writeBytes(reply); bytes.writeInteger(UInt8(10))
                channel.writeAndFlush(bytes).whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }
    func channelInactive(context: ChannelHandlerContext) { deadline?.cancel(); deadline = nil; context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

@MainActor final class PiBridgeListener {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var server: Channel?
    private var children: [ObjectIdentifier: Channel] = [:]
    private var path: String?
    private var inode: UInt64?
    private var sweep: Task<Void, Never>?

    func start(path: String, host: PiHostBridge) async throws {
        guard server == nil, path.utf8.count < 104, path.hasPrefix("/"), !path.utf8.contains(0) else { throw PiBridgeFailure.invalidRequest }
        var parent = stat(), existing = stat()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(directory, &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR,
              parent.st_uid == getuid(), (parent.st_mode & 0o077) == 0,
              lstat(path, &existing) != 0, errno == ENOENT else { throw PiBridgeFailure.denied }
        server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .childChannelInitializer { channel in
                let promise = channel.eventLoop.makePromise(of: Void.self)
                Task { @MainActor in
                    guard self.children.count < 64 else { channel.close(promise: nil); promise.fail(PiBridgeFailure.unavailable); return }
                    let id = ObjectIdentifier(channel)
                    self.children[id] = channel
                    channel.closeFuture.whenComplete { _ in Task { @MainActor in self.children[id] = nil } }
                    do {
                        let option = ChannelOptions.Types.SocketOption(level: SocketOptionLevel(SOL_LOCAL), name: SocketOptionName(LOCAL_PEERPID))
                        let peerPID = try await channel.getOption(option).get()
                        guard peerPID > 1 else { throw PiBridgeFailure.identity }
                        try await channel.pipeline.addHandler(PiBridgeChannel(peerPID: peerPID, receive: { pid, data in
                            await host.receive(peerPID: pid, data: data)
                        })).get()
                        promise.succeed(())
                    } catch { channel.close(promise: nil); promise.fail(PiBridgeFailure.denied) }
                }
                return promise.futureResult
            }.bind(unixDomainSocketPath: path).get()
        guard chmod(path, 0o600) == 0, lstat(path, &existing) == 0, (existing.st_mode & S_IFMT) == S_IFSOCK else {
            try? await server?.close().get(); server = nil; throw PiBridgeFailure.unavailable
        }
        self.path = path; inode = UInt64(existing.st_ino)
        sweep = Task { @MainActor in
            while !Task.isCancelled {
                host.sweep()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop(host: PiHostBridge) async -> Bool {
        // Admission stops before socket teardown. Native quarantine is not reset.
        let retired = await host.stop()
        sweep?.cancel(); sweep = nil
        for channel in children.values { try? await channel.close().get() }
        children = [:]
        try? await server?.close().get(); server = nil
        if let path, let inode {
            var info = stat()
            if lstat(path, &info) == 0, UInt64(info.st_ino) == inode, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK {
                _ = unlink(path)
            }
        }
        path = nil; inode = nil
        return retired
    }
    deinit { group.shutdownGracefully { _ in } }
}
#endif
