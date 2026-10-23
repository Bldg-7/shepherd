import Foundation

/// Fixed read-only endpoints on the paired Mac, not arbitrary remote paths.
/// A herdr-managed remote machine does not implement this transport primitive.
public nonisolated enum HerdrLineEndpoint: Sendable {
    case conversations, debugConversations

    public func path(home: String) throws -> String {
        let name = self == .conversations ? "ac.sock" : "ac-debug.sock"
        let path = home + "/Library/Application Support/com.bldg-7.shepherd/" + name
        guard home.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 103 else { throw HerdrLineStreamError.unsupported }
        return path
    }
}

public nonisolated enum HerdrLineStreamError: Error {
    case unsupported, invalidRequest, lineTooLong, slowConsumer, closed, timedOut
}

/// Includes the initial RPC reply followed by any notifications. Every line is
/// bounded to 2MiB; implementations keep at most two queued lines. Overflow is
/// an error/reset, never silent loss of a delta. Caller must close on completion.
public nonisolated struct HerdrLineStream: Sendable {
    public let lines: AsyncThrowingStream<Data, any Error>
    public let close: @Sendable () -> Void
    public init(lines: AsyncThrowingStream<Data, any Error>, close: @escaping @Sendable () -> Void) {
        self.lines = lines; self.close = close
    }
}

/// Does not first append an arbitrarily large chunk or materialize an array of
/// all lines in one chunk. Validates completed lines too, not just the remainder.
public nonisolated struct BoundedHostLines: Sendable {
    public static let maximumLineBytes = 2 << 20
    private var pending: [UInt8] = []
    public init() {}
    public mutating func append<Bytes: Sequence>(_ bytes: Bytes, emit: (Data) throws -> Void) throws where Bytes.Element == UInt8 {
        for byte in bytes {
            if byte == 10 {
                if !pending.isEmpty { try emit(Data(pending)); pending.removeAll(keepingCapacity: true) }
            } else {
                guard pending.count < Self.maximumLineBytes - 1 else { throw HerdrLineStreamError.lineTooLong }
                pending.append(byte)
            }
        }
    }
    public var hasIncompleteLine: Bool { !pending.isEmpty }
}
