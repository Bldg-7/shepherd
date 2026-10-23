import Foundation
import CoreFoundation

public nonisolated struct CapturedResponse: Equatable, Sendable {
    public enum Status: Sendable { case streaming, complete, incomplete }
    public enum Failure: Sendable {
        case invalidEvent, unexpectedSequence, resourceLimit, providerError, transportIncomplete
    }
    public let responseID: String?
    public let blocks: [CapturedBlock]
    public let status: Status
    public let truncated: Bool
    public let failure: Failure?
}

/// Semantic assembly of one Anthropic Messages SSE response. Never stores
/// thinking/signatures, image bytes, raw events, usage or provider error text.
/// All retained visible text shares a 256-KiB response budget; each tool input
/// is additionally limited to 16 KiB. The 64-entry limit includes hidden blocks.
///
/// Feed only decompressed SSE events, then always call finish() with the tee's
/// transport outcome. A provider message_stop cannot make an aborted exchange
/// look complete. This value is not a conversation store or a stream subscriber.
public nonisolated struct AnthropicResponseAssembly: Sendable {
    private struct Entry: Sendable {
        var kind: CapturedBlock.Kind?
        var text: String
        let callID: String?
        let toolName: String?
        var stopped = false
        var truncated = false
        var awaitingArguments = false
        var acceptsArgumentDeltas = false
    }
    private var entries: [Int: Entry] = [:]
    private var started = false
    private var closed = false
    private var bytes = 0
    private var responseID: String?
    private var status: CapturedResponse.Status = .streaming
    private var failure: CapturedResponse.Failure?
    private var truncated = false

    public init() {}

    public var snapshot: CapturedResponse {
        let blocks = entries.keys.sorted().compactMap { index -> CapturedBlock? in
            guard let entry = entries[index], let kind = entry.kind else { return nil }
            return CapturedBlock(kind: kind, text: entry.text, callID: entry.callID, toolName: entry.toolName)
        }
        return CapturedResponse(responseID: responseID, blocks: blocks, status: status,
                                truncated: truncated, failure: failure)
    }

    public mutating func consume(_ event: ServerSentEvent) {
        guard !closed, status == .streaming else { return }
        guard event.data.utf8.count <= 2 << 20 else { fail(.resourceLimit); return }
        let object: [String: Any]
        do { object = try RequestProjection.decodeObject(Data(event.data.utf8)) }
        catch { fail(.invalidEvent); return }
        guard let type = object["type"] as? String,
              event.name == "message" || event.name == type else { fail(.invalidEvent); return }
        if type == "ping" { return }
        if type == "error" { fail(.providerError); return }
        if type == "message_start" {
            guard !started, let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let id = RequestProjection.identifier(message["id"]),
                  let content = message["content"] as? [Any], content.isEmpty else { fail(.unexpectedSequence); return }
            started = true
            responseID = id
            return
        }
        guard started else { fail(.unexpectedSequence); return }
        switch type {
        case "content_block_start":
            guard let index = Self.index(object["index"]), entries[index] == nil,
                  let block = object["content_block"] as? [String: Any], let kind = block["type"] as? String else {
                fail(.unexpectedSequence); return
            }
            guard entries.count < 64 else { fail(.resourceLimit); return }
            switch kind {
            case "text":
                guard let text = block["text"] as? String else { fail(.invalidEvent); return }
                entries[index] = Entry(kind: .text, text: "", callID: nil, toolName: nil)
                append(text, at: index)
            case "tool_use":
                guard let id = RequestProjection.identifier(block["id"]), let name = RequestProjection.identifier(block["name"]),
                      let input = block["input"] as? [String: Any], JSONSerialization.isValidJSONObject(input),
                      let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                      let text = CaptureUTF8.decode(data) else { fail(.invalidEvent); return }
                entries[index] = Entry(kind: .toolCall, text: "", callID: id, toolName: name,
                                       awaitingArguments: input.isEmpty, acceptsArgumentDeltas: input.isEmpty)
                append(text, at: index)
            case "thinking", "redacted_thinking":
                entries[index] = Entry(kind: nil, text: "", callID: nil, toolName: nil)
            case "image":
                entries[index] = Entry(kind: .image, text: "", callID: nil, toolName: nil)
            default:
                // Future block kinds must not accidentally be exposed as text.
                entries[index] = Entry(kind: nil, text: "", callID: nil, toolName: nil)
                truncated = true
            }
        case "content_block_delta":
            guard let index = Self.index(object["index"]), var entry = entries[index], !entry.stopped,
                  let delta = object["delta"] as? [String: Any], let kind = delta["type"] as? String else {
                fail(.unexpectedSequence); return
            }
            if entry.kind == nil { return }
            if kind == "citations_delta", entry.kind == .text { return }
            if entry.kind == .text, kind == "text_delta", let text = delta["text"] as? String {
                append(text, at: index)
            } else if entry.kind == .toolCall, kind == "input_json_delta", let text = delta["partial_json"] as? String {
                guard entry.acceptsArgumentDeltas else { fail(.unexpectedSequence); return }
                if entry.awaitingArguments {
                    // The empty {} in tool_use is a placeholder, not the first
                    // fragment of streamed arguments. Replace it exactly once.
                    bytes -= entry.text.utf8.count
                    entry.text = ""
                    entry.awaitingArguments = false
                    entries[index] = entry
                }
                append(text, at: index)
            } else { fail(.invalidEvent) }
        case "content_block_stop":
            guard let index = Self.index(object["index"]), var entry = entries[index], !entry.stopped else {
                fail(.unexpectedSequence); return
            }
            if entry.kind == .toolCall && !entry.truncated {
                do { _ = try RequestProjection.decodeObject(Data(entry.text.utf8)) }
                catch { fail(.invalidEvent); return }
            }
            entry.stopped = true
            entries[index] = entry
        case "message_delta":
            // Usage and stop_reason are not transcript content.
            break
        case "message_stop":
            guard entries.values.allSatisfy(\.stopped) else { fail(.unexpectedSequence); return }
            status = .complete
        default:
            // Unknown events may contain semantics the projection cannot show.
            // Keep the stream viable but explicitly mark the view incomplete.
            truncated = true
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
        failure = reason
        status = .incomplete
        closed = true
    }

    private mutating func append(_ text: String, at index: Int) {
        guard var entry = entries[index], !entry.truncated else { return }
        let perBlock = entry.kind == .toolCall ? ConversationCaptureLimits.toolText : ConversationCaptureLimits.assistantText
        let room = min(perBlock - entry.text.utf8.count, ConversationCaptureLimits.assistantText - bytes)
        let prefix = ConversationCaptureLimits.textPrefix(text, maximumBytes: max(0, room))
        entry.text += prefix
        bytes += prefix.utf8.count
        if prefix.utf8.count < text.utf8.count { entry.truncated = true; truncated = true }
        entries[index] = entry
    }

    private static func index(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= 1_000_000,
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
}
