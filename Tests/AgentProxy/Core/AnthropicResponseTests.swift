import Foundation
import AgentProxyCore

struct AnthropicResponseTests {
    final class Stream {
        var decoder = ServerSentEventDecoder()
        var assembly = AnthropicResponseAssembly()
        func send(_ object: [String: Any], name: String? = nil, chunk: Int = 7) throws {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let type = name ?? object["type"] as? String ?? "message"
            let wire = Data("event: \(type)\ndata: ".utf8) + data + Data([10, 10])
            for start in stride(from: 0, to: wire.count, by: chunk) {
                try decoder.append(Data(wire[start..<min(wire.count, start + chunk)])) { assembly.consume($0) }
            }
        }
        func start() throws {
            try send(["type": "message_start", "message": ["id": "msg-1", "role": "assistant", "content": []]])
        }
        func block(_ index: Any, _ block: [String: Any]) throws {
            try send(["type": "content_block_start", "index": index, "content_block": block])
        }
        func delta(_ index: Any, _ delta: [String: Any]) throws {
            try send(["type": "content_block_delta", "index": index, "delta": delta])
        }
        func stop(_ index: Any) throws { try send(["type": "content_block_stop", "index": index]) }
        func complete(transport: Bool = true) throws {
            try send(["type": "message_stop"])
            decoder.finish()
            assembly.finish(transportComplete: transport)
        }
    }

    static func run(check: (Bool, String) -> Void) throws {
        let stream = Stream()
        try stream.send(["type": "ping"])
        try stream.start()
        try stream.block(0, ["type": "text", "text": ""])
        try stream.delta(0, ["type": "text_delta", "text": "안녕🧪" ])
        check(stream.assembly.snapshot.blocks.first?.text == "안녕🧪" && stream.assembly.snapshot.status == .streaming, "Anthropic text visible before message completes")
        try stream.stop(0)
        try stream.block(1, ["type": "thinking", "thinking": "PRIVATE_THINKING"])
        try stream.delta(1, ["type": "thinking_delta", "thinking": "PRIVATE_DELTA"])
        try stream.delta(1, ["type": "signature_delta", "signature": "PRIVATE_SIGNATURE"])
        try stream.stop(1)
        try stream.block(2, ["type": "tool_use", "id": "call-1", "name": "read", "input": [:]])
        for fragment in ["{\"q\":\"", "한", "글\"}"] { try stream.delta(2, ["type": "input_json_delta", "partial_json": fragment]) }
        try stream.stop(2)
        try stream.block(3, ["type": "image", "source": ["data": "PRIVATE_IMAGE"]])
        try stream.stop(3)
        try stream.send(["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 10]])
        try stream.complete()
        let snapshot = stream.assembly.snapshot
        check(snapshot.responseID == "msg-1" && snapshot.status == .complete && snapshot.failure == nil && !snapshot.truncated, "valid Anthropic completion")
        check(snapshot.blocks.map(\.kind) == [.text, .toolCall, .image], "hidden blocks not retained in snapshot")
        check(snapshot.blocks[1].text == "{\"q\":\"한글\"}", "tool start {} replaced, not prepended to streamed JSON")
        check(snapshot.blocks[1].callID == "call-1" && snapshot.blocks[1].toolName == "read", "streamed tool identity")
        check(snapshot.blocks[2].text.isEmpty && !String(describing: snapshot).contains("PRIVATE_"), "no reasoning, signature or image payload retained")
        let late = Stream(); late.assembly = stream.assembly
        try late.delta(0, ["type": "text_delta", "text": "late"])
        check(late.assembly.snapshot == snapshot, "events after terminal state cannot change response")

        let emptyTool = Stream(); try emptyTool.start()
        try emptyTool.block(0, ["type": "tool_use", "id": "c", "name": "noop", "input": [:]])
        try emptyTool.stop(0); try emptyTool.complete()
        check(emptyTool.assembly.snapshot.blocks.first?.text == "{}" && emptyTool.assembly.snapshot.status == .complete, "empty tool arguments without deltas")
        let initialTool = Stream(); try initialTool.start()
        try initialTool.block(0, ["type": "tool_use", "id": "c", "name": "noop", "input": ["x": 1]])
        try initialTool.stop(0); try initialTool.complete()
        check(initialTool.assembly.snapshot.blocks.first?.text == "{\"x\":1}" && initialTool.assembly.snapshot.status == .complete, "complete initial tool arguments")

        let conflictingTool = Stream(); try conflictingTool.start()
        try conflictingTool.block(0, ["type": "tool_use", "id": "c", "name": "noop", "input": ["x": 1]])
        try conflictingTool.delta(0, ["type": "input_json_delta", "partial_json": "{"])
        check(conflictingTool.assembly.snapshot.failure == .unexpectedSequence, "cannot append streamed arguments to complete initial tool object")

        let eof = Stream(); try eof.start(); try eof.block(0, ["type": "text", "text": "partial"])
        eof.assembly.finish(transportComplete: true)
        check(eof.assembly.snapshot.status == .incomplete && eof.assembly.snapshot.failure == .transportIncomplete, "EOF without message_stop is incomplete")
        let aborted = Stream(); try aborted.start(); try aborted.block(0, ["type": "text", "text": "text"]); try aborted.stop(0)
        try aborted.complete(transport: false)
        check(aborted.assembly.snapshot.status == .incomplete, "provider stop cannot mask transport abort/drop")
        let error = Stream(); try error.start()
        try error.send(["type": "error", "error": ["message": "PRIVATE_ERROR"]])
        check(error.assembly.snapshot.failure == .providerError && !String(describing: error.assembly.snapshot).contains("PRIVATE_ERROR"), "provider errors retain no raw message")
        let premature = Stream(); try premature.start(); try premature.block(0, ["type": "text", "text": "x"])
        try premature.complete()
        check(premature.assembly.snapshot.failure == .unexpectedSequence, "cannot complete open content block")
        let duplicate = Stream(); try duplicate.start(); try duplicate.start()
        check(duplicate.assembly.snapshot.failure == .unexpectedSequence, "duplicate message start rejected")
        let missing = Stream(); try missing.start(); try missing.delta(99, ["type": "text_delta", "text": "x"])
        check(missing.assembly.snapshot.failure == .unexpectedSequence && missing.assembly.snapshot.blocks.isEmpty, "delta cannot invent a block")
        for index: Any in [true, -1, 0.5, 1_000_001, "0"] {
            let invalid = Stream(); try invalid.start(); try invalid.block(index, ["type": "text", "text": "bad"])
            check(invalid.assembly.snapshot.failure == .unexpectedSequence, "invalid content index rejected")
        }
        let mismatched = Stream(); try mismatched.send(["type": "message_start", "message": ["id": "m", "role": "assistant", "content": []]], name: "message_stop")
        check(mismatched.assembly.snapshot.failure == .invalidEvent, "event name and JSON type cannot disagree")
        let malformed = Stream()
        try malformed.decoder.append(Data("data: not json\n\n".utf8)) { malformed.assembly.consume($0) }
        check(malformed.assembly.snapshot.failure == .invalidEvent, "malformed event fails only capture")

        let bounded = Stream(); try bounded.start(); try bounded.block(0, ["type": "text", "text": ""])
        try bounded.delta(0, ["type": "text_delta", "text": String(repeating: "한", count: 87_382)])
        let prefix = bounded.assembly.snapshot.blocks[0].text
        try bounded.delta(0, ["type": "text_delta", "text": "z"])
        check(bounded.assembly.snapshot.truncated && prefix.utf8.count == 262_143 && bounded.assembly.snapshot.blocks[0].text == prefix, "streamed text cap never skips a scalar then appends later data")
        try bounded.stop(0); try bounded.block(1, ["type": "text", "text": "xy"]); try bounded.stop(1); try bounded.complete()
        check(bounded.assembly.snapshot.blocks.reduce(0) { $0 + $1.text.utf8.count } <= 262_144, "all response blocks share a total byte budget")
        let tool = Stream(); try tool.start(); try tool.block(0, ["type": "tool_use", "id": "c", "name": "x", "input": [:]])
        try tool.delta(0, ["type": "input_json_delta", "partial_json": String(repeating: "a", count: 20_000)])
        try tool.stop(0); try tool.complete()
        check(tool.assembly.snapshot.truncated && tool.assembly.snapshot.blocks[0].text.utf8.count == 16_384, "truncated tool arguments retained as explicitly truncated prefix")
        let badTool = Stream(); try badTool.start(); try badTool.block(0, ["type": "tool_use", "id": "c", "name": "x", "input": [:]])
        try badTool.delta(0, ["type": "input_json_delta", "partial_json": "{\"x\":"]); try badTool.stop(0)
        check(badTool.assembly.snapshot.failure == .invalidEvent, "untruncated completed tool arguments must be an object")
        let flood = Stream(); try flood.start()
        for i in 0..<65 { try flood.block(i, ["type": "thinking", "thinking": "not retained"]); try flood.stop(i) }
        check(flood.assembly.snapshot.failure == .resourceLimit && flood.assembly.snapshot.blocks.isEmpty, "hidden blocks also count toward entry bound")
        let unknown = Stream(); try unknown.start(); try unknown.block(0, ["type": "future_block", "payload": "PRIVATE_FUTURE"])
        try unknown.stop(0); try unknown.complete()
        check(unknown.assembly.snapshot.truncated && unknown.assembly.snapshot.blocks.isEmpty && unknown.assembly.snapshot.status == .complete, "unknown block omitted with explicit projection truncation")
    }
}
