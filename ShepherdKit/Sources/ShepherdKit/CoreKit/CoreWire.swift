import Foundation

/// Generation 1 of herdr-core's framed protocol. No process, socket, UI or
/// legacy herdr dependency. Channel routing and consumption CREDIT belong to
/// the connection/consumer, not to this byte codec.
public nonisolated enum CoreWire {
    public static let generation: UInt32 = 1
    public static let headerSize = 9
    public static let maximumPayload = 16 * 1024 * 1024
    public static let initialStreamCredit = 256 * 1024

    public enum Kind: UInt8, CaseIterable, Sendable {
        case data = 0, credit = 1, close = 2, resize = 3, focus = 4, facts = 5
    }

    /// Deliberately carries no terminal bytes, JSON, paths or server messages.
    public enum Failure: Error, Equatable, Sendable {
        case payloadTooLarge
        case unknownKind(UInt8)
        case invalidControlChannel
        case invalidControlPayload
        case truncatedFrame
        case decoderClosed
        case invalidLineLimit
        case lineTooLong
        case truncatedLine
        case invalidHello
        case helloRejected(Int)
        case unsupportedGeneration(UInt32)
        case framingNotAccepted
        case missingMethods([String])
        case truncatedHello
    }

    static func validate(channel: UInt32, kind: Kind, count: Int) throws {
        guard count <= maximumPayload else { throw Failure.payloadTooLarge }
        guard channel != 0 || kind == .data else { throw Failure.invalidControlChannel }
        switch kind {
        case .credit, .resize:
            guard count == 4 else { throw Failure.invalidControlPayload }
        case .focus:
            guard count == 1 else { throw Failure.invalidControlPayload }
        case .data, .close, .facts: break
        }
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
}

public nonisolated struct CoreFrame: Equatable, Sendable {
    public let channel: UInt32
    public let kind: CoreWire.Kind
    public let payload: Data

    public init(channel: UInt32, kind: CoreWire.Kind, payload: Data = Data()) throws {
        try CoreWire.validate(channel: channel, kind: kind, count: payload.count)
        if kind == .focus, let byte = payload.first, byte > 1 {
            throw CoreWire.Failure.invalidControlPayload
        }
        self.channel = channel
        self.kind = kind
        self.payload = payload
    }

    /// Channel 0's payload is a single JSON-RPC message, not a JSON line.
    /// Other DATA payloads are opaque bytes (not necessarily UTF-8).
    public func encoded() -> Data {
        var bytes = Data(CoreWire.littleEndian(channel))
        bytes.append(kind.rawValue)
        bytes.append(contentsOf: CoreWire.littleEndian(UInt32(payload.count)))
        bytes.append(payload)
        return bytes
    }
}

/// Holds at most one incomplete frame (9-byte header + bounded payload).
/// Complete frames are delivered synchronously rather than collected into an
/// unbounded result array. The caller must bound admission to each channel.
/// Any parse or consumer error poisons the decoder: close the connection,
/// never try to find a new frame boundary in terminal output.
public nonisolated struct CoreFrameDecoder: Sendable {
    private struct Header: Sendable {
        let channel: UInt32
        let kind: CoreWire.Kind
        let count: Int
    }
    private var headerBytes: [UInt8] = []
    private var header: Header?
    private var payload = Data()
    private var closed = false

    public init() {}
    public var bufferedByteCount: Int { headerBytes.count + payload.count }

    public mutating func receive(_ bytes: Data, emit: (CoreFrame) throws -> Void) throws {
        guard !closed else { throw CoreWire.Failure.decoderClosed }
        do {
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                if header == nil {
                    let end = cursor + min(CoreWire.headerSize - headerBytes.count, bytes.endIndex - cursor)
                    headerBytes.append(contentsOf: bytes[cursor..<end])
                    cursor = end
                    guard headerBytes.count == CoreWire.headerSize else { break }
                    guard let kind = CoreWire.Kind(rawValue: headerBytes[4]) else {
                        throw CoreWire.Failure.unknownKind(headerBytes[4])
                    }
                    let channel = CoreWire.uint32(headerBytes, at: 0)
                    let count = Int(CoreWire.uint32(headerBytes, at: 5))
                    // Reject the length before copying or allocating a payload.
                    try CoreWire.validate(channel: channel, kind: kind, count: count)
                    header = Header(channel: channel, kind: kind, count: count)
                }
                guard let header else { break }
                let end = cursor + min(header.count - payload.count, bytes.endIndex - cursor)
                payload.append(contentsOf: bytes[cursor..<end])
                cursor = end
                if payload.count == header.count {
                    let frame = try CoreFrame(channel: header.channel, kind: header.kind, payload: payload)
                    clearFrame()
                    try emit(frame)
                }
            }
        } catch {
            closed = true
            clearFrame()
            throw error
        }
    }

    /// An EOF halfway through either header or payload is a broken stream,
    /// not a clean detach. No input is accepted after finish, even on success.
    public mutating func finish() throws {
        guard !closed else { throw CoreWire.Failure.decoderClosed }
        closed = true
        let incomplete = bufferedByteCount != 0
        clearFrame()
        if incomplete { throw CoreWire.Failure.truncatedFrame }
    }

    private mutating func clearFrame() {
        headerBytes.removeAll(keepingCapacity: false)
        header = nil
        payload = Data()
    }
}
