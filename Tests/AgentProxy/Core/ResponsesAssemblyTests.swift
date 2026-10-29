import Foundation
import AgentProxyCore

struct ResponsesAssemblyTests {
    final class Stream {
        var decoder = ServerSentEventDecoder()
        var assembly = ResponsesAssembly()
        func send(_ object: [String: Any], name: String? = nil, chunk: Int = 31) throws {
            let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let wire = Data("event: \(name ?? object["type"] as? String ?? "message")\ndata: ".utf8) + json + Data([10, 10])
            for start in stride(from: 0, to: wire.count, by: chunk) {
                try decoder.append(Data(wire[start..<min(wire.count, start + chunk)])) { assembly.consume($0) }
            }
        }
        func start() throws { try send(["type": "response.created", "response": ["id": "resp-1", "status": "in_progress", "output": []]]) }
        func item(_ index: Any, _ item: [String: Any], done: Bool = false) throws {
            try send(["type": done ? "response.output_item.done" : "response.output_item.added", "output_index": index, "item": item])
        }
        func part(_ index: Int, _ id: String, _ part: [String: Any], done: Bool = false) throws {
            try send(["type": done ? "response.content_part.done" : "response.content_part.added", "output_index": index, "content_index": 0, "item_id": id, "part": part])
        }
        func delta(_ index: Any, _ id: String, _ value: String, arguments: Bool = false, done: Bool = false) throws {
            let type = arguments ? "response.function_call_arguments" : "response.output_text"
            try send(["type": type + (done ? ".done" : ".delta"), "output_index": index,
                      "content_index": 0, "item_id": id,
                      done ? (arguments ? "arguments" : "text") : "delta": value])
        }
        func complete(_ output: [[String: Any]], transport: Bool = true) throws {
            try send(["type": "response.completed", "response": ["id": "resp-1", "status": "completed", "output": output]])
            decoder.finish(); assembly.finish(transportComplete: transport)
        }
    }
    static func message(_ id: String, _ text: String? = nil) -> [String: Any] {
        ["id": id, "type": "message", "role": "assistant", "content": text.map { [["type": "output_text", "text": $0]] } ?? []]
    }
    static func function(_ arguments: String, id: String = "fn-1", call: String = "call-1") -> [String: Any] {
        ["id": id, "type": "function_call", "call_id": call, "name": "lookup", "arguments": arguments]
    }

    static func run(check: (Bool, String) -> Void) throws {
        let stream = Stream(); try stream.start()
        let reasoning: [String: Any] = ["id": "reason-1", "type": "reasoning", "encrypted_content": "PRIVATE_REASONING"]
        try stream.item(0, reasoning)
        try stream.send(["type": "response.reasoning_summary_text.delta", "delta": "PRIVATE_REASONING_DELTA"])
        try stream.item(0, reasoning, done: true)
        try stream.item(1, message("msg-1"))
        try stream.part(1, "msg-1", ["type": "output_text", "text": ""])
        try stream.delta(1, "msg-1", "Hello")
        check(stream.assembly.snapshot.blocks.first?.text == "Hello" && stream.assembly.snapshot.status == .streaming, "Responses live text before completion")
        try stream.delta(1, "msg-1", " 한글🧪")
        let text = "Hello 한글🧪"
        try stream.delta(1, "msg-1", text, done: true)
        try stream.part(1, "msg-1", ["type": "output_text", "text": text], done: true)
        try stream.item(1, message("msg-1", text), done: true)
        // api.openai.com interleaves response.metadata with Pi's text deltas.
        try stream.send(["type": "response.metadata", "metadata": [:]])
        try stream.item(2, function(""))
        for fragment in ["{\"q\":", "\"한글\"}"] { try stream.delta(2, "fn-1", fragment, arguments: true) }
        let arguments = "{\"q\":\"한글\"}"
        try stream.delta(2, "fn-1", arguments, arguments: true, done: true)
        try stream.item(2, function(arguments), done: true)
        check(stream.assembly.snapshot.blocks.count == 2 && stream.assembly.snapshot.blocks[0].text == text, "done snapshots do not duplicate streamed text")
        try stream.complete([reasoning, message("msg-1", text), function(arguments)])
        let snapshot = stream.assembly.snapshot
        check(snapshot.status == .complete && snapshot.failure == nil && !snapshot.truncated && snapshot.responseID == "resp-1", "Responses valid completion")
        check(snapshot.blocks.map(\.kind) == [.text, .toolCall] && snapshot.blocks[1].text == arguments, "final snapshot replaces rather than appends")
        check(snapshot.blocks[1].callID == "call-1" && snapshot.blocks[1].toolName == "lookup", "function call identity distinct from item ID")
        check(!String(describing: snapshot).contains("PRIVATE_"), "reasoning fields and deltas never retained")

        let authoritative = Stream(); try authoritative.start()
        try authoritative.complete([message("final-only", "authoritative")])
        check(authoritative.assembly.snapshot.blocks.first?.text == "authoritative" && authoritative.assembly.snapshot.status == .complete, "complete final output can supply authoritative content")
        let refusal = Stream(); try refusal.start()
        try refusal.item(0, message("refusal")); try refusal.part(0, "refusal", ["type": "refusal", "refusal": ""])
        try refusal.send(["type": "response.refusal.delta", "output_index": 0, "content_index": 0, "item_id": "refusal", "delta": "No"])
        try refusal.send(["type": "response.refusal.done", "output_index": 0, "content_index": 0, "item_id": "refusal", "refusal": "No"])
        try refusal.complete([["id": "refusal", "type": "message", "role": "assistant", "content": [["type": "refusal", "refusal": "No"]]]])
        check(refusal.assembly.snapshot.blocks.first?.text == "No", "refusal text represented without duplication")
        let image = Stream(); try image.start()
        try image.complete([["id": "image", "type": "image_generation_call", "result": "PRIVATE_BASE64"]])
        check(image.assembly.snapshot.blocks.first?.kind == .image && !String(describing: image.assembly.snapshot).contains("PRIVATE_"), "image output is a placeholder only")

        let eof = Stream(); try eof.start(); eof.assembly.finish(transportComplete: true)
        check(eof.assembly.snapshot.status == .incomplete && eof.assembly.snapshot.failure == .transportIncomplete, "Responses EOF is not completion")
        let aborted = Stream(); try aborted.start(); try aborted.complete([message("m", "partial")], transport: false)
        check(aborted.assembly.snapshot.status == .incomplete, "abort overrides Responses terminal marker")
        let doneOnly = Stream(); try doneOnly.start()
        try doneOnly.decoder.append(Data("data: [DONE]\n\n".utf8)) { doneOnly.assembly.consume($0) }
        check(doneOnly.assembly.snapshot.failure == .unexpectedSequence, "DONE alone cannot claim Responses completion")
        for type in ["error", "response.failed", "response.incomplete"] {
            let error = Stream(); try error.start(); try error.send(["type": type, "message": "PRIVATE_ERROR"])
            check(error.assembly.snapshot.failure == .providerError && !String(describing: error.assembly.snapshot).contains("PRIVATE_ERROR"), "provider failure \(type)")
        }
        let mismatched = Stream(); try mismatched.start(); try mismatched.item(0, message("m")); try mismatched.part(0, "m", ["type": "output_text", "text": ""])
        try mismatched.delta(0, "another-item", "must not merge")
        check(mismatched.assembly.snapshot.failure == .unexpectedSequence && mismatched.assembly.snapshot.blocks.first?.text == "", "item IDs guard delta routing")
        let late = Stream(); try late.start(); try late.item(0, message("m")); try late.part(0, "m", ["type": "output_text", "text": ""])
        try late.delta(0, "m", "done", done: true); try late.delta(0, "m", "late")
        check(late.assembly.snapshot.failure == .unexpectedSequence, "delta after part done rejected")
        let duplicate = Stream(); try duplicate.start()
        try duplicate.complete([message("same", "a"), message("same", "b")])
        check(duplicate.assembly.snapshot.failure == .unexpectedSequence && duplicate.assembly.snapshot.blocks.isEmpty, "invalid final snapshot is transactional")
        let badArguments = Stream(); try badArguments.start(); try badArguments.item(0, function(""))
        try badArguments.delta(0, "fn-1", "{", arguments: true, done: true)
        check(badArguments.assembly.snapshot.failure == .invalidEvent, "untruncated final function arguments must be an object")
        let wrongResponse = Stream(); try wrongResponse.start()
        try wrongResponse.send(["type": "response.completed", "response": ["id": "other", "status": "completed", "output": []]])
        check(wrongResponse.assembly.snapshot.failure == .invalidEvent, "terminal response ID must match")
        for index: Any in [true, -1, 0.5, 1_000_001, "0"] {
            let invalid = Stream(); try invalid.start(); try invalid.item(index, message("m"))
            check(invalid.assembly.snapshot.status == .incomplete, "invalid Responses index")
        }

        let bound = Stream(); try bound.start(); try bound.item(0, message("m")); try bound.part(0, "m", ["type": "output_text", "text": ""])
        try bound.delta(0, "m", String(repeating: "한", count: 87_382)); let prefix = bound.assembly.snapshot.blocks[0].text
        try bound.delta(0, "m", "z")
        check(bound.assembly.snapshot.truncated && prefix.utf8.count == 262_143 && bound.assembly.snapshot.blocks[0].text == prefix, "Responses streaming prefix bound sticky")
        let argumentBound = Stream(); try argumentBound.start(); try argumentBound.complete([function(String(repeating: "x", count: 20_000))])
        check(argumentBound.assembly.snapshot.truncated && argumentBound.assembly.snapshot.blocks.first?.text.utf8.count == 16_384, "Responses function argument bound")
        let total = Stream(); try total.start()
        try total.complete([message("a", String(repeating: "a", count: 200_000)), message("b", String(repeating: "b", count: 200_000))])
        check(total.assembly.snapshot.truncated && total.assembly.snapshot.blocks.reduce(0) { $0 + $1.text.utf8.count } == 262_144, "Responses total response byte budget")
        let replacements = Stream(); try replacements.start(); try replacements.item(0, message("a", "short"))
        let longText = String(repeating: "a", count: 200_000)
        try replacements.delta(0, "a", longText, done: true)
        try replacements.part(0, "a", ["type": "output_text", "text": longText], done: true)
        try replacements.item(0, message("a", longText), done: true)
        try replacements.item(1, message("b", String(repeating: "b", count: 100_000)))
        check(replacements.assembly.snapshot.truncated && replacements.assembly.snapshot.blocks.reduce(0) { $0 + $1.text.utf8.count } == 262_144, "repeated done replacements maintain exact streaming byte accounting")
        let partFlood = Stream(); try partFlood.start()
        let hiddenParts = (0..<33).map { _ in ["type": "reasoning_text", "text": "PRIVATE_HIDDEN_PART"] }
        try partFlood.complete([["id": "a", "type": "message", "role": "assistant", "content": hiddenParts],
                                ["id": "b", "type": "message", "role": "assistant", "content": hiddenParts]])
        check(partFlood.assembly.snapshot.failure == .resourceLimit && partFlood.assembly.snapshot.blocks.isEmpty, "content block limit is global and includes hidden parts")
        let preserve = Stream(); try preserve.start(); try preserve.item(0, message("live", "keep this partial"))
        try preserve.complete([message("duplicate", "replace"), message("duplicate", "invalid")])
        check(preserve.assembly.snapshot.status == .incomplete && preserve.assembly.snapshot.blocks.first?.text == "keep this partial", "invalid final output preserves previous live content")
        let malformed = Stream(); try malformed.start()
        try malformed.decoder.append(Data("data: not json\n\n".utf8)) { malformed.assembly.consume($0) }
        check(malformed.assembly.snapshot.failure == .invalidEvent, "malformed Responses event fails capture")
        let flood = Stream(); try flood.start()
        try flood.complete((0..<65).map { ["id": "r\($0)", "type": "reasoning", "encrypted_content": "hidden"] })
        check(flood.assembly.snapshot.failure == .resourceLimit, "hidden output items also bounded")
        let unknown = Stream(); try unknown.start(); try unknown.complete([["id": "unknown", "type": "future", "payload": "PRIVATE_UNKNOWN"]])
        check(unknown.assembly.snapshot.status == .complete && unknown.assembly.snapshot.truncated && unknown.assembly.snapshot.blocks.isEmpty, "unknown output omitted with explicit projection truncation")
    }
}
