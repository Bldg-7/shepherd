import Foundation
import AgentProxyProtocol

/// Archive/capture namespace, not a connection selector or native authority.
/// Legacy sessions are retained only as their own tagged archive namespace.
/// In hc, the same native session on the same core may resume in a new route;
/// launch/pane/terminal provenance belongs to context, not this stable key.
public nonisolated struct ConversationOrigin: Codable, Hashable, Sendable {
    public enum Backend: String, Codable, Sendable { case herdr, hc }
    public let backend: Backend
    public let value: String
    public init?(herdrSession: String) {
        guard RequestProjection.identifier(herdrSession) != nil else { return nil }
        backend = .herdr; value = herdrSession
    }
    public init?(hcCoreID: String) {
        guard AgentProxyHcCaptureIntent.isValidOriginCoreID(hcCoreID) else { return nil }
        backend = .hc; value = hcCoreID
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.backend == rhs.backend && lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(backend.rawValue); hasher.combine(Data(value.utf8))
    }
    private enum Keys: String, CodingKey { case backend, value }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:Keys.self)
        let backend = try c.decode(Backend.self,forKey:.backend), value = try c.decode(String.self,forKey:.value)
        let parsed = backend == .herdr ? Self(herdrSession:value) : Self(hcCoreID:value)
        guard let parsed else { throw DecodingError.dataCorruptedError(forKey:.value,in:c,debugDescription:"Invalid capture namespace") }
        self = parsed
    }
}
