import Foundation

/// Backend-tagged, non-secret recorder provenance. Legacy identities remain
/// legacy; hc pending/bound metadata never passes through a legacy session ID.
public nonisolated enum AgentProxyCaptureRouteIdentity: Equatable, Sendable {
    case legacy(AgentProxyRouteCreate)
    case hc(AgentProxyHcRouteState)
    public var kind: AgentProxyRouteKind {
        switch self { case .legacy(let value): value.kind; case .hc(let value): value.kind }
    }
    public var cliVersion: String {
        switch self { case .legacy(let value): value.cliVersion; case .hc(let value): value.cliVersion }
    }
}
