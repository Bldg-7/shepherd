#if os(macOS)
import Foundation

/// The agent proxy's LaunchAgent, as `AgentProxyService` sees it: registered
/// with launchd while "Show Conversations on iPhone and iPad" is on, or while
/// agents still use the proxy after it is turned off. A stand-in takes its
/// place in tests, which never register anything.
@MainActor protocol AgentProxyLaunchAgent: AnyObject {
    var state: AgentProxyLaunchAgentState { get }
    func register() throws
    func unregister() async throws
    /// System Settings › General › Login Items, where the person can allow it again.
    func openSystemSettings()
}

nonisolated enum AgentProxyLaunchAgentState: Equatable, Sendable {
    case notRegistered
    /// Registered and allowed: launchd keeps the proxy running.
    case enabled
    /// Registered, but turned off in Login Items: launchd won't start it.
    case requiresApproval
    /// The app bundle has no such LaunchAgent.
    case notFound
}

#endif
