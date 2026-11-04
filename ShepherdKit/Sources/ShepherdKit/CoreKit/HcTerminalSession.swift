import Foundation

/// One interactive attach to an hc terminal on an already-negotiated
/// connection: `terminal.attach` (observe=false) yields first paint then live
/// bytes as DATA frames; keys are sent as DATA, size changes as RESIZE, and
/// the stream is retired with CLOSE. CREDIT is returned only after the UI
/// consumer has received each DATA frame — dequeuing never grants credit.
///
/// This is the hc replacement for the herdr `TerminalSession` (which ran
/// `herdr terminal attach --takeover` over an SSH PTY). No PTY, no shell
/// command string, and no separate SSH hop: input/resize/close are the
/// terminal's own stream frames. The caller owns the connection; closing this
/// session never stops the core or the terminal. Output is raw `Data` (VT/ANSI
/// as the core renders it); the UI layer owns SwiftTerm/ByteBuffer adaptation.
public actor HcTerminalSession {
    public enum Failure: Error, Equatable, Sendable {
        case notStarted, alreadyStarted, oversizedGrid
    }
    private let connection: CoreRPCConnection
    private let terminalID: String
    private let timeout: Duration
    private var stream: CoreStream?
    private var reader: Task<Void, Never>?
    private var output: AsyncStream<Data>.Continuation?
    private var hasStarted = false
    private var stopRequested = false

    public init(connection: CoreRPCConnection, terminalID: String, timeout: Duration = .seconds(10)) {
        self.connection = connection
        self.terminalID = terminalID
        self.timeout = timeout
    }

    public func start(columns: Int, rows: Int) async throws -> AsyncStream<Data> {
        guard !hasStarted else { throw Failure.alreadyStarted }
        guard (1...2048).contains(columns), (1...2048).contains(rows) else { throw Failure.oversizedGrid }
        hasStarted = true
        let parameters = try JSONSerialization.data(withJSONObject: [
            "terminal": terminalID, "cols": UInt16(columns), "rows": UInt16(rows)
        ], options: [.sortedKeys])
        let opened = try await connection.openStream("terminal.attach", parameters: parameters, timeout: timeout)
        guard !stopRequested else { try await opened.close(); throw CancellationError() }
        stream = opened
        // Install the consumer before reading, so the reader task can never
        // yield into a continuation the UI has not yet received.
        // Bounded: if the UI drains slower than the core sends, oldest output
        // is dropped (terminal scrollback semantics) instead of growing forever.
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        output = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.consumerStopped() } }
        reader = Task.detached { [weak self, opened] in await self?.pump(opened) }
        return pair.stream
    }

    public func write(_ data: Data) async throws {
        guard let stream else { throw Failure.notStarted }
        try await stream.send(data)
    }

    public func resize(columns: Int, rows: Int) async throws {
        guard let stream else { throw Failure.notStarted }
        guard (1...2048).contains(columns), (1...2048).contains(rows) else { throw Failure.oversizedGrid }
        try await stream.resize(columns: UInt16(columns), rows: UInt16(rows))
    }

    /// Ends the attach and finishes the output stream. Idempotent, and safe at
    /// any point relative to `start()`: a stop told before attach completes
    /// must never leave the terminal taken over.
    public func stop() async {
        stopRequested = true
        let reader = reader
        reader?.cancel()
        let stream = stream
        self.stream = nil
        self.reader = nil
        if let stream { try? await stream.close() }
        await reader?.value
        output?.finish()
        output = nil
    }

    private func consumerStopped() async {
        guard !stopRequested else { return }
        stopRequested = true
        reader?.cancel()
        if let stream { self.stream = nil; try? await stream.close() }
        reader = nil
    }

    private func pump(_ stream: CoreStream) async {
        do {
            while !Task.isCancelled {
                guard let packet = try await stream.next(timeout: timeout) else { break }
                if packet.frame.kind == .close { try await stream.acknowledge(packet); break }
                guard packet.frame.kind == .data else {
                    try await stream.acknowledge(packet); continue
                }
                output?.yield(packet.frame.payload)
                // Return CREDIT once the chunk is accepted into the bounded
                // buffer; a stalled UI drops oldest output rather than
                // unbounded memory, while the core stays within its credit.
                _ = try await stream.acknowledge(packet)
            }
        } catch { /* A bounded public failure kind is surfaced by the closed stream. */ }
        output?.finish()
        if !stopRequested {
            stopRequested = true
            if self.stream != nil { self.stream = nil; try? await stream.close() }
        }
    }
}
