import Foundation

/// Provider-neutral request history, before session identity, deduplication or
/// storage. No request headers, system instructions, thinking, image bytes or
/// arbitrary provider objects are retained in these values.
public nonisolated struct CapturedBlock: Equatable, Sendable {
    public enum Kind: String, Sendable { case text, toolCall, toolResult, image }
    public let kind: Kind
    public let text: String
    public let callID: String?
    public let toolName: String?
}

public nonisolated struct CapturedMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant, tool }
    public let role: Role
    public let blocks: [CapturedBlock]
    public let truncated: Bool

    /// Conservative accounting units for retained fields and bounded object
    /// counts, not an assertion about Swift allocator or process RSS.
    var cost: Int {
        256 + blocks.reduce(0) { $0 + 256 + $1.text.utf8.count + ($1.callID?.utf8.count ?? 0) + ($1.toolName?.utf8.count ?? 0) }
    }
}

public nonisolated struct CapturedRequest: Equatable, Sendable {
    public let messages: [CapturedMessage]
    public let truncated: Bool
    /// A Responses request may contain only the new input, not full history.
    /// The store must not treat such a request as a replacement transcript.
    public let previousResponseID: String?
}

public nonisolated enum RequestProjection {
    public enum Provider: Sendable { case anthropic, responses }
    public enum Failure: Error, Equatable { case invalidJSON, unsupportedShape, resourceLimit }

    public static func project(_ body: Data, provider: Provider,
                               maximumBodyBytes: Int = ConversationCaptureLimits.decompressedRequest) throws -> CapturedRequest {
        guard maximumBodyBytes >= 0, body.count <= min(maximumBodyBytes, ConversationCaptureLimits.decompressedRequest) else {
            throw Failure.resourceLimit
        }
        try checkJSONStructure(body)
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw Failure.unsupportedShape }
            object = value
        } catch let failure as Failure { throw failure }
        catch { throw Failure.invalidJSON }
        let items: [Any]
        var previous: String?
        switch provider {
        case .anthropic:
            guard let messages = object["messages"] as? [Any] else { throw Failure.unsupportedShape }
            items = messages
        case .responses:
            if let value = object["previous_response_id"], !(value is NSNull) {
                guard let id = identifier(value) else { throw Failure.unsupportedShape }
                previous = id
            }
            if let input = object["input"] as? String { items = [["role": "user", "content": input]] }
            else if let input = object["input"] as? [Any] { items = input }
            else { throw Failure.unsupportedShape }
        }
        var messages: [CapturedMessage] = []
        var cost = 0
        var truncated = false
        // Keep the most recent visible history, rather than letting old
        // system-only or reasoning items consume the 200-message allowance.
        for item in items.reversed() {
            guard let value = item as? [String: Any] else { truncated = true; continue }
            let projection = message(value, provider: provider)
            truncated = truncated || projection.incomplete
            guard let message = projection.message else { continue }
            guard messages.count < ConversationCaptureLimits.reconstructedHistoryItems,
                  message.cost <= ConversationCaptureLimits.conversation - cost else {
                truncated = true
                break
            }
            messages.append(message)
            cost += message.cost
        }
        return CapturedRequest(messages: Array(messages.reversed()), truncated: truncated, previousResponseID: previous)
    }

    /// Bound the JSON parser's nesting and object overhead before Foundation
    /// materializes an untrusted tree. This scanner is not a JSON validator;
    /// syntax and UTF-8 validation are still Foundation's responsibility.
    private static func checkJSONStructure(_ body: Data) throws {
        var inString = false, escaped = false
        var depth = 0, tokens = 0
        for byte in body {
            // Reject UTF-16/32 and literal NUL, not the valid JSON escape \u0000.
            if byte == 0 { throw Failure.invalidJSON }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34: inString = true; tokens += 1
            case 123, 91: depth += 1; tokens += 1
            case 125, 93: depth -= 1
            case 44, 58: tokens += 1
            default: break
            }
            guard depth <= 64, tokens <= 100_000 else { throw Failure.resourceLimit }
        }
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func message(_ value: [String: Any], provider: Provider) -> (message: CapturedMessage?, incomplete: Bool) {
        let type = value["type"] as? String ?? "message"
        if ["reasoning", "compaction"].contains(type) { return (nil, type == "compaction") }
        let role: CapturedMessage.Role
        let parts: [Any]
        if provider == .responses && type == "function_call" {
            role = .assistant
            parts = [["type": "tool_use", "id": value["call_id"] ?? NSNull(), "name": value["name"] ?? NSNull(),
                      "arguments": value["arguments"] ?? NSNull()]]
        } else if provider == .responses && type == "function_call_output" {
            role = .tool
            parts = [["type": "tool_result", "tool_use_id": value["call_id"] ?? NSNull(),
                      "content": value["output"] ?? NSNull()]]
        } else {
            let rawRole = value["role"] as? String
            if rawRole == "system" || rawRole == "developer" { return (nil, false) }
            guard type == "message", let rawRole, let parsed = CapturedMessage.Role(rawValue: rawRole), parsed != .tool else { return (nil, true) }
            role = parsed
            if let text = value["content"] as? String { parts = [["type": "text", "text": text]] }
            else if let content = value["content"] as? [Any] { parts = content }
            else { return (nil, true) }
        }
        var remaining = role == .assistant ? ConversationCaptureLimits.assistantText :
            (role == .tool ? ConversationCaptureLimits.toolText : ConversationCaptureLimits.userText)
        var blocks: [CapturedBlock] = []
        var truncated = false
        for part in parts {
            guard blocks.count < 64 else { truncated = true; break }
            guard let part = part as? [String: Any], let kind = part["type"] as? String else { truncated = true; continue }
            switch kind {
            case "thinking", "redacted_thinking", "reasoning", "reasoning_text": continue
            case "image", "input_image", "output_image":
                blocks.append(.init(kind: .image, text: "", callID: nil, toolName: nil))
            case "text", "input_text", "output_text", "refusal":
                guard let text = (part["text"] ?? part["refusal"]) as? String else { truncated = true; continue }
                let visible = VisibleRequestText.project(text, maximumBytes: remaining, stripMetadata: role == .user)
                truncated = truncated || visible.truncated
                if !visible.text.isEmpty {
                    remaining -= visible.text.utf8.count
                    blocks.append(.init(kind: .text, text: visible.text, callID: nil, toolName: nil))
                }
            case "tool_use":
                guard let id = identifier(part["id"]), let name = identifier(part["name"]) else { truncated = true; continue }
                let text: String
                if let arguments = part["arguments"] as? String { text = arguments }
                else if let input = part["input"], JSONSerialization.isValidJSONObject(input),
                        let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                        let encoded = CaptureUTF8.decode(data) { text = encoded }
                else { truncated = true; continue }
                let bounded = VisibleRequestText.project(text, maximumBytes: min(remaining, ConversationCaptureLimits.toolText), stripMetadata: false)
                remaining -= bounded.text.utf8.count
                truncated = truncated || bounded.truncated
                blocks.append(.init(kind: .toolCall, text: bounded.text, callID: id, toolName: name))
            case "tool_result":
                guard let id = identifier(part["tool_use_id"]) else { truncated = true; continue }
                let text: String
                if let content = part["content"] as? String { text = content }
                else if let content = part["content"] as? [[String: Any]] {
                    // Never stringify an image/base64 or thinking object into
                    // a tool result. Unknown parts are explicitly incomplete.
                    var pieces: [String] = []
                    var bytes = 0
                    for entry in content.prefix(64) {
                        if ["image", "input_image", "output_image"].contains(entry["type"] as? String ?? "") { pieces.append("[Image]"); bytes += 7 }
                        else if entry["type"] as? String == "text", let s = entry["text"] as? String {
                            let bounded = ConversationCaptureLimits.textPrefix(s, maximumBytes: max(0, ConversationCaptureLimits.toolText - bytes))
                            truncated = truncated || bounded.utf8.count < s.utf8.count
                            pieces.append(bounded); bytes += bounded.utf8.count + 1
                        } else { truncated = true }
                        if bytes >= ConversationCaptureLimits.toolText { truncated = true; break }
                    }
                    if content.count > 64 { truncated = true }
                    text = pieces.joined(separator: "\n")
                } else { truncated = true; continue }
                let bounded = VisibleRequestText.project(text, maximumBytes: min(remaining, ConversationCaptureLimits.toolText), stripMetadata: false)
                remaining -= bounded.text.utf8.count
                truncated = truncated || bounded.truncated
                blocks.append(.init(kind: .toolResult, text: bounded.text, callID: id, toolName: nil))
            default: truncated = true
            }
        }
        guard !blocks.isEmpty else { return (nil, truncated) }
        return (CapturedMessage(role: role, blocks: blocks, truncated: truncated), truncated)
    }
}

/// Remove only recognized, exact metadata wrappers in user input. Nested
/// wrappers are handled with a stack; an unclosed wrapper hides its remainder.
/// Assistant output and tool output are not run through this display filter.
private nonisolated enum VisibleRequestText {
    static let tags = ["system-reminder", "environment_context", "command-name", "command-message", "command-args", "local-command-stdout", "local-command-stderr"]

    static func project(_ text: String, maximumBytes: Int, stripMetadata: Bool) -> (text: String, truncated: Bool) {
        if !stripMetadata {
            let prefix = ConversationCaptureLimits.textPrefix(text, maximumBytes: maximumBytes)
            return (prefix, prefix.utf8.count < text.utf8.count)
        }
        var output = "", stack: [String] = []
        var cursor = text.startIndex
        var truncated = false
        var delimiters = 0
        func appendVisible(_ segment: Substring) {
            let room = maximumBytes - output.utf8.count
            var bytes = Array(segment.utf8.prefix(room))
            while CaptureUTF8.decode(bytes) == nil { bytes.removeLast() }
            let value = CaptureUTF8.decode(bytes) ?? ""
            output += value
            truncated = truncated || value.utf8.count < segment.utf8.count
        }
        while cursor < text.endIndex {
            // Never stitch a later segment onto a prefix that already lost a
            // scalar. Also bound work on hostile delimiter-heavy metadata.
            if truncated || output.utf8.count == maximumBytes { return (output, true) }
            guard let opening = text[cursor...].firstIndex(of: "<") else {
                if stack.isEmpty { appendVisible(text[cursor...]) }
                break
            }
            delimiters += 1
            guard delimiters <= 4_096 else { return (output, true) }
            if stack.isEmpty { appendVisible(text[cursor..<opening]) }
            if truncated { return (output, true) }
            var matched = false
            for tag in tags {
                let open = "<\(tag)>", close = "</\(tag)>"
                if text[opening...].hasPrefix(open) {
                    guard stack.count < 64 else { return (output, true) }
                    stack.append(tag)
                    cursor = text.index(opening, offsetBy: open.count)
                    matched = true; break
                }
                if text[opening...].hasPrefix(close), stack.last == tag {
                    stack.removeLast()
                    cursor = text.index(opening, offsetBy: close.count)
                    matched = true; break
                }
            }
            if !matched {
                let next = text.index(after: opening)
                if stack.isEmpty { appendVisible(text[opening..<next]) }
                cursor = next
            }
        }
        return (output, truncated)
    }
}
