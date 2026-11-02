import Foundation

/// Event stream DATA contains newline-delimited JSON, but a DATA frame can
/// end anywhere in a line, including in the middle of a UTF-8 character.
/// This layer preserves raw bytes; the event reducer validates JSON later.
/// Empty lines are emitted too, never silently treated as valid events.
public nonisolated struct CoreEventLines: Sendable {
    public let maximumLineBytes: Int
    private var pending = Data()
    private var closed = false

    public init(maximumLineBytes: Int = CoreWire.maximumPayload) throws {
        guard (1...CoreWire.maximumPayload).contains(maximumLineBytes) else {
            throw CoreWire.Failure.invalidLineLimit
        }
        self.maximumLineBytes = maximumLineBytes
    }

    public var bufferedByteCount: Int { pending.count }

    public mutating func receive(_ bytes: Data, emit: (Data) throws -> Void) throws {
        guard !closed else { throw CoreWire.Failure.decoderClosed }
        do {
            var cursor = bytes.startIndex
            while cursor < bytes.endIndex {
                let newline = bytes[cursor...].firstIndex(of: 0x0a)
                let end = newline ?? bytes.endIndex
                guard end - cursor <= maximumLineBytes - pending.count else {
                    throw CoreWire.Failure.lineTooLong
                }
                pending.append(contentsOf: bytes[cursor..<end])
                if let newline {
                    let line = pending
                    pending = Data()
                    try emit(line)
                    cursor = newline + 1
                } else {
                    break
                }
            }
        } catch {
            closed = true
            pending = Data()
            throw error
        }
    }

    public mutating func finish() throws {
        guard !closed else { throw CoreWire.Failure.decoderClosed }
        closed = true
        let incomplete = !pending.isEmpty
        pending = Data()
        if incomplete { throw CoreWire.Failure.truncatedLine }
    }
}
