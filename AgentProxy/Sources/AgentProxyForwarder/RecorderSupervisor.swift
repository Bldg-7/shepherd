import Foundation
import Darwin
import NIOCore
import NIOPosix
import AgentProxyProtocol

/// Starts the recorder as a child process with one end of a socketpair as its
/// descriptor 3, gives the other end to the `Tee`, and starts it again when it
/// exits: a quarter of a second later the first time, twice as long each time
/// it exits again soon (up to 30 seconds), and a quarter of a second again
/// once one has run for 30 seconds. The child gets no other descriptor of the
/// forwarder's and no environment.
///
/// Used on the proxy's event loop, except `stop`.
final class RecorderSupervisor: @unchecked Sendable {
    static let firstDelay: TimeAmount = .milliseconds(250)
    static let longestDelay: TimeAmount = .seconds(30)
    static let settled: TimeInterval = 30

    private let command: [String]
    private let loop: EventLoop
    private let tee: Tee
    private let routes: RouteTable
    private let log: @Sendable (String) -> Void
    private var authorityGeneration: UInt64 = 0
    private var acknowledgedGeneration: UInt64 = 0
    private var acknowledgements: [UInt64: EventLoopPromise<Void>] = [:]
    private var pid: pid_t?
    private var link: Channel?
    private var delay = RecorderSupervisor.firstDelay
    private var startedAt = Date()
    private var restartTask: Scheduled<Void>?
    private(set) var restarts = 0
    private(set) var state: AgentProxyStatus.Recorder.State = .stopped
    private var stopped = false
    private let exits = NSCondition()
    private var waiting = 0

    init(command: [String], loop: EventLoop, tee: Tee, routes: RouteTable, log: @escaping @Sendable (String) -> Void) {
        self.command = command; self.loop = loop; self.tee = tee; self.routes = routes; self.log = log
    }

    /// A snapshot and all subsequent tee frames share the same ordered stream.
    /// If it cannot be sent, close the link rather than retain stale authority.
    func authorityChanged() {
        loop.assertInEventLoop()
        guard let link else { return }
        guard sendAuthority(on: link) else { link.close(promise: nil); return }
    }

    private struct AuthorityUnavailable: Error {}

    /// Fails rather than reporting a synchronized mutation when the child is
    /// absent, the link is desynchronized, or its acknowledgement times out.
    func waitForAuthority() -> EventLoopFuture<Void> {
        loop.assertInEventLoop()
        guard let link, link.isActive else { return loop.makeFailedFuture(AuthorityUnavailable()) }
        if acknowledgedGeneration == authorityGeneration { return loop.makeSucceededFuture(()) }
        guard let pending = acknowledgements[authorityGeneration] else { return loop.makeFailedFuture(AuthorityUnavailable()) }
        return pending.futureResult
    }

    private func sendAuthority(on channel: Channel) -> Bool {
        guard channel.isActive, channel.isWritable, authorityGeneration < UInt64.max,
              acknowledgements.count < 128 else { return false }
        authorityGeneration += 1
        let generation = authorityGeneration
        let snapshot = AgentProxyTeeFrame.RouteSnapshot(generation: generation, routes: routes.recorderAuthority())
        guard let payload = try? JSONEncoder().encode(snapshot), payload.count <= AgentProxyTeeFrame.maximumPayloadBytes else { return false }
        let promise = loop.makePromise(of: Void.self)
        acknowledgements[generation] = promise
        let timeout = loop.scheduleTask(in: .seconds(2)) { [weak self, weak channel] in
            guard let self, let channel, self.link === channel, self.acknowledgements[generation] != nil else { return }
            channel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in timeout.cancel() }
        let header = AgentProxyTeeFrame.header(kind: .routeSnapshot, exchange: 0, payloadCount: payload.count)
        channel.write(ByteBuffer(bytes: header), promise: nil)
        channel.writeAndFlush(ByteBuffer(bytes: payload)).whenFailure { _ in channel.close(promise: nil) }
        return true
    }

    private func received(_ frame: AgentProxyTeeFrame.Frame, on channel: Channel) -> Bool {
        guard link === channel, frame.kind == .routeAcknowledgement, frame.payload.isEmpty,
              let first = acknowledgements.keys.min(), frame.exchange == first,
              let promise = acknowledgements.removeValue(forKey: first) else { return false }
        acknowledgedGeneration = first
        promise.succeed(())
        return true
    }

    private func failAcknowledgements() {
        let pending = acknowledgements.values
        acknowledgements.removeAll()
        for promise in pending { promise.fail(AuthorityUnavailable()) }
    }

    var currentPID: pid_t? { pid }

    func start() {
        loop.assertInEventLoop()
        spawn()
    }

    private func spawn() {
        guard !stopped else { return }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { scheduleRestart(); return }
        let (ours, theirs) = (pair[0], pair[1])
        _ = fcntl(ours, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(ours, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 1 << 20
        _ = setsockopt(ours, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_adddup2(&actions, theirs, 3)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let arguments = command.map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { arguments.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, command[0], &actions, &attributes, arguments, environment)
        close(theirs)
        guard result == 0 else {
            close(ours)
            log("recorder: could not be started (errno \(result))")
            scheduleRestart()
            return
        }
        pid = child
        startedAt = Date()
        state = .running
        waitForExit(child)
        ClientBootstrap(group: loop)
            .channelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 1 << 20, high: 4 << 20))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RecorderLinkHandler { [weak self] frame, channel in
                        self?.received(frame, on: channel) ?? false
                    })
                }
            }
            .withConnectedSocket(ours)
            .whenComplete { [self] result in
                switch result {
                case .success(let channel):
                    guard pid == child, !stopped else { channel.close(promise: nil); return }
                    link = channel
                    guard sendAuthority(on: channel) else {
                        link = nil; failAcknowledgements(); channel.close(promise: nil)
                        if pid == child { kill(child, SIGKILL) }
                        return
                    }
                    tee.attach(channel)
                    channel.closeFuture.whenComplete { [self] _ in
                        tee.detach(channel)
                        if link === channel { link = nil; failAcknowledgements() }
                        // During shutdown the child may close the link while
                        // completing its bounded flush.
                        if pid == child && !stopped { kill(child, SIGKILL) }
                    }
                case .failure:
                    if pid == child { kill(child, SIGKILL) }
                }
            }
    }

    /// Waits on a thread of its own for the child to exit, without reaping
    /// it: it is reaped on the loop, so a signal sent from the loop never
    /// reaches a process that took its number.
    private func waitForExit(_ child: pid_t) {
        exits.withLock { waiting += 1 }
        let thread = Thread { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
            loop.execute { self.exited(child) }
        }
        thread.name = "agent-proxy recorder wait"
        thread.start()
    }

    private func exited(_ child: pid_t) {
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        exits.withLock { waiting -= 1; exits.broadcast() }
        guard pid == child else { return }
        pid = nil
        if let link { tee.detach(link); link.close(promise: nil) }
        link = nil
        failAcknowledgements()
        guard !stopped else { state = .stopped; return }
        restarts += 1
        log("recorder: exited; starting it again")
        if Date().timeIntervalSince(startedAt) >= Self.settled { delay = Self.firstDelay }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped else { return }
        state = .restarting
        let wait = delay
        delay = .nanoseconds(min(delay.nanoseconds * 2, Self.longestDelay.nanoseconds))
        restartTask = loop.scheduleTask(in: wait) { [self] in spawn() }
    }

    /// Allows two seconds for EOF/flush, then uses bounded signal fallbacks.
    /// Called off the loop.
    func stop() {
        let child: pid_t? = try? loop.submit { [self] () -> pid_t? in
            stopped = true
            restartTask?.cancel()
            // EOF lets the child flush without blocking the forwarding loop.
            if let link { link.close(mode: .output, promise: nil) }
            state = .stopped
            return pid
        }.wait()
        guard child != nil else { return }
        let deadline = Date().addingTimeInterval(2)
        exits.withLock {
            while waiting > 0 && Date() < deadline { _ = exits.wait(until: deadline) }
        }
        if let child, exits.withLock({ waiting > 0 }) {
            try? loop.submit { [self] in if pid == child { kill(child, SIGTERM) } }.wait()
            exits.withLock {
                let deadline = Date().addingTimeInterval(1)
                while waiting > 0 && Date() < deadline { _ = exits.wait(until: deadline) }
            }
        }
        if let child, exits.withLock({ waiting > 0 }) {
            try? loop.submit { [self] in if pid == child { kill(child, SIGKILL) } }.wait()
            exits.withLock {
                let deadline = Date().addingTimeInterval(1)
                while waiting > 0 && Date() < deadline { _ = exits.wait(until: deadline) }
            }
        }
    }
}

/// Only ordered, generation-correlated ACK frames are accepted from the child.
private final class RecorderLinkHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var decoder = AgentProxyTeeFrame.Decoder()
    private let accept: (AgentProxyTeeFrame.Frame, Channel) -> Bool
    init(accept: @escaping (AgentProxyTeeFrame.Frame, Channel) -> Bool) { self.accept = accept }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        decoder.append(unwrapInboundIn(data).readableBytesView)
        do {
            while let frame = try decoder.next() {
                guard accept(frame, context.channel) else { context.close(promise: nil); return }
            }
        } catch { context.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
