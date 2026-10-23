import Foundation
import AgentProxyCore

struct RequestProjectionTests {
    static func run(check: (Bool, String) -> Void) throws {
        func project(_ object: [String: Any], _ provider: RequestProjection.Provider = .anthropic) throws -> CapturedRequest {
            try RequestProjection.project(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), provider: provider)
        }
        func user(_ text: String) throws -> CapturedRequest {
            try project(["messages": [["role": "user", "content": text]]])
        }
        func failure(_ data: Data, _ expected: RequestProjection.Failure, limit: Int = ConversationCaptureLimits.decompressedRequest) {
            do {
                _ = try RequestProjection.project(data, provider: .anthropic, maximumBodyBytes: limit)
                check(false, "request expected \(expected)")
            } catch { check(error as? RequestProjection.Failure == expected, "request failure \(expected)") }
        }
        let request = try project([
            "system": "PRIVATE_SYSTEM", "metadata": ["credential": "PRIVATE_METADATA"],
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": "Hi<system-reminder>PRIVATE_META<system-reminder>NESTED</system-reminder>TAIL</system-reminder>!"],
                    ["type": "image", "source": ["data": "PRIVATE_IMAGE"]]]],
                ["role": "assistant", "content": [
                    ["type": "thinking", "thinking": "PRIVATE_THINKING"],
                    ["type": "redacted_thinking", "data": "PRIVATE_REDACTED"],
                    ["type": "tool_use", "id": "call-1", "name": "lookup", "input": ["b": 2, "a": 1]],
                    ["type": "text", "text": "Checking"]]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "call-1", "content": [
                        ["type": "text", "text": "OK"], ["type": "image", "source": ["data": "PRIVATE_TOOL_IMAGE"]]]]]],
                ["role": "assistant", "content": "Done"]
            ]
        ])
        check(request.messages.count == 4 && !request.truncated, "Anthropic visible history order")
        check(request.messages[0].blocks.map(\.kind) == [.text, .image], "user text and image placeholder")
        check(request.messages[0].blocks[0].text == "Hi!", "nested metadata removed without losing surrounding user text")
        let call = request.messages[1].blocks[0]
        check(call.kind == .toolCall && call.callID == "call-1" && call.toolName == "lookup", "Anthropic tool identity")
        check(call.text == "{\"a\":1,\"b\":2}", "tool JSON canonical key order")
        check(request.messages[2].blocks[0].text == "OK\n[Image]", "tool image has no payload")
        check(!String(describing: request).contains("PRIVATE_"), "system, metadata, thinking and image contents not retained")

        let responses = try project([
            "instructions": "PRIVATE_INSTRUCTIONS", "previous_response_id": "response-previous",
            "input": [
                ["role": "developer", "content": "PRIVATE_DEVELOPER"],
                ["type": "reasoning", "encrypted_content": "PRIVATE_REASONING"],
                ["role": "user", "content": [["type": "input_text", "text": "Question"]]],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Answer"]]],
                ["type": "function_call", "call_id": "call-2", "name": "read", "arguments": "{\"path\":\"a\"}"],
                ["type": "function_call_output", "call_id": "call-2", "output": "result"]
            ]
        ], .responses)
        check(responses.messages.count == 4 && !responses.truncated, "Responses messages and tools projected")
        check(responses.previousResponseID == "response-previous", "Responses continuation reference retained")
        check(responses.messages.map(\.role) == [.user, .assistant, .assistant, .tool], "Responses roles")
        check(responses.messages[2].blocks[0].callID == "call-2", "Responses call ID distinct from item ID")
        check(responses.messages[3].blocks[0].kind == .toolResult && responses.messages[3].blocks[0].text == "result", "Responses function output")
        check(!String(describing: responses).contains("PRIVATE_"), "Responses reasoning and instructions excluded")
        let plain = try project(["input": "Simple", "previous_response_id": NSNull()], .responses)
        check(plain.messages[0].blocks[0].text == "Simple" && plain.previousResponseID == nil, "Responses shorthand input")

        for tag in ["environment_context", "command-name", "command-message", "command-args", "local-command-stdout", "local-command-stderr"] {
            let result = try user("before<\(tag)>hidden</\(tag)>after")
            check(result.messages.first?.blocks.first?.text == "beforeafter", "known metadata \(tag)")
        }
        check(try user("<system-reminder>hidden").messages.isEmpty, "unterminated metadata remainder hidden")
        check(try user("<custom-tag>user text</custom-tag>").messages.first?.blocks.first?.text == "<custom-tag>user text</custom-tag>", "unknown user tags kept")
        let assistantTag = try project(["messages": [["role": "assistant", "content": "<system-reminder>explaining this tag</system-reminder>"]]])
        check(assistantTag.messages[0].blocks[0].text.contains("explaining"), "assistant explanations not filtered as request metadata")
        let overflowedMetadata = try user(String(repeating: "<system-reminder>", count: 65) + "hidden")
        check(overflowedMetadata.truncated && overflowedMetadata.messages.isEmpty, "metadata nesting bounded")

        let text = String(repeating: "한", count: 30_000)
        let bounded = try user(text)
        check(bounded.truncated && bounded.messages[0].truncated, "user truncation explicit")
        check(bounded.messages[0].blocks[0].text.utf8.count == 65_535, "user cap does not split a Korean scalar")
        let acrossMetadata = try user(String(repeating: "한", count: 21_845) + "🧪<system-reminder>hidden</system-reminder>z")
        check(acrossMetadata.messages[0].blocks[0].text.utf8.count == 65_535 && !acrossMetadata.messages[0].blocks[0].text.hasSuffix("z"), "truncation cannot skip a scalar then append a later segment")
        let delimiterFlood = try user("visible<system-reminder>" + String(repeating: "<unknown>", count: 5_000) + "</system-reminder>after")
        check(delimiterFlood.truncated && delimiterFlood.messages[0].blocks[0].text == "visible", "metadata scan work bounded on delimiter flood")
        let many = try project(["messages": (0..<205).map { ["role": "user", "content": "message-\($0)"] }])
        check(many.messages.count == 200 && many.truncated, "history count bounded")
        check(many.messages.first?.blocks.first?.text == "message-5" && many.messages.last?.blocks.first?.text == "message-204", "newest visible history kept in chronological order")
        let large = try project(["messages": (0..<20).map { n in
            ["role": "assistant", "content": String(n) + String(repeating: "a", count: 262_140)]
        }])
        check(large.truncated && large.messages.count < 20 && !large.messages.isEmpty, "aggregate projected history bounded")
        check(large.messages.last?.blocks.first?.text.hasPrefix("19") == true, "aggregate bound preserves recent end")
        let tool = try project(["input": [["type": "function_call_output", "call_id": "c", "output": String(repeating: "x", count: 20_000)]]], .responses)
        check(tool.messages[0].blocks[0].text.utf8.count == 16_384 && tool.truncated, "tool cap")
        let images = try project(["messages": [["role": "user", "content": (0..<65).map { _ in ["type": "image"] }]]])
        check(images.messages[0].blocks.count == 64 && images.truncated, "empty image objects still count toward block limit")
        let missing = try project(["input": [["type": "function_call", "name": "missing-id", "arguments": "{}"]]], .responses)
        check(missing.messages.isEmpty && missing.truncated, "invalid tool identity not invented or truncated into a collision")
        let unknown = try project(["input": [["type": "unknown-provider-item"]]], .responses)
        check(unknown.messages.isEmpty && unknown.truncated, "unknown provider item cannot masquerade as full history")
        let compaction = try project(["input": [["type": "compaction", "encrypted_content": "PRIVATE_COMPACTION"]]], .responses)
        check(compaction.truncated && compaction.messages.isEmpty, "encrypted compaction not exposed as text or claimed reconstructed")

        failure(Data("not json".utf8), .invalidJSON)
        failure(Data("[]".utf8), .unsupportedShape)
        failure(Data("{}".utf8), .unsupportedShape)
        failure(Data("{\"messages\":[]}".utf8), .resourceLimit, limit: 4)
        failure(Data("{\"messages\":[\"".utf8) + Data([0xFF]) + Data("\"]}".utf8), .invalidJSON)
        failure(Data([0xFF, 0xFE, 0x7B, 0, 0x7D, 0]), .invalidJSON)
        failure(Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8), .resourceLimit)
        failure(Data(("[" + Array(repeating: "0", count: 100_002).joined(separator: ",") + "]").utf8), .resourceLimit)
        let escaped = try user("quoted \" braces {[ ]} \\ and newline\n")
        check(!escaped.truncated && escaped.messages.count == 1, "JSON structure scanner ignores quoted punctuation and escapes")
    }
}
