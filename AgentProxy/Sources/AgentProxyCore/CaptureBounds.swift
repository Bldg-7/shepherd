import Foundation

/// The capture contract's limits, in payload bytes. Aggregate admission and
/// eviction belong to the recorder/store, not to a single body accumulator.
public nonisolated enum ConversationCaptureLimits {
    public static let userText = 64 << 10
    public static let assistantText = 256 << 10
    public static let toolText = 16 << 10
    public static let conversation = 4 << 20
    public static let allConversations = 128 << 20
    public static let compressedRequest = 64 << 20
    public static let decompressedRequest = 128 << 20
    public static let reconstructedHistoryItems = 200

    /// A valid UTF-8 prefix within the byte budget, never a replacement
    /// character made by splitting a scalar. This can split a grapheme cluster
    /// (for example between a letter and a combining mark), not a UTF-8 scalar.
    public static func textPrefix(_ text: String, maximumBytes: Int) -> String {
        precondition(maximumBytes >= 0)
        var prefix = Array(text.utf8.prefix(maximumBytes))
        // A prefix of valid UTF-8 needs at most three trailing bytes removed.
        while !prefix.isEmpty {
            if let result = CaptureUTF8.decode(prefix) { return result }
            prefix.removeLast()
        }
        return ""
    }
}

/// All-or-nothing, bounded capture of one request body. Overflow immediately
/// releases the partial body and remains sticky: later chunks cannot turn a
/// truncated JSON document into an apparently complete request. This does not
/// affect the bytes the independent forwarder sends to the agent/provider.
public nonisolated struct BoundedCaptureBody: Sendable {
    public let maximumBytes: Int
    private var storage = Data()
    public private(set) var overflowed = false
    private var finished = false

    public init(maximumBytes: Int) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    public var bufferedByteCount: Int { storage.count }

    @discardableResult
    public mutating func append(_ bytes: Data) -> Bool {
        guard !finished, !overflowed else { return false }
        guard bytes.count <= maximumBytes - storage.count else {
            storage = Data()
            overflowed = true
            return false
        }
        storage.append(bytes)
        return true
    }

    /// nil means overflow, an aborted request, or a repeated finish. No partial
    /// body is returned on those paths. An empty but complete body is Data().
    public mutating func finish(complete: Bool = true) -> Data? {
        guard !finished else { return nil }
        finished = true
        defer { storage = Data() }
        return complete && !overflowed ? storage : nil
    }
}
