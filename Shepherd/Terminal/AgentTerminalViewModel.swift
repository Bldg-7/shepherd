import Foundation
import Observation
import SwiftTerm
import NIOCore

/// Drives a `TerminalSessionProviding` and feeds its output directly into a
/// live `TerminalView` instance — imperatively, not through SwiftUI's
/// declarative diffing, since terminal output is a byte stream rather than
/// state to re-render. One instance per pane; each `start()` attaches with a
/// session of its own, so the same instance can come back after a `stop()`.
///
/// `start()` and `stop()` are driven by a view's appearance, and SwiftUI
/// doesn't promise those arrive as one tidy appear → disappear pair: a
/// detail column can disappear and reappear, and a disappearance can land
/// while `start()` is still suspended in the connect, or before its task has
/// run at all. An attach is `herdr terminal attach --takeover` — it takes the
/// pane away from whoever else has it — so the rule here is strict: at most
/// one session is ever live, and none outlives the last `stop()`. See
/// `generation` for how that holds under any interleaving.
@MainActor
@Observable
final class AgentTerminalViewModel {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .connecting

    private let makeSession: () -> any TerminalSessionProviding
    /// The session owned by the current generation, from the moment it is
    /// created (so before it has finished connecting) until it is retired.
    ///
    /// Left out of observation, like the other bookkeeping below: no view
    /// renders from it, and `deinit` has to be able to read it.
    @ObservationIgnored private var session: (any TerminalSessionProviding)?
    private var terminalView: TerminalView?
    @ObservationIgnored private var readerTask: Task<Void, Never>?
    /// The size the terminal view last reported, whether or not there was a
    /// session to pass it on to: an attach is opened at this size, and
    /// brought up to it again if it moved while the attach was being made.
    private var pendingSize: (columns: Int, rows: Int)?
    /// Counts every `start()` and `stop()`. A `start()` remembers the value
    /// it began with and, each time it resumes from an `await`, compares:
    /// a different value means a later `stop()` or `start()` has taken over
    /// while it was suspended, so whatever it was waiting for is no longer
    /// wanted — it retires the session it created and returns without
    /// touching `connectionState`, which by then belongs to someone else.
    @ObservationIgnored private var generation = 0
    /// The most recent of the `stop()` calls made on retired sessions, each
    /// one waiting for the one before it. `start()` waits for this before
    /// creating a session, which is what keeps a reappearing view from
    /// attaching while the session it had a moment ago is still attached.
    @ObservationIgnored private var teardown: Task<Void, Never>?

    init(makeSession: @escaping () -> any TerminalSessionProviding) {
        self.makeSession = makeSession
    }

    /// Stops a session that is still live when the view model goes away
    /// without a `stop()` — SwiftUI destroying a view's state doesn't
    /// guarantee `onDisappear` was delivered first, and nothing else holds
    /// the session, so this is the last chance to end its attach.
    ///
    /// `isolated` so it runs on the main actor, like every other access to
    /// this state.
    isolated deinit {
        readerTask?.cancel()
        if let session {
            Task { await session.stop() }
        }
    }

    /// Called once by `TerminalHostView.onCreate` when the underlying
    /// terminal view is created.
    func attach(terminalView: TerminalView) {
        self.terminalView = terminalView
    }

    /// Attaches with a fresh session and returns once output is flowing (or
    /// the attempt failed, or was superseded). Safe to call again after
    /// `stop()`, and after a previous `start()` — the earlier session is
    /// retired first rather than left running alongside.
    func start() async {
        // SwiftUI cancels a `.task` when its view goes away, and a task that
        // was cancelled before it got to run still runs its body. That body
        // must not attach, and must not disturb the generation either: by
        // now the view may have come back and started a newer one.
        guard !Task.isCancelled else { return }

        generation += 1
        let generation = generation
        retireSession()
        connectionState = .connecting

        await teardown?.value
        guard isCurrent(generation) else { return }

        let session = makeSession()
        self.session = session
        let size: (columns: Int, rows: Int) = pendingSize ?? (80, 24)
        do {
            // The cancellation handler covers the case where the task is
            // cancelled but no `stop()` follows: without it the session
            // would connect and take the pane over before the check below
            // got a chance to end it.
            let output = try await withTaskCancellationHandler {
                try await session.start(columns: size.columns, rows: size.rows)
            } onCancel: {
                Task { await session.stop() }
            }
            guard isCurrent(generation) else {
                abandon(session)
                return
            }
            // The terminal view can be laid out, or laid out again, while
            // the connect is under way. A session that hasn't attached yet
            // has nothing to resize, so it turned those sizes down, and the
            // pane is still at the size the attach was opened with.
            if let pendingSize, pendingSize != size {
                resize(columns: pendingSize.columns, rows: pendingSize.rows)
            }
            // Feed whatever's already waiting before flipping to .connected,
            // so the first paint (including in #Preview snapshots) doesn't
            // race a separately-scheduled reader task for an empty screen.
            var iterator = output.makeAsyncIterator()
            let firstBuffer = await iterator.next()
            guard isCurrent(generation) else {
                abandon(session)
                return
            }
            if let firstBuffer {
                feed(firstBuffer)
            }
            connectionState = .connected
            // Weak, because this task runs for as long as the session does:
            // a strong reference would keep the view model alive until the
            // session ended, and `deinit` — whose job is to end it — would
            // never get to run.
            readerTask = Task { [weak self] in
                while let buffer = await iterator.next() {
                    guard let self, self.generation == generation else { return }
                    self.feed(buffer)
                }
                // The stream also ends when this generation is stopped;
                // only an end nobody asked for is a failure to report.
                guard let self, self.generation == generation, self.connectionState == .connected else { return }
                self.connectionState = .failed(String(localized: "The connection closed"))
            }
        } catch {
            guard isCurrent(generation) else {
                abandon(session)
                return
            }
            connectionState = .failed(connectionFailureDescription(error))
        }
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard let session else { return }
        Task { try? await session.write(Data(data)) }
    }

    func resize(columns: Int, rows: Int) {
        pendingSize = (columns, rows)
        guard let session else { return }
        Task { try? await session.resize(columns: columns, rows: rows) }
    }

    /// Ends the current attach, at whatever stage it is: connected, still
    /// connecting, or not begun (in which case the bumped generation is
    /// what stops a `start()` that is already under way from going on).
    func stop() {
        generation += 1
        retireSession()
    }

    /// Whether the `start()` that began as `generation` is still the one in
    /// charge. Task cancellation counts as not: it means the view that asked
    /// for this attach is gone, whether or not a `stop()` has said so yet.
    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    /// Lets go of the current session, if any, and queues its `stop()`.
    private func retireSession() {
        readerTask?.cancel()
        readerTask = nil
        guard let session else { return }
        self.session = nil
        queueStop(of: session)
    }

    /// For a `start()` that found itself superseded: ends the session it
    /// created. Usually whoever superseded it has retired that session
    /// already, and this second `stop()` is redundant — but it is the one
    /// made after the session's own `start()` has finished, so it holds even
    /// for a session that didn't act on a `stop()` it received mid-start.
    private func abandon(_ session: any TerminalSessionProviding) {
        if self.session === session {
            self.session = nil
        }
        queueStop(of: session)
    }

    private func queueStop(of session: any TerminalSessionProviding) {
        let previous = teardown
        teardown = Task {
            await previous?.value
            await session.stop()
        }
    }

    private func feed(_ buffer: ByteBuffer) {
        guard let terminalView else { return }
        let bytes = Array(buffer.readableBytesView)
        terminalView.feed(byteArray: bytes[...])
    }
}
