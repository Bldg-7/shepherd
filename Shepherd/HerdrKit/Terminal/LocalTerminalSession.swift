import Foundation
import NIOCore

// SwiftTerm's `LocalProcess` (forkpty-based) is only compiled for
// `!os(iOS) && !os(Windows)`, which in this app's target set means macOS.
#if os(macOS)
import SwiftTerm

/// Attaches to a herdr pane's live terminal the same way `TerminalSession`
/// does (`herdr terminal attach <terminal> --takeover`, under a real PTY),
/// but as a local subprocess instead of over SSH — for when the pane lives
/// on this same Mac. One `LocalTerminalSession` is one `LocalProcess` — not
/// pooled or reused across panes.
actor LocalTerminalSession: TerminalSessionProviding {
    /// The pane's terminal (see `AgentSummary.terminalID`).
    private let terminalID: String
    /// The herdr machine the pane is on, or nil for this Mac's own herdr.
    private let herdrMachine: HerdrMachine?
    /// Both this actor's executor and the queue `LocalProcess` delivers its
    /// delegate callbacks on, so the two are one serial context.
    ///
    /// `LocalProcess` has no synchronisation of its own, and it reports the
    /// child's exit from its delegate queue in the same breath as it reaps
    /// it. `stop()` has to know about that reaping before it signals the
    /// pid, and a report that still had to hop over to this actor could
    /// arrive after `stop()` had already gone ahead. Sharing the queue
    /// leaves no gap: `stop()` runs either wholly before the exit is
    /// handled, or wholly after it has been recorded.
    private let queue = DispatchSerialQueue(label: "LocalTerminalSession")
    private var process: LocalProcess?
    private var delegateBridge: DelegateBridge?
    private var outputContinuation: AsyncStream<ByteBuffer>.Continuation?
    /// Set by `stop()` and never cleared. `start()` has no suspension point,
    /// so `stop()` can't land in the middle of it — but it can land before
    /// it (the two are sent from the main actor as separate hops onto this
    /// one, with no ordering promise), when there is no process yet to
    /// terminate. Without this, that `stop()` would do nothing and the
    /// `start()` behind it would spawn an attach nobody is left to end.
    private var stopRequested = false

    init(terminalID: String, on herdrMachine: HerdrMachine? = nil) {
        self.terminalID = terminalID
        self.herdrMachine = herdrMachine
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer> {
        guard process == nil else { throw TerminalSessionError.alreadyStarted }
        guard !stopRequested else { throw CancellationError() }

        var continuation: AsyncStream<ByteBuffer>.Continuation!
        let stream = AsyncStream<ByteBuffer> { continuation = $0 }
        self.outputContinuation = continuation

        let bridge = DelegateBridge(
            initialSize: winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0),
            output: continuation
        )
        self.delegateBridge = bridge

        let process = LocalProcess(delegate: bridge, dispatchQueue: queue)
        self.process = process

        // herdr is started directly where it is normally installed, and only
        // looked up through an interactive zsh otherwise (see
        // `HerdrExecutable`). Started directly, the arguments go straight to
        // execvp with no shell to quote for; the fallback's `-c` string is
        // parsed by that one zsh, so they are quoted for it.
        //
        // SwiftTerm forks right here, on this actor's dispatch thread, and
        // the child keeps that thread's signal mask through exec. Dispatch
        // threads block SIGHUP and SIGTERM, so a herdr started directly would
        // ignore the hangup `stop()` sends and only go at its SIGKILL
        // backstop two seconds later (an interactive zsh happened to clear
        // the mask, which is why this never showed while every attach went
        // through one). The mask is opened for the fork alone.
        var hangupSignals = sigset_t()
        sigemptyset(&hangupSignals)
        for signal in [SIGHUP, SIGTERM, SIGINT] {
            sigaddset(&hangupSignals, signal)
        }
        var previousMask = sigset_t()
        pthread_sigmask(SIG_UNBLOCK, &hangupSignals, &previousMask)
        if let herdrMachine {
            // A pane on one of this Mac's herdr machines is attached to over
            // this Mac's own `ssh`, the one herdr uses to reach that machine
            // (looked up on PATH, as herdr does). SwiftTerm's default
            // environment for a child has the terminal basics and who the
            // user is, but no PATH — `env` would then look only in
            // /usr/bin:/bin — and no SSH_AUTH_SOCK, without which ssh can't
            // use the agent holding the keys herdr's own requests go out
            // with. Both are passed on from the app's environment.
            var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            let inherited = ProcessInfo.processInfo.environment
            for name in ["PATH", "SSH_AUTH_SOCK"] {
                if let value = inherited[name] {
                    environment.append("\(name)=\(value)")
                }
            }
            process.startProcess(
                executable: "/usr/bin/env",
                args: ["ssh"] + HerdrExecutable.sshAttachArguments(to: herdrMachine, terminalID: terminalID),
                environment: environment
            )
        } else if let herdr = HerdrExecutable.localPath() {
            process.startProcess(executable: herdr, args: HerdrExecutable.attachArguments(terminalID: terminalID))
        } else {
            let attach = (["herdr"] + HerdrExecutable.attachArguments(terminalID: terminalID).map(shellQuoted)).joined(separator: " ")
            process.startProcess(executable: "/bin/zsh", args: ["-ic", attach])
        }
        pthread_sigmask(SIG_SETMASK, &previousMask, nil)

        return stream
    }

    func write(_ data: Data) async throws {
        guard let process else { throw TerminalSessionError.notStarted }
        process.send(data: Array(data)[...])
    }

    func resize(columns: Int, rows: Int) async throws {
        guard let process, process.childfd >= 0 else { throw TerminalSessionError.notStarted }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func stop() async {
        stopRequested = true
        // A child that ended by itself has already been reaped by
        // `LocalProcess`, so its pid may by now belong to some unrelated
        // process — and the hangup and `terminate()` both signal the pid
        // unconditionally. Letting go of the `LocalProcess` is all that's
        // left to do for it.
        if let process, let delegateBridge, !delegateBridge.processHasExited {
            let pid = process.shellPid
            Self.hangUp(pid)
            process.terminate()
            Self.reapWhenExited(pid)
        }
        process = nil
        delegateBridge = nil
        outputContinuation?.finish()
        outputContinuation = nil
    }

    /// Sends the child the hangup it would get if its terminal were closed.
    ///
    /// `terminate()` doesn't amount to one. Its SIGTERM goes to the child's
    /// pid alone, and that pid is an interactive zsh — which ignores
    /// SIGTERM — for as long as the rc files are loading, and for the whole
    /// attach wherever they leave the shell something to do on exit (a
    /// trap, an exit hook): it then runs the command as a child of its own
    /// instead of exec'ing it. Nor does `terminate()` close the PTY, which
    /// is what would make the kernel hang up: the read `LocalProcess` has
    /// in flight keeps the master open until the child is gone.
    ///
    /// The child is the session leader of its terminal (`forkpty` makes it
    /// one), which is who the kernel's own hangup goes to. A shell exits on
    /// it and hangs up the job it was running, and once the session leader
    /// is gone the kernel hangs up the terminal's foreground group as well.
    private static func hangUp(_ pid: pid_t) {
        // 0 is what `LocalProcess` reports when the fork itself failed, and
        // to `kill` it would mean every process in this app's own group.
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
    }

    /// Where every stopped child is waited for and, if it comes to that,
    /// killed. One serial queue for both, so that a pid is never signalled
    /// once it has been reaped — see `reapWhenExited`.
    private static let reaperQueue = DispatchQueue(label: "LocalTerminalSession.reaper", qos: .utility)
    /// How long a stopped child gets to act on the hangup before it is
    /// killed outright.
    private static let killDelay: DispatchTimeInterval = .seconds(2)

    /// Collects the exit status of a child that `stop()` has just
    /// signalled. `terminate()` also cancels the exit monitor through which
    /// `LocalProcess` would otherwise have reaped the child, so from here on
    /// nobody else will — and an unreaped child stays behind as a zombie
    /// until the app quits, one per attach.
    ///
    /// Waits for the exit with a dispatch source of its own, off this
    /// actor and off the main queue, rather than by parking a thread in
    /// `waitpid` from the start: a child is free to take its time over
    /// the signals. The source is held by its own handler, which keeps it
    /// armed for exactly as long as the child lives.
    ///
    /// That is `killDelay` at the most: a child still there by then is
    /// killed. The hangup can miss — a zsh that takes it at the moment it
    /// is replacing itself with the command goes through with the exec, and
    /// the command starts out never having been signalled — and a program
    /// is free to ignore it. When it is the shell that gets killed, the
    /// kernel hangs up the foreground group after it, as in `hangUp`.
    private static func reapWhenExited(_ pid: pid_t) {
        // 0 is what `LocalProcess` reports when the fork itself failed, and
        // to `waitpid` it would mean "any child in this process group".
        guard pid > 0 else { return }
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: reaperQueue)
        exitSource.setEventHandler {
            // Blocking rather than WNOHANG: should the event get here
            // before the child is quite waitable, a non-blocking call would
            // come back empty and never be repeated. Now that the child has
            // exited, the wait is over at once either way.
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            exitSource.cancel()
        }
        exitSource.activate()
        reaperQueue.asyncAfter(deadline: .now() + killDelay) {
            // The handler above cancels the source in the same block it
            // reaps the child in, and that block and this one take turns
            // on the queue: a source not yet cancelled means a child not
            // yet reaped, so the pid is still its own.
            if !exitSource.isCancelled {
                kill(pid, SIGKILL)
            }
        }
    }

    /// `LocalProcessDelegate` callbacks arrive synchronously on the queue
    /// `LocalProcess` was given — the one this actor runs on — which is what
    /// makes it safe for the actor to read `processHasExited` directly.
    ///
    /// Output goes straight from the callback into the stream. The callbacks
    /// come one at a time, in the order the bytes were read, and that order
    /// is the terminal's: forwarding each chunk through a task of its own
    /// would hand the ordering to the scheduler instead.
    private nonisolated final class DelegateBridge: LocalProcessDelegate {
        private let initialSize: winsize
        private let output: AsyncStream<ByteBuffer>.Continuation
        /// Set once `LocalProcess` has seen the child exit, which is also
        /// when it reaps it.
        private(set) var processHasExited = false

        init(initialSize: winsize, output: AsyncStream<ByteBuffer>.Continuation) {
            self.initialSize = initialSize
            self.output = output
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            var buffer = ByteBuffer()
            buffer.writeBytes(slice)
            output.yield(buffer)
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            processHasExited = true
            output.finish()
        }

        func getWindowSize() -> winsize {
            initialSize
        }
    }
}
#endif
