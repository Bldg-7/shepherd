import Foundation
import NIOCore

/// Abstraction over "however we're currently attached to a pane's live
/// terminal". Mirrors `HerdrTransport`'s role for the JSON socket API: lets
/// the UI layer work the same way whether Citadel is available (real
/// `TerminalSession`) or not / for previews (`StubTerminalSession`).
///
/// A session is single-use: one `start`, then `stop` ends it for good.
protocol TerminalSessionProviding: Actor {
    /// Attaches and returns the live output stream. Throws
    /// `CancellationError` instead of attaching when `stop()` got there
    /// first — see `stop()`.
    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer>
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    /// Ends the session and finishes its output stream. Safe to call more
    /// than once, and at any point relative to `start`: before it, while it
    /// is still suspended, or after it returned.
    ///
    /// The first two matter because the UI can lose interest in a pane
    /// before the attach has finished, and an actor doesn't promise to run
    /// `start` and `stop` in the order they were sent. A session that has
    /// been told to stop must therefore never end up attached, no matter
    /// which of the two the actor gets to first — attaching means
    /// `herdr terminal attach --takeover`, which takes the pane away from
    /// whoever else is looking at it.
    func stop() async
}

/// Canned terminal output for previews and for when Citadel isn't wired up
/// yet. Echoes whatever gets written back out, so the preview UI feels
/// interactive without any real connection.
actor StubTerminalSession: TerminalSessionProviding {
    private var continuation: AsyncStream<ByteBuffer>.Continuation?
    private var stopRequested = false

    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer> {
        guard !stopRequested else { throw CancellationError() }
        return AsyncStream { continuation in
            self.continuation = continuation
            var buffer = ByteBuffer()
            buffer.writeString("Shepherd preview terminal (\(columns)x\(rows))\r\n$ ")
            continuation.yield(buffer)
        }
    }

    func write(_ data: Data) async throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        continuation?.yield(buffer)
    }

    func resize(columns: Int, rows: Int) async throws {}

    func stop() async {
        stopRequested = true
        continuation?.finish()
        continuation = nil
    }
}
