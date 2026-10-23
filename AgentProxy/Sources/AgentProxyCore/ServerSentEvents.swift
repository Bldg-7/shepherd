import Foundation

/// Only the event name and data used by the provider adapters. This reader
/// does not reconnect, so SSE's id and retry fields are intentionally ignored.
public nonisolated struct ServerSentEvent: Equatable, Sendable {
    public let name: String
    public let data: String
}

/// Incremental UTF-8 SSE framing, independent of HTTP and the recorder's
/// socket. Lines may end in LF, CRLF or CR, including between input chunks.
/// A blank line dispatches an event; EOF alone must not dispatch a partial
/// event. Comments and unknown fields are ignored. Invalid UTF-8 in an event
/// fails capture instead of silently changing provider JSON. No transcript is written.
///
/// The caller supplies a synchronous sink rather than collecting an unbounded
/// array of events. Exceeding either bound fails this decoder permanently;
/// callers must mark that exchange incomplete, not resume midway through it.
public nonisolated struct ServerSentEventDecoder: Sendable {
    public enum Failure: Error, Equatable {
        case lineTooLong
        case eventTooLarge
        case invalidUTF8
        case closed
    }

    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var eventName: [UInt8] = []
    private var hasData = false
    private var firstLine = true
    private var skipLF = false
    private var closed = false

    public init(maximumLineBytes: Int = 1 << 20, maximumEventBytes: Int = 2 << 20) {
        precondition(maximumLineBytes >= 0 && maximumEventBytes >= 0)
        self.maximumLineBytes = maximumLineBytes
        self.maximumEventBytes = maximumEventBytes
    }

    /// Retained payload bytes, not a measure of allocator or process RSS.
    public var bufferedByteCount: Int { line.count + data.count + eventName.count }

    public mutating func append(_ bytes: Data, onEvent: (ServerSentEvent) -> Void) throws {
        guard !closed else { throw Failure.closed }
        do {
            for byte in bytes {
                if skipLF {
                    skipLF = false
                    if byte == 10 { continue }
                }
                if byte == 10 || byte == 13 {
                    try consumeLine(onEvent: onEvent)
                    skipLF = byte == 13
                } else {
                    guard line.count < maximumLineBytes else { throw Failure.lineTooLong }
                    line.append(byte)
                }
            }
        } catch {
            finish()
            throw error
        }
    }

    /// Discard the pending line/event, even if the last line ended in LF.
    /// Only an actual empty line in append() can dispatch an SSE event.
    public mutating func finish() {
        closed = true
        line = []
        data = []
        eventName = []
        hasData = false
        skipLF = false
    }

    private mutating func consumeLine(onEvent: (ServerSentEvent) -> Void) throws {
        var current = line[...]
        if firstLine {
            firstLine = false
            if current.starts(with: [0xEF, 0xBB, 0xBF]) { current = current.dropFirst(3) }
        }
        // Release long line storage after processing, rather than keeping a
        // high-water allocation for the rest of a long-lived response.
        defer { line = [] }
        if current.isEmpty {
            var event: ServerSentEvent?
            if hasData {
                guard let name = CaptureUTF8.decode(eventName),
                      let text = CaptureUTF8.decode(data) else { throw Failure.invalidUTF8 }
                event = ServerSentEvent(name: name.isEmpty ? "message" : name, data: text)
            }
            data = []
            eventName = []
            hasData = false
            if let event { onEvent(event) }
            return
        }
        if current.first == 58 { return } // comment
        let colon = current.firstIndex(of: 58)
        let field = colon.map { current[..<$0] } ?? current
        var value = colon.map { current[current.index(after: $0)...] } ?? current[current.endIndex...]
        if value.first == 32 { value = value.dropFirst() } // exactly one space
        if field.elementsEqual("data".utf8) {
            let separator = hasData ? 1 : 0
            let remaining = maximumEventBytes - eventName.count - data.count
            guard separator <= remaining, value.count <= remaining - separator else {
                throw Failure.eventTooLarge
            }
            if hasData { data.append(10) }
            data.append(contentsOf: value)
            hasData = true
        } else if field.elementsEqual("event".utf8) {
            guard value.count <= maximumEventBytes - data.count else { throw Failure.eventTooLarge }
            eventName = Array(value)
        }
    }
}
