import Foundation

/// Whether an agent the New Tab launcher starts goes through the agent proxy
/// (SHPHRD-105), told before the proxy is asked for a route. Whether the proxy
/// answers, runs this app's build and is running is asked of the proxy itself
/// (`AgentProxyService`); whether the user's own CLI settings point the agent
/// elsewhere, by the runtime as it prepares the launch (`apiProxyConflict`).
nonisolated enum AgentProxyInjectionPolicy {
    enum Skip: String, Equatable, Sendable {
        case settingOff = "setting-off"
        case notThisMac = "not-this-mac"
        case oauthRejected = "oauth-rejected"
        case cliVersion = "cli-version"
        case systemProxy = "system-proxy"
        case proxyUnavailable = "proxy-unavailable"
    }

    /// The oldest CLI of each kind whose requests the proxy was checked with.
    static let minimumVersions: [AgentKind: [Int]] = [.claude: [2, 1, 283], .codex: [0, 162, 0], .pi: [1, 3, 0]]

    /// The first `x.y` or `x.y.z` in what a CLI reported: "2.1.288 (Claude
    /// Code)", "codex-cli 0.162.0", Pi's package version "1.4.0".
    static func version(in text: String?) -> [Int]? {
        guard let text, let match = text.firstMatch(of: #/(\d{1,6})\.(\d{1,6})(?:\.(\d{1,6}))?/#) else { return nil }
        return [Int(match.1), Int(match.2), match.3.flatMap { Int($0) } ?? 0].map { $0 ?? 0 }
    }

    static func meetsMinimum(_ kind: AgentKind, version text: String?) -> Bool {
        guard let version = version(in: text), let minimum = minimumVersions[kind] else { return false }
        return version.lexicographicallyPrecedes(minimum) == false
    }

    /// Why this launch goes without the proxy, or nil to ask it for a route.
    static func skip(kind: AgentKind, cliVersion: String?, settingOn: Bool, isThisMac: Bool,
                     systemProxyConfigured: Bool, rejectedKinds: Set<String>) -> Skip? {
        guard settingOn else { return .settingOff }
        guard isThisMac else { return .notThisMac }
        guard !rejectedKinds.contains(kind.rawValue) else { return .oauthRejected }
        guard meetsMinimum(kind, version: cliVersion) else { return .cliVersion }
        guard !systemProxyConfigured else { return .systemProxy }
        return nil
    }
}
