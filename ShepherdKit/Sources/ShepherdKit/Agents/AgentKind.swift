import Foundation

public nonisolated enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, pi
    /// Qualified local-launch capabilities, not a preference or an identity proof.
    /// Pi is authorized only by its native process/session bridge, never copied argv.
    public var supportsManagedBrowserLaunch: Bool {
        switch self { case .claude, .codex, .pi: true }
    }
    /// Pi's kernel bridge is independent of legacy argv/session/idle heuristics.
    /// Enabling its launcher must never implicitly enable those contracts.
    public var supportsLegacySessionInspection: Bool { self != .pi }
    public var title: LocalizedStringResource {
        switch self { case .claude: LocalizedStringResource("Claude Code", bundle: .shepherdKit); case .codex: LocalizedStringResource("Codex", bundle: .shepherdKit); case .pi: LocalizedStringResource("Pi", bundle: .shepherdKit) }
    }
}
