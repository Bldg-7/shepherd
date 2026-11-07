import Foundation

/// Receipt syntax only. The caller must already possess the durable launch
/// ticket and its exact known run receipt; these fields confer no native input,
/// provider-session, browser, credential or process-kill authority.
public nonisolated struct AgentProxyHcRouteBind: Codable, Sendable, Equatable {
    public let routeID: UUID
    public let received: AgentProxyHcCaptureBinding
    public init(routeID: UUID, received: AgentProxyHcCaptureBinding) { self.routeID = routeID;self.received = received }
}

/// Non-secret review state. The capability is returned only by creation, after
/// durable acknowledgement, never listed or reconstructed from a stored hash.
public nonisolated struct AgentProxyHcRouteInfo: Codable, Sendable, Equatable {
    public let routeID: UUID
    public let state: AgentProxyHcRouteState
    public let oauthRejected: Bool
    public let inFlight: Int
    public init(routeID: UUID, state: AgentProxyHcRouteState, oauthRejected: Bool, inFlight: Int) {
        self.routeID = routeID;self.state = state;self.oauthRejected = oauthRejected;self.inFlight = inFlight
    }
}
public nonisolated struct AgentProxyHcRouteList: Codable, Sendable, Equatable {
    public let routes: [AgentProxyHcRouteInfo]
    public init(routes: [AgentProxyHcRouteInfo]) { self.routes = routes }
}
public nonisolated struct AgentProxyHcRouteBound: Codable, Sendable, Equatable {
    public let bound: Bool
    public init(bound: Bool) { self.bound = bound }
}
