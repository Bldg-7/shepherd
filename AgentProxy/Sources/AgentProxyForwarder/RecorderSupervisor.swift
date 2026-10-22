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
    private let log: @Sendable (String) -> Void
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

    init(command: [String], loop: EventLoop, tee: Tee, log: @escaping @Sendable (String) -> Void) {
        self.command = command; self.loop = loop; self.tee = tee; self.log = log
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
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(RecorderLinkHandler()) }
            }
            .withConnectedSocket(ours)
            .whenComplete { [self] result in
                switch result {
                case .success(let channel):
                    guard pid == child, !stopped else { channel.close(promise: nil); return }
                    link = channel
                    tee.attach(channel)
                    channel.closeFuture.whenComplete { [self] _ in
                        tee.detach(channel)
                        if link === channel { link = nil }
                        // A recorder that closed its end but lives on is
                        // stopped, so a new one is started.
                        if pid == child { kill(child, SIGKILL) }
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

    /// Stops the recorder and waits (up to two seconds) until it has exited.
    /// Called off the loop.
    func stop() {
        let child: pid_t? = try? loop.submit { [self] () -> pid_t? in
            stopped = true
            restartTask?.cancel()
            if let link { link.close(promise: nil) }
            if let pid { kill(pid, SIGTERM) }
            state = .stopped
            return pid
        }.wait()
        guard child != nil else { return }
        let deadline = Date().addingTimeInterval(2)
        exits.withLock {
            while waiting > 0 && Date() < deadline { _ = exits.wait(until: deadline) }
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

/// The forwarder's end of the socketpair. The recorder sends nothing back in
/// this stage; anything it sends is ignored.
private final class RecorderLinkHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
