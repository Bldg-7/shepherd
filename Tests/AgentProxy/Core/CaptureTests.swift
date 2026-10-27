import Foundation
import AgentProxyCore

@main
struct CaptureTests {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { passed += 1 }
        else { failed += 1; print("FAIL: \(message)") }
    }

    static func events(_ chunks: [Data], line: Int = 1 << 20, event: Int = 2 << 20) throws -> [[String]] {
        var decoder = ServerSentEventDecoder(maximumLineBytes: line, maximumEventBytes: event)
        var result: [[String]] = []
        for chunk in chunks { try decoder.append(chunk) { result.append([$0.name, $0.data]) } }
        decoder.finish()
        check(decoder.bufferedByteCount == 0, "finish releases all retained event bytes")
        return result
    }

    static func failure(_ input: Data, line: Int, event: Int, expected: ServerSentEventDecoder.Failure) {
        var decoder = ServerSentEventDecoder(maximumLineBytes: line, maximumEventBytes: event)
        do {
            try decoder.append(input) { _ in }
            check(false, "expected \(expected)")
        } catch let error as ServerSentEventDecoder.Failure {
            check(error == expected, "specific decoder failure \(expected)")
        } catch { check(false, "unexpected error type") }
        check(decoder.bufferedByteCount == 0, "failure releases retained data")
        do {
            try decoder.append(Data("data: later\n\n".utf8)) { _ in }
            check(false, "failed decoder must not resume")
        } catch let error as ServerSentEventDecoder.Failure {
            check(error == .closed, "failed decoder stays closed")
        } catch { check(false, "unexpected repeated failure type") }
    }

    static func main() throws {
        // Exercise every pair of chunk boundaries, including inside the BOM,
        // multibyte scalars, field names, JSON and CRLF delimiters.
        let input = Data("\u{FEFF}:ping\r\nevent: delta\r\ndata: {\"text\":\"한글🧪\"}\r\n\r\ndata: [DONE]\n\n".utf8)
        let expected = [["delta", "{\"text\":\"한글🧪\"}"], ["message", "[DONE]"]]
        for first in 0...input.count {
            for second in first...input.count {
                let actual = try events([Data(input[..<first]), Data(input[first..<second]), Data(input[second...])])
                check(actual == expected, "chunk boundaries \(first),\(second)")
            }
        }
        let bytes = input.map { Data([$0]) }
        check(try events(bytes) == expected, "one byte chunks")
        for newline in ["\n", "\r", "\r\n"] {
            let body = ["data: first", "data: second", "", ""].joined(separator: newline)
            check(try events([Data(body.utf8)]) == [["message", "first\nsecond"]], "newline \(Array(newline.utf8))")
        }
        check(try events([Data("event: unused\n\ndata: text\n\n".utf8)]) == [["message", "text"]], "event name cleared by empty block")
        check(try events([Data("event: a\nevent: b\ndata:x\n\ndata:y\n\n".utf8)]) == [["b", "x"], ["message", "y"]], "last event name wins and resets")
        check(try events([Data("event:x\nevent:\ndata:z\n\n".utf8)]) == [["message", "z"]], "empty event name means message")
        check(try events([Data("data\n\ndata:\n\n".utf8)]) == [["message", ""], ["message", ""]], "empty data dispatches")
        check(try events([Data("data:  x:y\ndata:\ndata:z\n\n".utf8)]) == [["message", " x:y\n\nz"]], "only one leading space removed")
        check(try events([Data(": ping\nid: 7\nretry: 100\nData: ignored\nunknown:x\n\n".utf8)]).isEmpty, "comments, reconnection and unknown fields ignored")
        check(try events([Data("data: ok\n\ndata: unfinished\n".utf8)]) == [["message", "ok"]], "EOF does not dispatch a partial block")
        check(try events([Data("data: unfinished".utf8)]).isEmpty, "EOF does not dispatch partial line")
        check(try events([Data("data: before\n\ndata: \u{FEFF}after\n\n".utf8)]) == [["message", "before"], ["message", "\u{FEFF}after"]], "BOM only removed at stream start")

        check(try events([Data("data:1234\n\n".utf8)], line: 9, event: 4) == [["message", "1234"]], "exact line and event limits accepted")
        check(try events([Data("event:ab\ndata:cd\n\n".utf8)], line: 8, event: 4) == [["ab", "cd"]], "event name counted in budget")
        check(try events([Data("data:a\ndata:b\n\n".utf8)], line: 8, event: 3) == [["message", "a\nb"]], "data newline counted in budget")
        check(try events([Data("data:\n\n".utf8)], line: 5, event: 0) == [["message", ""]], "zero event budget accepts empty data")
        failure(Data("data:12345".utf8), line: 9, event: 100, expected: .lineTooLong)
        failure(Data("data:12345\n".utf8), line: 20, event: 4, expected: .eventTooLarge)
        failure(Data("data:a\ndata:b\n".utf8), line: 20, event: 2, expected: .eventTooLarge)
        failure(Data("data:abcd\nevent:x\n".utf8), line: 20, event: 4, expected: .eventTooLarge)
        failure(Data("event:abcd\ndata:x\n".utf8), line: 20, event: 4, expected: .eventTooLarge)
        failure(Data("data:".utf8) + Data([0xF0, 0x9F, 10, 10]), line: 20, event: 20, expected: .invalidUTF8)
        failure(Data("event:".utf8) + Data([0xFF]) + Data("\ndata:x\n\n".utf8), line: 20, event: 20, expected: .invalidUTF8)
        failure(Data([65]), line: 0, event: 0, expected: .lineTooLong)
        // The iOS-17-compatible round-trip validator must reject replacement
        // decoding, but preserve a genuine U+FFFD scalar sent by the provider.
        for invalid: [UInt8] in [[0x80], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]] {
            failure(Data("data:".utf8) + Data(invalid) + Data([10, 10]),
                    line: 20, event: 20, expected: .invalidUTF8)
        }
        check(try events([Data("data: \u{FFFD}\u{0}\n\n".utf8)]) == [["message", "\u{FFFD}\u{0}"]], "valid replacement scalar and NUL preserved")
        var done = ServerSentEventDecoder()
        done.finish()
        do { try done.append(Data()) { _ in }; check(false, "EOF stays terminal") }
        catch { check(error as? ServerSentEventDecoder.Failure == .closed, "EOF stays terminal") }
        var stream = ServerSentEventDecoder(maximumLineBytes: 10, maximumEventBytes: 1)
        var count = 0
        for _ in 0..<10_000 { try stream.append(Data("data:x\n\n".utf8)) { _ in count += 1 } }
        check(count == 10_000 && stream.bufferedByteCount == 0, "long stream dispatches without retaining prior events")

        var body = BoundedCaptureBody(maximumBytes: 4)
        check(body.append(Data([1, 2])) && body.append(Data([3, 4])), "body allows exact bound across chunks")
        check(body.finish() == Data([1, 2, 3, 4]), "complete body returned")
        check(body.bufferedByteCount == 0 && !body.append(Data()) && body.finish() == nil, "body cannot be consumed or appended twice")
        var overflow = BoundedCaptureBody(maximumBytes: 4)
        check(overflow.append(Data([1, 2, 3])), "partial body accepted")
        check(!overflow.append(Data([4, 5])) && overflow.overflowed, "whole crossing chunk rejected")
        check(overflow.bufferedByteCount == 0, "overflow releases partial body")
        check(!overflow.append(Data([6])) && overflow.finish() == nil, "overflow cannot recover by later chunk")
        var aborted = BoundedCaptureBody(maximumBytes: 4)
        aborted.append(Data([1]))
        check(aborted.finish(complete: false) == nil && aborted.bufferedByteCount == 0, "aborted body discarded")
        var empty = BoundedCaptureBody(maximumBytes: 0)
        check(empty.append(Data()) && empty.finish() == Data(), "empty complete body is not an error")
        var zero = BoundedCaptureBody(maximumBytes: 0)
        check(!zero.append(Data([1])) && zero.finish() == nil, "zero bound rejects nonempty body")

        for value in ["", "ASCII", "한글", "🧪😀", "a\u{301}z", "가🧪b", "\u{FEFF}inside", "\u{0}text"] {
            let encoded = Array(value.utf8)
            for limit in 0...(encoded.count + 2) {
                let prefix = ConversationCaptureLimits.textPrefix(value, maximumBytes: limit)
                check(prefix.utf8.count <= limit, "UTF8 byte bound")
                check(encoded.starts(with: prefix.utf8), "prefix has original bytes, no replacement scalar")
                if limit >= encoded.count { check(prefix == value, "whole string retained when it fits") }
                else {
                    let upper = min(encoded.count, limit)
                    let longest = (0...upper).reversed().compactMap { String(validating: encoded.prefix($0), as: UTF8.self) }.first!
                    check(prefix == longest, "longest valid UTF8 prefix")
                }
            }
        }
        check(ConversationCaptureLimits.userText == 65_536, "user bound")
        check(ConversationCaptureLimits.assistantText == 262_144, "assistant bound")
        check(ConversationCaptureLimits.toolText == 16_384, "tool bound")
        check(ConversationCaptureLimits.conversation == 4_194_304, "conversation bound")
        check(ConversationCaptureLimits.allConversations == 134_217_728, "aggregate bound")
        check(ConversationCaptureLimits.compressedRequest == 67_108_864 && ConversationCaptureLimits.decompressedRequest == 134_217_728, "request capture bounds")
        check(ConversationCaptureLimits.reconstructedHistoryItems == 200, "history item bound")
        try RequestProjectionTests.run(check: check)
        try AnthropicResponseTests.run(check: check)
        try ResponsesAssemblyTests.run(check: check)
        try ConversationStoreTests.run(check: check)
        try ConversationPersistenceTests.run(check: check)
        try ConversationReconcilerTests.run(check: check)
        try RequestClassificationTests.run(check: check)
        try CompactionProjectionTests.run(check: check)
        try ConversationOwnerTests.run(check: check)
        try ConversationCaptureTests.run(check: check)
        try ConversationReadAPITests.run(check: check)
        try ConversationSubscriptionTests.run(check: check)
        try PiClassificationTests.run(check: check)
        try SubagentTests.run(check: check)
        print("Capture tests: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
