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

public nonisolated struct AgentStartResult: Sendable {
    public let agent: AgentSummary
    /// May contain user instructions; never log this value.
    public let arguments: [String]
}

public nonisolated struct PaneProcessInfo: Decodable, Sendable {
    public struct ForegroundProcess: Decodable, Equatable, Sendable {
        public let pid: UInt32
        public let name: String
        /// Absent/null means unknown, not missing injection.
        public let argv: [String]?
        public let argv0: String?
        public enum CodingKeys: String, CodingKey { case pid, name, argv, argv0 }
    }
    public let paneID: String
    public let shellPID: UInt32?
    public let foregroundProcessGroupID: UInt32?
    public let tty: String?
    public let foregroundProcesses: [ForegroundProcess]
    public enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", shellPID = "shell_pid"
        case foregroundProcessGroupID = "foreground_process_group_id", foregroundProcesses = "foreground_processes", tty
    }

    public func agentArguments(for kind: AgentKind) -> [String]? {
        guard let argv = agentProcess(for: kind)?.argv, let first = argv.first, !first.isEmpty else { return nil }
        return argv
    }

    /// The one foreground process of `kind`, or nil if there is none or more than one.
    public func agentProcess(for kind: AgentKind) -> ForegroundProcess? {
        // Pi always uses the native process/session bridge. Enabling its
        // launcher does not make a process name or copied argv an identity proof.
        guard kind.supportsLegacySessionInspection else { return nil }
        let matching = foregroundProcesses.filter {
            AgentKind(herdrName: $0.name) == kind || $0.argv0.map { AgentKind(herdrName: Self.commandName($0)) == kind } == true ||
            $0.argv?.first.map { AgentKind(herdrName: Self.commandName($0)) == kind } == true
        }
        guard matching.count == 1 else { return nil }
        return matching[0]
    }

    /// The last component of argv0, from the text alone. A URL would resolve
    /// a relative argv0 against the current directory (getcwd), and this runs
    /// for every pane the sidebar draws.
    public static func commandName(_ argv0: String) -> String { (argv0 as NSString).lastPathComponent }

    /// Requires actual shell PID in the foreground, not an empty process list.
    public var isShellForeground: Bool {
        guard let shellPID, !foregroundProcesses.isEmpty else { return false }
        return foregroundProcesses.allSatisfy { $0.pid == shellPID }
    }
}
