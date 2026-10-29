import Foundation
import CoreFoundation

/// One OpenAI Responses SSE exchange. Deltas provide the live view; done
/// events and response.completed replace matching content instead of appending
/// it again. A valid final output snapshot is authoritative, but an HTTP/tee
/// abort can still make the exchange incomplete in finish().
///
/// Only text/refusal, function arguments and image placeholders are retained.
/// Reasoning/encrypted content, annotations, raw events and provider error text
/// are never stored. At most 64 items, 64 content blocks and 256 KiB of visible
/// text are retained, with a 16-KiB limit for each function's arguments.
public nonisolated struct ResponsesAssembly: Sendable {
    private struct Block: Sendable {
        let kind: CapturedBlock.Kind?
        let wireType: String
        let callID: String?
        let name: String?
        var text = ""
        var done = false
        var truncated = false
    }
    private struct Item: Sendable {
        let id: String?
        let type: String
        var blocks: [Int: Block] = [:]
        var done = false
    }
    private var items: [Int: Item] = [:]
    private var bytes = 0
    private var blockCount = 0
    private var started = false
    private var closed = false
    private var responseID: String?
    private var status: CapturedResponse.Status = .streaming
    private var failure: CapturedResponse.Failure?
    private var truncated = false
    private var finalAnswer = false

    public init() {}

    public var snapshot: CapturedResponse {
        let blocks = items.keys.sorted().flatMap { index -> [CapturedBlock] in
            let item = items[index]!
            return item.blocks.keys.sorted().compactMap { part in
                let block = item.blocks[part]!
                guard let kind = block.kind else { return nil }
                return CapturedBlock(kind: kind, text: block.text, callID: block.callID, toolName: block.name)
            }
        }
        return CapturedResponse(responseID: responseID, blocks: blocks, status: status,
                                truncated: truncated, failure: failure,
                                containsOpaqueCompaction: items.values.contains { CompactionProjection.isOpaqueItem($0.type) },
                                isFinalAnswer: status == .complete && finalAnswer && !blocks.contains(where: { $0.kind == .toolCall }))
    }

    public mutating func consume(_ event: ServerSentEvent) {
        guard !closed, status == .streaming else { return }
        // [DONE] alone does not prove a Responses response completed.
        if event.data == "[DONE]" { fail(.unexpectedSequence); return }
        guard event.data.utf8.count <= 2 << 20 else { fail(.resourceLimit); return }
        let object: [String: Any]
        do { object = try RequestProjection.decodeObject(Data(event.data.utf8)) }
        catch { fail(.invalidEvent); return }
        guard let type = object["type"] as? String,
              event.name == "message" || event.name == type else { fail(.invalidEvent); return }
        if ["error", "response.failed", "response.incomplete"].contains(type) { fail(.providerError); return }
        if type == "response.created" {
            guard !started, let response = object["response"] as? [String: Any],
                  let id = RequestProjection.identifier(response["id"]) else { fail(.unexpectedSequence); return }
            started = true; responseID = id
            return
        }
        guard started else { fail(.unexpectedSequence); return }
        if type.hasPrefix("response.reasoning_") { return }
        switch type {
        case "response.in_progress":
            guard let response = object["response"] as? [String: Any], response["id"] as? String == responseID else {
                fail(.unexpectedSequence); return
            }
        case "response.output_item.added", "response.output_item.done":
            guard let index = Self.index(object["output_index"]), let item = object["item"] as? [String: Any] else {
                fail(.invalidEvent); return
            }
            let done = type.hasSuffix(".done")
            guard done ? items[index] != nil : items[index] == nil else { fail(.unexpectedSequence); return }
            _ = install(item, at: index, done: done)
        case "response.content_part.added", "response.content_part.done":
            guard let position = position(object), items[position.item]?.type == "message",
                  let part = object["part"] as? [String: Any] else { fail(.unexpectedSequence); return }
            let done = type.hasSuffix(".done")
            guard done ? items[position.item]?.blocks[position.part] != nil : items[position.item]?.blocks[position.part] == nil else {
                fail(.unexpectedSequence); return
            }
            _ = installPart(part, item: position.item, part: position.part, done: done)
        case "response.output_text.delta", "response.refusal.delta", "response.function_call_arguments.delta",
             "response.output_text.done", "response.refusal.done", "response.function_call_arguments.done":
            let arguments = type.hasPrefix("response.function_call_arguments.")
            guard let position = position(object, arguments: arguments), let block = items[position.item]?.blocks[position.part] else {
                fail(.unexpectedSequence); return
            }
            let wireType = arguments ? "arguments" : (type.hasPrefix("response.refusal.") ? "refusal" : "output_text")
            guard block.wireType == wireType else { fail(.unexpectedSequence); return }
            let done = type.hasSuffix(".done")
            guard done || !block.done else { fail(.unexpectedSequence); return }
            let field = done ? (arguments ? "arguments" : (wireType == "refusal" ? "refusal" : "text")) : "delta"
            guard let text = object[field] as? String else { fail(.invalidEvent); return }
            setText(text, item: position.item, part: position.part, replace: done)
            if done {
                items[position.item]?.blocks[position.part]?.done = true
                if arguments { validateArguments(item: position.item) }
            }
        case "response.completed":
            guard let response = object["response"] as? [String: Any], response["id"] as? String == responseID,
                  response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else {
                fail(.invalidEvent); return
            }
            guard output.count <= 64 else { fail(.resourceLimit); return }
            // Do not expose a partially replaced final snapshot on failure.
            var final = ResponsesAssembly()
            final.started = true; final.responseID = responseID; final.truncated = truncated
            for (index, item) in output.enumerated() {
                guard final.install(item, at: index, done: true) else { fail(final.failure ?? .invalidEvent); return }
            }
            final.status = .complete
            // Codex's explicit final_answer phase is stronger than HTTP/SSE
            // completion. Commentary/tool/compaction turns are not child results.
            final.finalAnswer = output.allSatisfy { ["message", "reasoning"].contains($0["type"] as? String ?? "") }
                && output.contains { $0["type"] as? String == "message" && $0["role"] as? String == "assistant" && $0["phase"] as? String == "final_answer" }
            self = final
        default:
            // Annotations and response metadata do not change visible text.
            // Other future semantics are not silently advertised as a fully
            // reconstructed view.
            if !["response.output_text.annotation.added", "response.metadata"].contains(type) { truncated = true }
        }
    }

    public mutating func finish(transportComplete: Bool) {
        guard !closed else { return }
        closed = true
        if !transportComplete || status != .complete {
            status = .incomplete
            if failure == nil { failure = .transportIncomplete }
        }
    }

    private mutating func fail(_ reason: CapturedResponse.Failure) {
        failure = reason; status = .incomplete; closed = true
    }

    private func position(_ object: [String: Any], arguments: Bool = false) -> (item: Int, part: Int)? {
        guard let index = Self.index(object["output_index"]), let item = items[index], !item.done,
              let id = object["item_id"] as? String, id == item.id,
              let part = arguments ? 0 : Self.index(object["content_index"]) else { return nil }
        if arguments && item.type != "function_call" { return nil }
        return (index, part)
    }

    @discardableResult
    private mutating func install(_ object: [String: Any], at index: Int, done: Bool) -> Bool {
        guard let type = object["type"] as? String, type.utf8.count <= 128 else { fail(.invalidEvent); return false }
        let opaque = CompactionProjection.isOpaqueItem(type)
        let id = RequestProjection.identifier(object["id"])
        // Codex 0.162.1 makes the id optional for these control items only.
        // Do not synthesize an ID that could collide with a provider item ID.
        let absentID = object["id"] == nil || object["id"] is NSNull
        guard id != nil || (opaque && absentID) else { fail(.invalidEvent); return false }
        if opaque {
            let encrypted = object["encrypted_content"]
            let absent = encrypted == nil || encrypted is NSNull
            guard encrypted is String || (type == "context_compaction" && absent) else {
                fail(.invalidEvent); return false
            }
        }
        if let old = items[index] {
            guard old.id == id && old.type == type else { fail(.unexpectedSequence); return false }
            bytes -= old.blocks.values.reduce(0) { $0 + $1.text.utf8.count }
            blockCount -= old.blocks.count
        } else {
            guard items.count < 64 else { fail(.resourceLimit); return false }
            if let id, items.values.contains(where: { $0.id == id }) { fail(.unexpectedSequence); return false }
        }
        items[index] = Item(id: id, type: type)
        switch type {
        case "message":
            guard object["role"] as? String == "assistant", let content = object["content"] as? [[String: Any]], content.count <= 64 else {
                fail(.invalidEvent); return false
            }
            for (part, value) in content.enumerated() {
                guard installPart(value, item: index, part: part, done: done) else { return false }
            }
        case "function_call":
            guard let call = RequestProjection.identifier(object["call_id"]), let name = RequestProjection.identifier(object["name"]),
                  let text = object["arguments"] as? String else { fail(.invalidEvent); return false }
            guard !items.values.contains(where: { $0.id != id && $0.blocks.values.contains(where: { $0.callID == call }) }) else {
                fail(.unexpectedSequence); return false
            }
            guard reserveBlock() else { return false }
            items[index]?.blocks[0] = Block(kind: .toolCall, wireType: "arguments", callID: call, name: name, done: done)
            setText(text, item: index, part: 0, replace: true)
            if done { validateArguments(item: index) }
        case "reasoning", "compaction", "compaction_summary", "context_compaction": break
        case "image_generation_call":
            guard reserveBlock() else { return false }
            items[index]?.blocks[0] = Block(kind: .image, wireType: "image", callID: nil, name: nil, done: done)
        default: truncated = true
        }
        items[index]?.done = done
        return failure == nil
    }

    private mutating func installPart(_ object: [String: Any], item: Int, part: Int, done: Bool) -> Bool {
        guard let type = object["type"] as? String, type.utf8.count <= 128 else { fail(.invalidEvent); return false }
        if let old = items[item]?.blocks[part] {
            guard old.wireType == type else { fail(.unexpectedSequence); return false }
            bytes -= old.text.utf8.count
        } else if !reserveBlock() { return false }
        let kind: CapturedBlock.Kind?
        let text: String
        switch type {
        case "output_text", "refusal":
            guard let value = object[type == "refusal" ? "refusal" : "text"] as? String else { fail(.invalidEvent); return false }
            kind = .text; text = value
        case "output_image": kind = .image; text = ""
        case "reasoning_text": kind = nil; text = ""
        default: kind = nil; text = ""; truncated = true
        }
        items[item]?.blocks[part] = Block(kind: kind, wireType: type, callID: nil, name: nil, done: done)
        setText(text, item: item, part: part, replace: true)
        return true
    }

    private mutating func reserveBlock() -> Bool {
        guard blockCount < 64 else { fail(.resourceLimit); return false }
        blockCount += 1
        return true
    }

    private mutating func setText(_ text: String, item: Int, part: Int, replace: Bool) {
        guard var block = items[item]?.blocks[part] else { return }
        if !replace && block.truncated { return }
        if replace { bytes -= block.text.utf8.count; block.text = "" }
        let cap = block.kind == .toolCall ? ConversationCaptureLimits.toolText : ConversationCaptureLimits.assistantText
        let room = min(cap - block.text.utf8.count, ConversationCaptureLimits.assistantText - bytes)
        let prefix = ConversationCaptureLimits.textPrefix(text, maximumBytes: max(0, room))
        block.text += prefix; bytes += prefix.utf8.count
        if prefix.utf8.count < text.utf8.count { block.truncated = true; truncated = true }
        items[item]?.blocks[part] = block
    }

    private mutating func validateArguments(item: Int) {
        guard let block = items[item]?.blocks[0], !block.truncated else { return }
        do { _ = try RequestProjection.decodeObject(Data(block.text.utf8)) }
        catch { fail(.invalidEvent) }
    }

    private static func index(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= 1_000_000,
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
}
