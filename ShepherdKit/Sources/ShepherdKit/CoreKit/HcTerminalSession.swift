import Foundation

/// One interactive attach on a caller-owned negotiated connection. Raw VT is
/// ordered/lossless: request a packet, render it, THEN acknowledge it. There is
/// no second AsyncStream queue, no dropped-oldest policy and no idle timeout.
/// Closing this attach never stops the program, core or shared RPC connection.
public actor HcTerminalSession {
    public enum Failure: Error, Equatable, Sendable { case notStarted, alreadyStarted, oversizedGrid, wrongTerminal }
    private let connection: CoreRPCConnection
    private let terminalID: String
    private let timeout: Duration
    private var stream: CoreStream?
    private var opening: Task<CoreStream, Error>?
    private var closing: Task<Void, Error>?
    private var hasStarted = false
    private var stopped = false

    public init(connection: CoreRPCConnection, terminalID: String, timeout: Duration = .seconds(10)) {
        self.connection = connection; self.terminalID = terminalID; self.timeout = timeout
    }
    deinit {
        opening?.cancel()
        if let stream { Task { try? await stream.close() } }
    }
    public func start(columns: Int, rows: Int) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard !hasStarted else { throw Failure.alreadyStarted }
        try grid(columns, rows)
        hasStarted = true
        let params = try JSONSerialization.data(withJSONObject: ["terminal":terminalID,"cols":columns,"rows":rows], options: [.sortedKeys])
        let connection = connection, timeout = timeout
        let job = Task { try await connection.openStream("terminal.attach", parameters: params, timeout: timeout) }
        opening = job
        do {
            let opened = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            opening = nil
            guard !stopped, !Task.isCancelled else { try await opened.close(); throw CancellationError() }
            stream = opened
            struct Attached: Decodable, Sendable {
                struct Terminal: Decodable, Sendable { let address: String }
                let terminal: Terminal
            }
            let reply: Attached = try opened.initialReply.result()
            guard reply.terminal.address == terminalID else { throw Failure.wrongTerminal }
        } catch {
            opening = nil
            try await stop()
            throw error
        }
    }
    /// A quiet interactive terminal can remain idle indefinitely. Optional
    /// timeout is for bounded tests, not normal UI lifetime. Only one packet
    /// may be outstanding; the connection enforces consumption CREDIT.
    public func nextOutput(timeout: Duration? = nil) async throws -> CoreStreamPacket? {
        guard !stopped, let stream else { throw Failure.notStarted }
        guard let packet = try await stream.next(timeout: timeout) else { return nil }
        switch packet.frame.kind {
        case .data: return packet
        case .close: return nil
        default: throw CoreStreamFailure.invalidFrame
        }
    }
    public func acknowledgeOutput(_ packet: CoreStreamPacket) async throws {
        guard !stopped, let stream else { throw Failure.notStarted }
        try await stream.acknowledge(packet)
    }
    public func write(_ data: Data) async throws {
        guard !stopped, let stream else { throw Failure.notStarted }
        try await stream.send(data)
    }
    public func writeAndFlush(_ data: Data, timeout: Duration = .seconds(10)) async throws {
        guard !stopped, let stream else { throw Failure.notStarted }
        try await stream.sendAndFlush(data, timeout: timeout)
    }
    public func resize(columns: Int, rows: Int) async throws {
        try grid(columns, rows)
        guard !stopped, let stream else { throw Failure.notStarted }
        try await stream.resize(columns: UInt16(columns), rows: UInt16(rows))
    }
    public func focus(_ focused: Bool) async throws {
        guard !stopped, let stream else { throw Failure.notStarted }
        try await stream.focus(focused)
    }
    private func grid(_ columns: Int, _ rows: Int) throws {
        guard (1...2048).contains(columns), (1...2048).contains(rows), columns * rows <= 262_144 else { throw Failure.oversizedGrid }
    }
    /// Shared cleanup task makes concurrent stop callers await the same result.
    /// Cancellation during open retires the late-open stream via RPC tombstone
    /// cleanup, never closes another channel or sends terminal.kill.
    public func stop() async throws {
        if let closing { try await closing.value; return }
        stopped = true
        let opening = opening, stream = stream
        opening?.cancel()
        let job = Task {
            var failure: (any Error)?
            if let opened = try? await opening?.value { do { try await opened.close() } catch { failure = error } }
            if let stream { do { try await stream.close() } catch { failure = error } }
            if let failure { throw failure }
        }
        closing = job
        try await job.value
        self.opening = nil; self.stream = nil
    }
}
