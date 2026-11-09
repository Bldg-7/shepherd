import Foundation

public nonisolated struct AgentSessionReference: Equatable, Sendable {
    public enum Kind: String, Sendable { case id, path }
    public let source: String
    public let agent: String
    public let kind: Kind
    public let value: String

    public init?(json: JSONValue) {
        guard let source = json["source"]?.stringValue, let agent = json["agent"]?.stringValue,
              let rawKind = json["kind"]?.stringValue, let kind = Kind(rawValue: rawKind),
              let value = json["value"]?.stringValue else { return nil }
        self.source = source; self.agent = agent; self.kind = kind; self.value = value
    }

    /// Read-only conversation matching, not permission to resume or open a
    /// file. Pi's authenticated app report uses <timestamp>_<session UUID>.jsonl
    /// (PiHostBridge.matches verifies that suffix against the launch ID). Match
    /// the already-reported metadata only; never read a transcript's contents.
    public func conversationID(for expected: AgentKind) -> String? {
        guard AgentKind(herdrName: agent) == expected, !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if kind == .id { return value.utf8.count <= 256 ? value : nil }
        guard expected == .pi, value.hasPrefix("/"), value.utf8.count <= 4096 else { return nil }
        let filename = (value as NSString).lastPathComponent
        guard filename.hasSuffix(".jsonl"), let split = filename.lastIndex(of: "_") else { return nil }
        let id = String(filename[filename.index(after: split)...].dropLast(6))
        guard UUID(uuidString: id) != nil else { return nil }
        return id // Preserve exact bytes; do not normalize opaque identity.
    }

    public func resumeID(for expected: AgentKind) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard expected.supportsLegacySessionInspection, kind == .id, AgentKind(herdrName: agent) == expected, !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}

nonisolated extension AgentKind {
    public init?(herdrName: String) {
        switch herdrName {
        case "claude", "claude-code": self = .claude
        case "codex": self = .codex
        case "pi": self = .pi
        default: return nil
        }
    }
}
