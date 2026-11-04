#if canImport(NIOSSH) && canImport(Crypto) && canImport(Citadel)
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

public nonisolated enum CoreSSHFailure: Error, Equatable, Sendable {
    case invalidConfiguration, closed, authenticationFailed, hostKeyMismatch, execRejected, timedOut
    case concurrentRead, bufferExceeded, writeLimitExceeded
    case hostKeyApprovalRequired(String)
}

/// Real SSH session/exec transport (never a PTY). The caller supplies an
/// approved host-key pin and fresh authentication factory. Paired-address
/// policy/DNS binding must be resolved by the machine factory before this
/// low-level endpoint is constructed; it never loads saved credentials itself.
public actor CoreSSHTransport: CoreByteTransport {
    public nonisolated struct Configuration: Sendable {
        public let host: String
        public let port: Int
        public let pinnedFingerprint: String?
        public let command: String
        public init(host: String, port: Int = 22, pinnedFingerprint: String? = nil, requestHostKeyApproval: Bool = false,
                    executable: String = "hc", discoverExecutable: Bool = false,
                    session: String = "default", environment: [String: String] = [:]) throws {
            guard !host.isEmpty, (1...65535).contains(port),
                  pinnedFingerprint.map({ $0.hasPrefix("SHA256:") && $0.utf8.count <= 128 && !requestHostKeyApproval }) ?? requestHostKeyApproval,
                  !executable.isEmpty, (!discoverExecutable || environment.isEmpty),
                  (1...64).contains(session.utf8.count), session.utf8.allSatisfy({
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
                  }), session != ".", session != "..",
                  !([host, executable, pinnedFingerprint ?? ""] + environment.flatMap { [$0.key,$0.value] }).contains(where: { $0.utf8.contains(0) }),
                  environment.keys.allSatisfy({ $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }) else {
                throw CoreSSHFailure.invalidConfiguration
            }
            self.host = host; self.port = port; self.pinnedFingerprint = pinnedFingerprint
            var env = environment; env["HC_SESSION"] = session
            // A login shell may itself have been started inside a core terminal.
            let clear = ["HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE", "HC_SOCKET"].map { "-u " + shellQuoted($0) }
            let assignments = env.keys.sorted().map { shellQuoted($0 + "=" + env[$0]!) }
            command = try discoverExecutable ? HcConnectionPolicy.remoteCommand(session: session) :
                (["exec env"] + clear + assignments + [shellQuoted(executable), "connect"]).joined(separator: " ")
        }
    }
    private let config: Configuration
    private let authentication: @Sendable () -> any NIOSSHClientUserAuthenticationDelegate
    private let group: any EventLoopGroup
    private let lifetime = CoreSSHLifetime()
    private let buffer = CoreSSHBuffer()
    private var started = false
    private var stopped = false
    private var channel: (any Channel)?
    private var cleanup: Task<Void, Error>?
    private var writeBytes = 0
    private var writeCount = 0

    public init(configuration: Configuration,
                authentication: @escaping @Sendable () -> any NIOSSHClientUserAuthenticationDelegate,
                group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        config = configuration; self.authentication = authentication; self.group = group
    }
    deinit { lifetime.stop(); buffer.finish(CoreSSHFailure.closed) }

    public func start() async throws {
        try Task.checkCancellation()
        guard !started, !stopped else { throw CoreSSHFailure.closed }
        started = true
        let loop = group.next(), config = config, authFactory = authentication, life = lifetime, buffer = buffer
        let ready = CoreSSHReady(loop), authenticated = CoreSSHReady(loop), executed = CoreSSHReady(loop)
        life.register(ready); life.register(authenticated); life.register(executed)
        let deadline = loop.scheduleTask(in: .seconds(10)) {
            ready.finish(.failure(CoreSSHFailure.timedOut)); life.stop(); buffer.finish(CoreSSHFailure.timedOut)
        }
        let bootstrap = ClientBootstrap(group: loop).connectTimeout(.seconds(10)).channelInitializer { parent in
            guard life.install(parent) else { return parent.eventLoop.makeFailedFuture(CoreSSHFailure.closed) }
            do {
                try parent.pipeline.syncOperations.addHandlers([
                    NIOSSHHandler(role: .client(SSHClientConfiguration(userAuthDelegate: authFactory(),
                        serverAuthDelegate: CoreSSHHostPin(config.pinnedFingerprint))), allocator: parent.allocator,
                        inboundChildChannelInitializer: { child, _ in child.eventLoop.makeFailedFuture(CoreSSHFailure.execRejected) }),
                    CoreSSHAuthHandler(authenticated)
                ])
                return parent.eventLoop.makeSucceededFuture(())
            } catch { return parent.eventLoop.makeFailedFuture(error) }
        }
        bootstrap.connect(host: config.host, port: config.port).flatMap { parent in
            authenticated.promise.futureResult.flatMap {
                let promise = parent.eventLoop.makePromise(of: (any Channel).self)
                do {
                    let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    handler.createChannel(promise, channelType: .session) { child, type in
                        guard case .session = type, life.install(child) else { return child.eventLoop.makeFailedFuture(CoreSSHFailure.closed) }
                        buffer.install(child)
                        return child.setOption(ChannelOptions.autoRead, value: false).flatMap {
                            child.pipeline.addHandler(CoreSSHExecHandler(buffer: buffer, ready: executed))
                        }
                    }
                } catch { promise.fail(error) }
                return promise.futureResult
            }
        }.flatMap { child in
            let sent = child.eventLoop.makePromise(of: Void.self)
            child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: config.command, wantReply: true), promise: sent)
            // Read authentication/exec success even before the first read().
            child.read()
            return sent.futureResult.flatMap { executed.promise.futureResult }
        }.whenComplete { result in
            deadline.cancel()
            switch result {
            case .success: ready.finish(.success(()))
            case .failure(let error):
                let safe = error as? CoreSSHFailure ?? .authenticationFailed
                ready.finish(.failure(safe)); buffer.finish(safe); life.stop()
            }
        }
        do {
            try await withTaskCancellationHandler { try await ready.promise.futureResult.get() }
                onCancel: { life.stop(); buffer.finish(CancellationError()) }
            guard !stopped, !Task.isCancelled, let child = lifetime.session else { throw CoreSSHFailure.closed }
            channel = child
        } catch { try await close(); throw error }
    }
    public func read() async throws -> Data? {
        guard started, !stopped else { throw CoreSSHFailure.closed }
        let buffer = buffer, life = lifetime
        return try await withTaskCancellationHandler { try Task.checkCancellation(); return try await buffer.read() }
            onCancel: { life.stop(); buffer.finish(CancellationError()) }
    }
    public func write(_ bytes: Data) async throws {
        try Task.checkCancellation()
        guard !stopped, let channel else { throw CoreSSHFailure.closed }
        guard writeCount < 64, bytes.count <= (2 << 20) - writeBytes else { throw CoreSSHFailure.writeLimitExceeded }
        writeCount += 1; writeBytes += bytes.count
        defer { writeCount -= 1; writeBytes -= bytes.count }
        let life = lifetime, buffer = buffer
        try await withTaskCancellationHandler {
            try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))).get()
        } onCancel: { life.stop(); buffer.finish(CancellationError()) }
    }
    public func close() async throws {
        if let cleanup { try await cleanup.value; return }
        stopped = true; channel = nil; buffer.finish(CoreSSHFailure.closed)
        let channels = lifetime.stop()
        let task = Task<Void, Error> {
            for channel in channels {
                do { try await channel.closeFuture.get() }
                catch {
                    // A failed, inactive session (e.g. tcpShutdown while exec
                    // was pending) is retired; preserve the original error.
                    if channel.isActive { throw CoreSSHFailure.closed }
                }
            }
        }
        cleanup = task
        try await task.value
    }
}

/// Exactly-once completion shared by NIO callbacks, deadline and cancellation.
private nonisolated final class CoreSSHReady: @unchecked Sendable {
    let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var done = false
    init(_ loop: any EventLoop) { promise = loop.makePromise() }
    func finish(_ result: Result<Void, any Error>) {
        lock.lock(); let finish = !done; done = true; lock.unlock()
        if finish { promise.completeWith(result) }
    }
}
/// Install guards run in channel initializers BEFORE connect/exec is allowed.
/// Late DNS/session completions after close cannot resurrect authority.
private nonisolated final class CoreSSHLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var channels: [any Channel] = []
    private var readiness: [CoreSSHReady] = []
    var session: (any Channel)? { lock.lock(); defer { lock.unlock() }; return stopped ? nil : channels.last }
    func register(_ ready: CoreSSHReady) {
        lock.lock(); let reject = stopped; if !reject { readiness.append(ready) }; lock.unlock()
        if reject { ready.finish(.failure(CoreSSHFailure.closed)) }
    }
    func install(_ channel: any Channel) -> Bool {
        lock.lock(); let accept = !stopped; if accept { channels.append(channel) }; lock.unlock()
        if !accept { channel.close(promise: nil) }; return accept
    }
    @discardableResult func stop() -> [any Channel] {
        lock.lock(); let first = !stopped; stopped = true
        let channels = channels, ready = readiness; readiness.removeAll(); lock.unlock()
        if first {
            for item in ready { item.finish(.failure(CoreSSHFailure.closed)) }
            for channel in channels { channel.close(promise: nil) }
        }
        return channels
    }
}
private nonisolated struct CoreSSHHostPin: NIOSSHClientServerAuthenticationDelegate {
    let pin: String?
    init(_ pin: String?) { self.pin = pin }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let pin else {
            validationCompletePromise.fail(CoreSSHFailure.hostKeyApprovalRequired(HostKeyFingerprint.compute(hostKey)))
            return
        }
        if HostKeyFingerprint.compute(hostKey) == pin { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(CoreSSHFailure.hostKeyMismatch) }
    }
}
/// Handlers are confined to the channel event loop; shared buffer has its own lock.
private nonisolated final class CoreSSHAuthHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let ready: CoreSSHReady
    init(_ ready: CoreSSHReady) { self.ready = ready }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { ready.finish(.success(())) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        ready.finish(.failure(error as? CoreSSHFailure ?? .authenticationFailed)); context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) { ready.finish(.failure(CoreSSHFailure.closed)); context.fireChannelInactive() }
}
private nonisolated final class CoreSSHExecHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let buffer: CoreSSHBuffer
    let ready: CoreSSHReady
    init(buffer: CoreSSHBuffer, ready: CoreSSHReady) { self.buffer = buffer; self.ready = ready }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent { ready.finish(.success(())) }
        else if event is ChannelFailureEvent { ready.finish(.failure(CoreSSHFailure.execRejected)); buffer.finish(CoreSSHFailure.execRejected); context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { buffer.finish(CoreSSHFailure.bufferExceeded); context.close(promise: nil); return }
        if message.type == .channel, !buffer.offer(Data(bytes.readableBytesView)) { context.close(promise: nil) }
        // stderr is intentionally discarded, never appended to protocol/stdout.
    }
    func channelReadComplete(context: ChannelHandlerContext) { buffer.requestReadIfNeeded() }
    func channelInactive(context: ChannelHandlerContext) {
        ready.finish(.failure(CoreSSHFailure.closed)); buffer.finish(nil); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { ready.finish(.failure(CoreSSHFailure.closed)); buffer.finish(CoreSSHFailure.closed); context.close(promise: nil) }
}
/// Admission is synchronous on the SSH event loop, not through an unbounded
/// AsyncStream/Task queue. autoRead=false applies SSH-window backpressure.
private nonisolated final class CoreSSHBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: (any Channel)?
    private var queue: [Data] = []
    private var count = 0
    private var ended = false
    private var error: (any Error)?
    private var waiter: CheckedContinuation<Data?, Error>?
    func install(_ channel: any Channel) { lock.lock(); self.channel = channel; lock.unlock() }
    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let error { lock.unlock(); c.resume(throwing: error) }
            else if !queue.isEmpty { let data = queue.removeFirst(); count -= data.count; lock.unlock(); c.resume(returning: data) }
            else if ended { lock.unlock(); c.resume(returning: nil) }
            else if waiter != nil { lock.unlock(); c.resume(throwing: CoreSSHFailure.concurrentRead) }
            else { waiter = c; lock.unlock(); requestReadIfNeeded() }
        }
    }
    func offer(_ data: Data) -> Bool {
        lock.lock()
        guard !ended else { lock.unlock(); return false }
        guard data.count <= 256 << 10, queue.count < 1024, data.count <= (4 << 20) - count else {
            lock.unlock(); finish(CoreSSHFailure.bufferExceeded); return false
        }
        if let waiting = waiter { waiter = nil; lock.unlock(); waiting.resume(returning: data) }
        else { queue.append(data); count += data.count; lock.unlock() }
        return true
    }
    func requestReadIfNeeded() {
        lock.lock(); let next = !ended && waiter != nil && queue.isEmpty ? channel : nil; lock.unlock()
        next?.read()
    }
    func finish(_ error: (any Error)?) {
        lock.lock()
        if ended {
            if let error { self.error = error; queue.removeAll(); count = 0 }
            channel = nil; lock.unlock(); return
        }
        ended = true; self.error = error; channel = nil
        if error != nil { queue.removeAll(); count = 0 }
        let pending = waiter; waiter = nil; lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume(returning: nil) }
    }
}
#endif
