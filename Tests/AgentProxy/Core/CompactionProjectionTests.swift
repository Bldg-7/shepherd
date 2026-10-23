import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct CompactionProjectionTests {
    static func run(check: (Bool, String) -> Void) throws {
        let claude = RequestClassification.classify(RequestClassificationTests.open(.claude, headers: [
            ["x-claude-code-session-id", "native"], ["x-claude-code-request-class", "compaction"]]), body: Data())
        let codex = RequestClassification.classify(RequestClassificationTests.open(.codex), body: try RequestClassificationTests.body("compaction"))
        let anthropic = AnthropicResponseTests.Stream()
        try anthropic.start()
        try anthropic.block(0, ["type": "text", "text": "요약🧪"]); try anthropic.stop(0)
        try anthropic.block(1, ["type": "thinking", "thinking": "PRIVATE_THINKING"]); try anthropic.stop(1)
        try anthropic.block(2, ["type": "tool_use", "id": "tool", "name": "read", "input": ["x": "PRIVATE_TOOL"]]); try anthropic.stop(2)
        try anthropic.block(3, ["type": "image", "source": ["data": "PRIVATE_IMAGE"]]); try anthropic.stop(3)
        try anthropic.block(4, ["type": "text", "text": "다음 단계"]); try anthropic.stop(4)
        try anthropic.complete()
        let plain = CompactionProjection.project(anthropic.assembly.snapshot, classification: claude, transportComplete: true)
        check(plain?.availability == .plaintext && plain?.text == "요약🧪\n\n다음 단계" && plain?.status == .complete, "compaction captures only completed visible summary text")
        check(!String(describing: plain).contains("PRIVATE_"), "summary retains no thinking/image/tool data")
        check(claude.mainConversationKey == nil && codex.mainConversationKey == nil, "compaction projection never promotes requests to main ownership")
        for kind in ["main", "subagent", "auxiliary", "future"] {
            let request = RequestClassification.classify(RequestClassificationTests.open(.claude, headers: [
                ["x-claude-code-session-id", "native"], ["x-claude-code-request-class", kind]]), body: Data())
            check(CompactionProjection.project(anthropic.assembly.snapshot, classification: request, transportComplete: true) == nil, "non-compaction \(kind) cannot create summary")
        }
        let pi = RequestClassification.classify(RequestClassificationTests.open(.pi, headers: [["x-3rdr-pi-class", "compaction"]]), body: Data())
        check(CompactionProjection.project(anthropic.assembly.snapshot, classification: pi, transportComplete: true) == nil, "unverified Pi compaction tag stays untrusted")
        let aborted = CompactionProjection.project(anthropic.assembly.snapshot, classification: claude, transportComplete: false)
        check(aborted?.availability == .incomplete && aborted?.text == nil && aborted?.status == .incomplete, "tee failure overrides provider completion")
        let pending = AnthropicResponseTests.Stream(); try pending.start()
        try pending.block(0, ["type": "text", "text": "not a complete summary"])
        let partial = CompactionProjection.project(pending.assembly.snapshot, classification: claude, transportComplete: true)
        check(partial?.availability == .incomplete && partial?.text == nil, "streaming summary cannot be advertised as completed")
        try pending.send(["type": "error", "error": ["message": "PRIVATE_ERROR"]])
        check(CompactionProjection.project(pending.assembly.snapshot, classification: claude, transportComplete: true)?.availability == .incomplete, "provider failure cannot create successful compaction")

        for type in ["compaction", "compaction_summary", "context_compaction"] {
            for id: Any? in [nil, NSNull(), "compact-1"] {
                var item: [String: Any] = ["type": type, "encrypted_content": "PRIVATE_CIPHERTEXT",
                    "summary": "PRIVATE_FAKE_SUMMARY", "content": [["type": "text", "text": "PRIVATE_FAKE_TEXT"]]]
                if let id { item["id"] = id }
                let stream = ResponsesAssemblyTests.Stream(); try stream.start()
                try stream.item(0, item); try stream.item(0, item, done: true)
                check(stream.assembly.snapshot.containsOpaqueCompaction && stream.assembly.snapshot.blocks.isEmpty, "\(type) optional ID observed without retaining payload")
                try stream.complete([item])
                let response = stream.assembly.snapshot
                let result = CompactionProjection.project(response, classification: codex, transportComplete: true)
                check(response.status == .complete && response.failure == nil && !response.truncated, "known \(type) is not unsupported output")
                check(result?.availability == .opaque && result?.text == nil && result?.status == .complete, "opaque summary has typed unavailable marker")
                check(!String(describing: response).contains("PRIVATE_") && !String(describing: result).contains("PRIVATE_"), "ciphertext/unknown plaintext fields never retained")
            }
        }
        for item: [String: Any] in [["type": "context_compaction"], ["type": "context_compaction", "encrypted_content": NSNull()]] {
            let stream = ResponsesAssemblyTests.Stream(); try stream.start(); try stream.complete([item])
            check(stream.assembly.snapshot.status == .complete && stream.assembly.snapshot.containsOpaqueCompaction, "context compaction permits absent encrypted body")
        }
        for item: [String: Any] in [
            ["type": "compaction"], ["type": "compaction_summary", "encrypted_content": NSNull()],
            ["type": "context_compaction", "encrypted_content": 123],
            ["type": "compaction", "encrypted_content": "x", "id": 7],
            ["type": "message", "role": "assistant", "content": []],
        ] {
            let stream = ResponsesAssemblyTests.Stream(); try stream.start(); try stream.complete([item])
            check(stream.assembly.snapshot.status == .incomplete && stream.assembly.snapshot.failure == .invalidEvent, "invalid compaction metadata or absent ordinary ID fails closed")
            check(CompactionProjection.project(stream.assembly.snapshot, classification: codex, transportComplete: true)?.availability == .incomplete, "malformed output is not successful compaction")
        }
        let opaque: [String: Any] = ["type": "compaction", "encrypted_content": "PRIVATE_CIPHERTEXT"]
        let mixed = ResponsesAssemblyTests.Stream(); try mixed.start()
        try mixed.complete([ResponsesAssemblyTests.message("m", "not documented as the summary"), opaque])
        check(CompactionProjection.project(mixed.assembly.snapshot, classification: codex, transportComplete: true)?.text == nil, "opaque control cannot use unrelated visible output as invented plaintext summary")
        let multiple = ResponsesAssemblyTests.Stream(); try multiple.start(); try multiple.complete([opaque, opaque])
        check(multiple.assembly.snapshot.status == .complete, "absent control IDs are not synthesized or conflated")
        let duplicate = ResponsesAssemblyTests.Stream(); try duplicate.start()
        try duplicate.complete([["type": "compaction", "id": "same", "encrypted_content": "x"], ResponsesAssemblyTests.message("same", "x")])
        check(duplicate.assembly.snapshot.failure == .unexpectedSequence, "explicit duplicate item IDs still rejected")
        let authoritative = ResponsesAssemblyTests.Stream(); try authoritative.start(); try authoritative.item(0, opaque)
        try authoritative.complete([ResponsesAssemblyTests.message("m", "actual plaintext summary")])
        check(!authoritative.assembly.snapshot.containsOpaqueCompaction, "authoritative final output replaces earlier control evidence")
        check(CompactionProjection.project(authoritative.assembly.snapshot, classification: codex, transportComplete: true)?.text == "actual plaintext summary", "Responses text-only compaction can expose its actual response text")
        let bound = ResponsesAssemblyTests.Stream(); try bound.start(); try bound.complete(Array(repeating: opaque, count: 65))
        check(bound.assembly.snapshot.failure == .resourceLimit, "opaque items count toward bounded assembly")
        let empty = ResponsesAssemblyTests.Stream(); try empty.start(); try empty.complete([])
        let missing = CompactionProjection.project(empty.assembly.snapshot, classification: codex, transportComplete: true)
        check(missing?.availability == .noText && missing?.text == nil, "empty summary is distinct from encrypted and failed compaction")
        let cutoff = AnthropicResponseTests.Stream(); try cutoff.start()
        let full = String(repeating: "a", count: ConversationCaptureLimits.assistantText - 3)
        try cutoff.block(0, ["type": "text", "text": full]); try cutoff.stop(0)
        try cutoff.block(1, ["type": "text", "text": "한"]); try cutoff.stop(1); try cutoff.complete()
        let bounded = CompactionProjection.project(cutoff.assembly.snapshot, classification: claude, transportComplete: true)
        check(bounded?.text == full && bounded?.truncated == true, "summary separators count toward byte cap and cannot split Korean scalar")
        let exact = AnthropicResponseTests.Stream(); try exact.start()
        try exact.block(0, ["type": "text", "text": String(repeating: "a", count: ConversationCaptureLimits.assistantText)]); try exact.stop(0); try exact.complete()
        let exactResult = CompactionProjection.project(exact.assembly.snapshot, classification: claude, transportComplete: true)
        check(exactResult?.text?.utf8.count == ConversationCaptureLimits.assistantText && exactResult?.truncated == false, "exact summary byte limit accepted")
    }
}
