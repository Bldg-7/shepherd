import Foundation

/// The agent proxy's route for one agent the New Tab launcher starts on This
/// Mac (SHPHRD-105): made by `AgentProxyService` once the agent's pane is
/// known, and given to the agent as its API's base URL.
nonisolated struct AgentProxyLaunchRoute: Sendable, Equatable {
    let routeID: String
    /// `http://127.0.0.1:PORT/p/<token>`: a secret, never logged or shown.
    let baseURL: String
}

/// What `AgentLaunchService` asks of the agent proxy. `route` is nil when the
/// launch goes without it: the setting is off, the window isn't on This Mac,
/// the proxy isn't running as it should, the CLI is older than the proxy
/// needs, a system HTTP proxy is set, or that kind of agent was turned away
/// for not being signed in with a subscription. A route whose agent never
/// started is `discard`ed; one whose agent did is `started`, and stays the
/// pane's until the pane is gone.
@MainActor protocol AgentProxyRouting: AnyObject {
    func route(for kind: AgentKind, pane: AgentPaneIdentity, cliVersion: String?, on machine: Machine) async -> AgentProxyLaunchRoute?
    func started(_ route: AgentProxyLaunchRoute)
    func discard(_ route: AgentProxyLaunchRoute) async
}
