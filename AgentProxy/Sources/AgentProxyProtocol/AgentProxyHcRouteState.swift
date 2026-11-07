import Foundation

/// Non-secret persisted hc route metadata. Pending records intentionally do not
/// identify a terminal. This value does not create/enable a route or prove a
/// terminal receipt: the service/coordinator must persist before dispatch and
/// bind only its known exact-origin receipt, never observations/labels/PIDs.
public nonisolated struct AgentProxyHcRouteState: Codable, Equatable, Sendable {
    public let kind: AgentProxyRouteKind
    public let intent: AgentProxyHcCaptureIntent
    public let cliVersion: String
    public private(set) var binding: AgentProxyHcCaptureBinding?
    public enum Failure: Error, Equatable, Sendable { case invalidVersion, differentIntent, alreadyBound }
    public init(kind: AgentProxyRouteKind, intent: AgentProxyHcCaptureIntent, cliVersion: String) throws {
        guard cliVersion.utf8.count <= 64,
              !cliVersion.unicodeScalars.contains(where:{ $0.properties.generalCategory == .control }) else { throw Failure.invalidVersion }
        self.kind = kind; self.intent = intent; self.cliVersion = cliVersion; binding = nil
    }
    /// Caller must first possess the durable ticket and exact known receipt.
    /// A repeated call is rejected even for identical data, not replayed/rebased.
    public mutating func bind(_ received: AgentProxyHcCaptureBinding) throws {
        guard binding == nil else { throw Failure.alreadyBound }
        guard received.intent == intent else { throw Failure.differentIntent }
        binding = received
    }
    private enum Keys: String, CodingKey { case kind, intent, cliVersion, binding }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:Keys.self)
        try self.init(kind:c.decode(AgentProxyRouteKind.self,forKey:.kind),intent:c.decode(AgentProxyHcCaptureIntent.self,forKey:.intent),cliVersion:c.decode(String.self,forKey:.cliVersion))
        if let received = try c.decodeIfPresent(AgentProxyHcCaptureBinding.self,forKey:.binding) { try bind(received) }
    }
}
