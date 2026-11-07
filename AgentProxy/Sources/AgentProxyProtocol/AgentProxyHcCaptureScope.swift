import Foundation

/// Non-secret launch provenance for hc capture. This is not a legacy herdr
/// session, a route capability, native-agent identity, or input/browser authority.
/// A launch intent may exist before terminal.run has returned a known receipt.
public nonisolated struct AgentProxyHcCaptureIntent: Codable, Equatable, Hashable, Sendable {
    public let originCoreID: String
    public let launchID: UUID
    public let paneID: UUID
    public enum Failure: Error, Equatable, Sendable { case invalidOrigin, unsupportedScope, legacyIdentity, invalidTerminal, originMismatch }
    public init(originCoreID: String, launchID: UUID, paneID: UUID) throws {
        guard !originCoreID.isEmpty, originCoreID.utf8.count <= 256,
              originCoreID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }) else { throw Failure.invalidOrigin }
        self.originCoreID = originCoreID; self.launchID = launchID; self.paneID = paneID
    }
    private enum Keys: String, CodingKey { case schemaVersion, kind, originCoreID, launchID, paneID, session, herdrSession, terminalID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:Keys.self)
        guard try c.decode(Int.self,forKey:.schemaVersion) == 1,
              try c.decode(String.self,forKey:.kind) == "hc" else { throw Failure.unsupportedScope }
        guard !c.contains(.session), !c.contains(.herdrSession), !c.contains(.terminalID) else { throw Failure.legacyIdentity }
        try self.init(originCoreID:c.decode(String.self,forKey:.originCoreID),launchID:c.decode(UUID.self,forKey:.launchID),paneID:c.decode(UUID.self,forKey:.paneID))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy:Keys.self)
        try c.encode(1,forKey:.schemaVersion); try c.encode("hc",forKey:.kind)
        try c.encode(originCoreID,forKey:.originCoreID); try c.encode(launchID,forKey:.launchID); try c.encode(paneID,forKey:.paneID)
    }
}

/// A value that the coordinator may bind ONLY after its durable launch record
/// and a known exact-origin terminal.run receipt. Validation here proves syntax,
/// not that a receipt occurred. Never construct by matching a PID/title/label.
public nonisolated struct AgentProxyHcCaptureBinding: Codable, Equatable, Hashable, Sendable {
    public let intent: AgentProxyHcCaptureIntent
    public let terminalID: String
    public init(intent: AgentProxyHcCaptureIntent, receiptOriginCoreID: String, terminalID: String) throws {
        guard receiptOriginCoreID == intent.originCoreID else { throw AgentProxyHcCaptureIntent.Failure.originMismatch }
        guard Self.isCanonicalTerminal(terminalID) else { throw AgentProxyHcCaptureIntent.Failure.invalidTerminal }
        self.intent = intent; self.terminalID = terminalID
    }
    private enum Keys: String, CodingKey { case intent, terminalID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy:Keys.self)
        let intent = try c.decode(AgentProxyHcCaptureIntent.self,forKey:.intent)
        try self.init(intent:intent,receiptOriginCoreID:intent.originCoreID,terminalID:c.decode(String.self,forKey:.terminalID))
    }
    // Wire package stays independent of ShepherdKit. Parity tests compare this
    // generation-1 rule against the real CoreTerminalID source, including overflow.
    public static func isCanonicalTerminal(_ value: String) -> Bool {
        let bytes = Array(value.utf8), alphabet = Array("0123456789bcdfghjkmnpqrstvwxyz".utf8)
        guard bytes.count >= 2, bytes.count <= 9, bytes[0] == 116, (49...57).contains(bytes[1]) else { return false }
        var rest = UInt64(bytes[1] - 49), before: UInt64 = 0, size: UInt64 = 9
        for byte in bytes.dropFirst(2) {
            guard let digit = alphabet.firstIndex(of:byte) else { return false }
            rest = rest * 30 + UInt64(digit); before += size; size *= 30
            if before + rest + 1 > UInt32.max { return false }
        }
        return before + rest + 1 <= UInt32.max
    }
}
