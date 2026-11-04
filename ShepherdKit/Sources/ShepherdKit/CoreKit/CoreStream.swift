import Foundation

public nonisolated enum CoreStreamFailure: Error, Equatable, Sendable {
    case limitExceeded, invalidChannel, staleEpoch, closed, concurrentRead, unacknowledgedData
    case invalidReceipt, creditExceeded, bufferExceeded, invalidFrame, readOnly, timedOut, closeTimedOut
}
nonisolated struct CoreStreamID: Hashable, Sendable {
    let epoch: UUID
    let channel: UInt32
    let nonce = UUID()
}
public nonisolated struct CoreCreditReceipt: Hashable, Sendable {
    let stream: CoreStreamID
    let sequence: UInt64
    public let bytes: Int
}
public nonisolated struct CoreStreamPacket: Sendable {
    // Local provenance for every packet, including controls without a CREDIT
    // receipt. Channel numbers alone can be reused on a new connection.
    let stream: CoreStreamID
    let ordinal: UInt64
    public let frame: CoreFrame
    public let receipt: CoreCreditReceipt?
}

/// One channel on one connection epoch. The initial RPC reply contains the
/// terminal record or event snapshot. Feed/process a DATA packet BEFORE ack;
/// dequeueing it alone never grants CREDIT. Only one DATA receipt is outstanding.
public nonisolated final class CoreStream: Sendable {
    public let initialReply: CoreRPCReply
    public let observesOnly: Bool
    public let resizeNotifications: Bool
    public var channel: UInt32 { id.channel }
    let id: CoreStreamID
    private let connection: CoreRPCConnection
    init(connection: CoreRPCConnection, id: CoreStreamID, reply: CoreRPCReply, observe: Bool, resizeNotifications: Bool) {
        self.connection = connection; self.id = id; initialReply = reply
        observesOnly = observe; self.resizeNotifications = resizeNotifications
    }
    deinit {
        let connection = connection, id = id
        Task { try? await connection.closeStream(id) }
    }
    public func next(timeout: Duration? = nil) async throws -> CoreStreamPacket? {
        try await connection.nextStreamPacket(id, timeout: timeout)
    }
    @discardableResult public func acknowledge(_ packet: CoreStreamPacket) async throws -> Bool {
        guard let receipt = packet.receipt else { return false }
        try await connection.acknowledgeStream(id, receipt: receipt)
        return true
    }
    /// Acceptance into the bounded writer, NOT confirmation that the program
    /// processed the input. Later transport failure is delivered by next().
    public func send(_ bytes: Data) async throws { try await connection.sendStream(id, kind: .data, payload: bytes) }
    /// Wait for the transport writer before a short-lived attach is closed.
    /// This is NOT a program-processing ACK. A canceled/timed-out in-flight
    /// frame may still arrive and must never be automatically resent.
    public func sendAndFlush(_ bytes: Data, timeout: Duration = .seconds(10)) async throws {
        try await connection.sendStreamAndFlush(id, payload: bytes, timeout: timeout)
    }
    public func resize(columns: UInt16, rows: UInt16) async throws {
        let bytes = [UInt8(truncatingIfNeeded: columns), UInt8(truncatingIfNeeded: columns >> 8),
                     UInt8(truncatingIfNeeded: rows), UInt8(truncatingIfNeeded: rows >> 8)]
        try await connection.sendStream(id, kind: .resize, payload: Data(bytes))
    }
    public func focus(_ focused: Bool) async throws { try await connection.sendStream(id, kind: .focus, payload: Data([focused ? 1 : 0])) }
    public func displayFacts(_ json: Data) async throws {
        guard (try? JSONSerialization.jsonObject(with: json)) is [String: Any] else { throw CoreStreamFailure.invalidFrame }
        try await connection.sendStream(id, kind: .facts, payload: json)
    }
    public func close() async throws { try await connection.closeStream(id) }
}

nonisolated struct CoreStreamOpen: Sendable {
    let method: String
    let observe: Bool
    let wantsResize: Bool
    init(method: String, parameters: Data) throws {
        struct Options: Decodable { let observe: Bool?; let resize_notifications: Bool? }
        let options = try JSONDecoder().decode(Options.self, from: parameters)
        self.method = method
        observe = method == "events.subscribe" || options.observe == true
        wantsResize = options.resize_notifications == true
    }
}
/// Actor-confined; never returned from the connection or sent to another executor.
nonisolated final class CoreStreamState {
    let id: CoreStreamID
    let options: CoreStreamOpen
    let resizeNotifications: Bool
    var packets: [CoreFrame] = []
    var dataBytes = 0
    var credit = CoreWire.initialStreamCredit
    var sequence: UInt64 = 0
    var packetOrdinal: UInt64 = 0
    var outstanding: CoreCreditReceipt?
    var reader: CheckedContinuation<CoreStreamPacket?, Error>?
    var readDeadline: ContinuousClock.Instant?
    var ended = false
    var closing = false
    var closeDeadline: ContinuousClock.Instant?
    var closers: [CheckedContinuation<Void, Error>] = []
    init(id: CoreStreamID, options: CoreStreamOpen, resizeNotifications: Bool) {
        self.id = id; self.options = options; self.resizeNotifications = resizeNotifications
    }
}
