import Foundation

nonisolated struct AgentSessionReference: Equatable, Sendable {
    enum Kind: String, Sendable { case id, path }
    let source: String
    let agent: String
    let kind: Kind
    let value: String

    init?(json: JSONValue) {
        guard let source = json["source"]?.stringValue, let agent = json["agent"]?.stringValue,
              let rawKind = json["kind"]?.stringValue, let kind = Kind(rawValue: rawKind),
              let value = json["value"]?.stringValue else { return nil }
        self.source = source; self.agent = agent; self.kind = kind; self.value = value
    }

    func resumeID(for expected: AgentKind) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard expected.supportsLegacySessionInspection, kind == .id, AgentKind(herdrName: agent) == expected, !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}

nonisolated extension AgentKind {
    init?(herdrName: String) {
        switch herdrName {
        case "claude", "claude-code": self = .claude
        case "codex": self = .codex
        case "pi": self = .pi
        default: return nil
        }
    }
}

nonisolated struct AgentStartResult: Sendable {
    let agent: AgentSummary
    /// May contain user instructions; never log this value.
    let arguments: [String]
}

nonisolated struct PaneProcessInfo: Decodable, Sendable {
    struct ForegroundProcess: Decodable, Equatable, Sendable {
        let pid: UInt32
        let name: String
        /// Absent/null means unknown, not missing injection.
        let argv: [String]?
        let argv0: String?
        enum CodingKeys: String, CodingKey { case pid, name, argv, argv0 }
    }
    let paneID: String
    let shellPID: UInt32?
    let foregroundProcessGroupID: UInt32?
    let tty: String?
    let foregroundProcesses: [ForegroundProcess]
    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", shellPID = "shell_pid"
        case foregroundProcessGroupID = "foreground_process_group_id", foregroundProcesses = "foreground_processes", tty
    }

    func agentArguments(for kind: AgentKind) -> [String]? {
        // Pi always uses the native process/session bridge. Enabling its
        // launcher does not make a process name or copied argv an identity proof.
        guard kind.supportsLegacySessionInspection else { return nil }
        let matching = foregroundProcesses.filter {
            AgentKind(herdrName: $0.name) == kind || $0.argv0.map { AgentKind(herdrName: URL(fileURLWithPath: $0).lastPathComponent) == kind } == true ||
            $0.argv?.first.map { AgentKind(herdrName: URL(fileURLWithPath: $0).lastPathComponent) == kind } == true
        }
        guard matching.count == 1 else { return nil }
        guard let argv = matching[0].argv, let first = argv.first, !first.isEmpty else { return nil }
        return argv
    }

    /// Requires actual shell PID in the foreground, not an empty process list.
    var isShellForeground: Bool {
        guard let shellPID, !foregroundProcesses.isEmpty else { return false }
        return foregroundProcesses.allSatisfy { $0.pid == shellPID }
    }
}
