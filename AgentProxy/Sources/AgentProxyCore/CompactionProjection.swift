import Foundation

/// A compaction response, not a replacement main transcript. The recorder must
/// still resolve its verified owner and append a typed boundary to that owner's
/// existing history. A missing summary never authorizes reading transcript files.
public nonisolated struct CapturedCompaction: Equatable, Sendable {
    public enum Availability: Sendable { case plaintext, opaque, noText, incomplete }
    public let availability: Availability
    public let text: String?
    public let truncated: Bool
    public let status: CapturedResponse.Status
}

public nonisolated enum CompactionProjection {
    // Codex rust-v0.162.1 protocol/src/models.rs. compaction_summary is the
    // serde alias of Compaction; ContextCompaction permits no encrypted body.
    static func isOpaqueItem(_ type: String) -> Bool {
        ["compaction", "compaction_summary", "context_compaction"].contains(type)
    }

    /// Invoke at exchange end, after semantic assembly. Only a verified
    /// compaction class can produce a summary. Even a provider completion is
    /// incomplete when the tee reports an abort/drop. Failed/partial summaries
    /// are not published as successfully compacted history.
    ///
    /// Opaque control output takes precedence over ordinary output text: those
    /// text items are not a documented plaintext representation of the control
    /// item. Never guess from a "summary" field or stringify unknown objects.
    public static func project(_ response: CapturedResponse, classification: ClassifiedRequest,
                               transportComplete: Bool) -> CapturedCompaction? {
        guard classification.kind == .compaction else { return nil }
        guard transportComplete, response.status == .complete, response.failure == nil else {
            return CapturedCompaction(availability: .incomplete, text: nil,
                                      truncated: response.truncated, status: .incomplete)
        }
        if response.containsOpaqueCompaction {
            return CapturedCompaction(availability: .opaque, text: nil,
                                      truncated: response.truncated, status: .complete)
        }
        var text = ""
        var truncated = response.truncated
        for block in response.blocks where block.kind == .text && !block.text.isEmpty {
            let separator = text.isEmpty ? "" : "\n\n"
            let remaining = ConversationCaptureLimits.assistantText - text.utf8.count
            // Account for separators too. Prefixing cannot split a UTF-8 scalar.
            guard remaining >= separator.utf8.count else { truncated = true; break }
            let prefix = ConversationCaptureLimits.textPrefix(block.text, maximumBytes: remaining - separator.utf8.count)
            if prefix.isEmpty { truncated = true; break }
            text += separator + prefix
            if prefix.utf8.count < block.text.utf8.count { truncated = true; break }
        }
        return CapturedCompaction(availability: text.isEmpty ? .noText : .plaintext,
                                  text: text.isEmpty ? nil : text, truncated: truncated, status: .complete)
    }
}
