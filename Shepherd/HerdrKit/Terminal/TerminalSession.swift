import Foundation

// Needs our patched local Citadel (see Vendor/) — upstream's withPTY can only
// run a bare shell, with no way to pair a PTY with a specific command, so we
// extended it (added an optional `command:` parameter + a ptyCommand mode).
// Guarded with `canImport` so the rest of the app keeps building before
// that's wired up.
#if canImport(Citadel)
import Citadel
import NIOCore
import NIOFoundationCompat
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

enum TerminalSessionError: Error, LocalizedError {
    case notStarted
    case alreadyStarted

    var errorDescription: String? {
        switch self {
        case .notStarted: String(localized: "Terminal session hasn't started yet")
        case .alreadyStarted: String(localized: "Terminal session was already started")
        }
    }
}

/// Attaches to a herdr pane's live terminal via `herdr terminal attach
/// <terminal> --takeover`, run with a real PTY — `attach` is a full-screen
/// program, and running it through a plain (non-PTY) exec would break its
/// rendering (no raw mode, cursor queries, etc.). This is a genuinely
/// different use case from `SSHHerdrTransport`'s one-shot JSON requests: a
/// terminal session is meant to stay open and interactive for as long as
/// the UI has it on screen.
///
/// One `TerminalSession` is one SSH connection + one PTY channel — not
/// pooled or reused across panes. Create a fresh one per attach.
actor TerminalSession: TerminalSessionProviding {
    private let host: String
    private let port: Int
    private let username: String
    private let credential: HostCredential
    /// Empty means herdr's own "default" session.
    private let sessionName: String
    private let pinnedFingerprint: String?
    /// The pane's terminal (see `AgentSummary.terminalID`).
    private let terminalID: String
    /// The herdr machine the pane is on, or nil for the host's own herdr.
    private let herdrMachine: HerdrMachine?

    private var client: SSHClient?
    private var outbound: TTYStdinWriter?
    private var sessionTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var outputContinuation: AsyncStream<ByteBuffer>.Continuation?
    private var hasStarted = false
    /// Set by `stop()` and never cleared. `start()` spends most of its time
    /// suspended (connecting, then waiting for the PTY), and this actor is
    /// free to run `stop()` during every one of those suspensions — at
    /// which point there may be no `client` or `sessionTask` yet for it to
    /// act on. The flag is what lets `start()` find out, when it resumes,
    /// that it should unwind instead of going on to attach.
    private var stopRequested = false

    init(host: String, port: Int, username: String, credential: HostCredential, sessionName: String = "", pinnedFingerprint: String?, terminalID: String, on herdrMachine: HerdrMachine? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.credential = credential
        self.sessionName = sessionName
        self.pinnedFingerprint = pinnedFingerprint
        self.terminalID = terminalID
        self.herdrMachine = herdrMachine
    }

    /// Connects, attaches to the pane, and returns the live output stream
    /// (raw bytes — ANSI/escape sequences included, for a terminal emulator
    /// like SwiftTerm to render). Call `write`/`resize` afterward to
    /// interact with the session; call `stop` when the UI is done with it.
    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer> {
        // A flag rather than `sessionTask == nil`: that stays nil for the
        // whole connect, so it wouldn't catch a second call arriving then.
        guard !hasStarted else { throw TerminalSessionError.alreadyStarted }
        hasStarted = true
        try throwIfStopRequested()

        let authMethod = try credential.authenticationMethod(username: username)
        let observedFingerprint = NIOLockedValueBox<String?>(nil)
        let validator = TOFUHostKeyValidator(pinnedFingerprint: pinnedFingerprint, observedFingerprint: observedFingerprint)
        let settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { authMethod },
            hostKeyValidator: .custom(validator)
        )
        let client = try await SSHClient.connect(to: settings)
        // `stop()` had no connection to close while this was still being
        // made, so closing it falls to us — before it is stored, and before
        // anything is run over it.
        guard !stopRequested else {
            try? await client.close()
            throw CancellationError()
        }
        self.client = client

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        // The exec string goes through more than one shell before herdr
        // sees its arguments (see `HerdrExecutable.remoteCommand`), so each
        // dynamic argument is quoted here, for the shell that finally runs
        // herdr, and the layers above add their own. Quoting only for the
        // outermost shell would hand the inner one the session name and
        // terminal ID bare: a space would split the argument, and `;` or
        // `$(…)` would run as code.
        var arguments: [String] = []
        if !sessionName.isEmpty {
            arguments += ["--session", shellQuoted(sessionName)]
        }
        arguments += HerdrExecutable.attachArguments(terminalID: terminalID).map(shellQuoted)
        let command: String
        if let herdrMachine {
            // A pane on one of the host's herdr machines: the host's own
            // `ssh` carries the attach on, as it carries herdr's requests to
            // that machine. `sessionName` is this connection's session on
            // the host, not the machine's — `sshAttachArguments` uses the
            // machine's own.
            command = (["ssh"] + HerdrExecutable.sshAttachArguments(to: herdrMachine, terminalID: terminalID))
                .map(shellQuoted)
                .joined(separator: " ")
        } else {
            command = HerdrExecutable.remoteCommand(arguments: arguments.joined(separator: " "))
        }

        var outputContinuation: AsyncStream<ByteBuffer>.Continuation!
        let outputStream = AsyncStream<ByteBuffer> { outputContinuation = $0 }
        self.outputContinuation = outputContinuation

        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            self.readyContinuation = ready
            self.sessionTask = Task {
                do {
                    try await client.withPTY(ptyRequest, command: command) { inbound, outbound in
                        self.sessionReady(outbound: outbound)
                        for try await event in inbound {
                            if case .stdout(let buffer) = event {
                                self.yield(buffer)
                            }
                        }
                    }
                    await self.shutDown(error: nil)
                } catch {
                    await self.shutDown(error: error)
                }
            }
        }
        // Being resumed and actually running again are two separate turns
        // on this actor; `stop()` can take the one in between.
        try throwIfStopRequested()

        return outputStream
    }

    func write(_ data: Data) async throws {
        guard let outbound else { throw TerminalSessionError.notStarted }
        try await outbound.write(ByteBuffer(data: data))
    }

    func resize(columns: Int, rows: Int) async throws {
        guard let outbound else { throw TerminalSessionError.notStarted }
        try await outbound.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func stop() async {
        stopRequested = true
        sessionTask?.cancel()
        sessionTask = nil
        await shutDown(error: CancellationError())
    }

    private func throwIfStopRequested() throws {
        if stopRequested { throw CancellationError() }
    }

    /// The one place a session ends, whether because `stop()` was called or
    /// because the PTY task finished on its own (remote side closed, or the
    /// channel never came up). Both can happen for the same session, in
    /// either order, so every step clears what it consumed: the caller
    /// parked in `start()` is resumed at most once, the output stream is
    /// finished once, and the connection is closed once.
    ///
    /// Everything is taken out of the actor's state before the one `await`
    /// here, so a second call arriving during it finds nothing left to do.
    private func shutDown(error: Error?) async {
        outbound = nil
        if let readyContinuation {
            self.readyContinuation = nil
            readyContinuation.resume(throwing: error ?? TerminalSessionError.notStarted)
        }
        outputContinuation?.finish()
        outputContinuation = nil
        // The connection exists only to carry this one PTY channel, so it
        // goes whenever the channel does, not just on an explicit `stop()`.
        let client = client
        self.client = nil
        try? await client?.close()
    }

    // MARK: - Called from the withPTY perform closure (same actor, see note in SSHHerdrTransport)

    private func sessionReady(outbound: TTYStdinWriter) {
        // The channel can still come up after `stop()`: opening it was
        // already in flight. It is about to be closed along with the
        // connection, so it must not be published as writable.
        guard !stopRequested else { return }
        self.outbound = outbound
        guard let readyContinuation else { return }
        self.readyContinuation = nil
        readyContinuation.resume()
    }

    private func yield(_ buffer: ByteBuffer) {
        outputContinuation?.yield(buffer)
    }
}
#endif
