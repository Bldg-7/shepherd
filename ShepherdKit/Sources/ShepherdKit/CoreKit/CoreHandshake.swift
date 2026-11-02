import Foundation

/// Connection metadata, NOT browser authority. core.id survives core restarts;
/// generation identifies the API, not a connection epoch or process instance.
public nonisolated struct CoreHello: Decodable, Equatable, Sendable {
    public struct Identity: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String
    }
    public let core: Identity
    public let generation: UInt32
    public let version: String
    public let methods: [String]
    public let features: [String]
    public let framed: Bool
}

/// Validates the one plain-mode hello, then hands the exact remaining bytes
/// to the framed decoder. SSH stdout banners are errors, not something to
/// skip. Stderr must be kept separate by the endpoint.
///
/// This is a pure state machine. Deadlines, RPC multiplexing, late attach
/// replies, channel lifetime and CREDIT accounting belong to CoreConnection.
public nonisolated struct CoreHandshakeDecoder: Sendable {
    public static let maximumHelloBytes = 64 * 1024
    public let requestID: UInt64
    public let requiredMethods: Set<String>
    public private(set) var hello: CoreHello?
    private var line = Data()
    private var frames = CoreFrameDecoder()
    private var closed = false

    public init(requestID: UInt64 = 0,
                requiredMethods: Set<String> = ["terminal.list", "terminal.attach", "events.subscribe"]) {
        self.requestID = requestID
        self.requiredMethods = requiredMethods
    }

    /// Consumers must add the methods they need; a successful minimal hello
    /// is not proof that every product feature is available. Optional features
    /// are checked by name, never inferred from a package version string.
    public func request() throws -> Data {
        struct Params: Encodable {
            let framed = true
            let generation = CoreWire.generation
        }
        struct Request: Encodable {
            let jsonrpc = "2.0"
            let id: UInt64
            let method = "hello"
            let params = Params()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(Request(id: requestID))
        bytes.append(0x0a)
        return bytes
    }

    public var bufferedByteCount: Int { line.count + frames.bufferedByteCount }

    public mutating func receive(_ bytes: Data,
                                 onHello: (CoreHello) throws -> Void,
                                 onFrame: (CoreFrame) throws -> Void) throws {
        guard !closed else { throw CoreWire.Failure.decoderClosed }
        do {
            if hello != nil {
                try frames.receive(bytes, emit: onFrame)
                return
            }
            let newline = bytes.firstIndex(of: 0x0a)
            let end = newline ?? bytes.endIndex
            guard end - bytes.startIndex <= Self.maximumHelloBytes - line.count else {
                throw CoreWire.Failure.lineTooLong
            }
            line.append(contentsOf: bytes[bytes.startIndex..<end])
            guard let newline else { return }
            let accepted = try accept(line)
            line = Data()
            hello = accepted
            try onHello(accepted)
            // A read can contain the newline and one or many binary frames.
            try frames.receive(bytes[(newline + 1)...], emit: onFrame)
        } catch {
            closed = true
            hello = nil
            line = Data()
            frames = CoreFrameDecoder()
            throw error
        }
    }

    public mutating func finish() throws {
        guard !closed else { throw CoreWire.Failure.decoderClosed }
        closed = true
        guard hello != nil else {
            line = Data()
            throw CoreWire.Failure.truncatedHello
        }
        do { try frames.finish() }
        catch { hello = nil; throw error }
    }

    private func accept(_ bytes: Data) throws -> CoreHello {
        struct Rejection: Decodable { let code: Int }
        struct Reply: Decodable {
            let jsonrpc: String
            let id: UInt64
            let result: CoreHello?
            let error: Rejection?
        }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: bytes) }
        catch { throw CoreWire.Failure.invalidHello }
        guard reply.jsonrpc == "2.0", reply.id == requestID,
              (reply.result == nil) != (reply.error == nil) else { throw CoreWire.Failure.invalidHello }
        if let error = reply.error { throw CoreWire.Failure.helloRejected(error.code) }
        guard let result = reply.result, !result.core.id.isEmpty, !result.version.isEmpty else {
            throw CoreWire.Failure.invalidHello
        }
        guard result.generation == CoreWire.generation else {
            throw CoreWire.Failure.unsupportedGeneration(result.generation)
        }
        guard result.framed else { throw CoreWire.Failure.framingNotAccepted }
        let missing = requiredMethods.subtracting(result.methods).sorted()
        guard missing.isEmpty else { throw CoreWire.Failure.missingMethods(missing) }
        return result
    }
}
