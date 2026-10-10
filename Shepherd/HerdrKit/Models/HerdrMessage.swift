import Foundation

/// Request envelope for the herdr local socket API: newline-delimited JSON,
/// one object per line, e.g. {"id":"req_1","method":"agent.list","params":{}}.
nonisolated struct HerdrRequest: Encodable, Sendable {
    let id: String
    let method: String
    let params: JSONValue

    func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A) // newline delimiter required by the wire protocol
        return data
    }
}

/// Response envelope. Echoes the request `id`; exactly one of `result`/`error` is set.
nonisolated struct HerdrResponse: Decodable, Sendable {
    let id: String
    let result: JSONValue?
    let error: HerdrErrorPayload?
}

nonisolated struct HerdrErrorPayload: Decodable, Sendable, LocalizedError {
    let code: String?
    let message: String

    /// The server's own words, since this is what ends up on screen: a plain
    /// `Error` would be described as "The operation couldn't be completed"
    /// plus a type name. The code goes along with the message because it is
    /// the stable half of the pair — herdr's messages are free text and often
    /// terse ("pane not found"), while the code is what its documentation and
    /// source can be searched for.
    var errorDescription: String? {
        guard let code, !code.isEmpty else { return "herdr: \(message)" }
        return "herdr: \(message) (\(code))"
    }
}

/// Unsolicited event line delivered after `events.subscribe` acknowledges.
/// The exact event envelope shape (e.g. whether the discriminator field is
/// named "event" or "type") should be confirmed against `herdr api schema --json`;
/// callers should treat this as provisional and fall back to raw access via `payload`.
nonisolated struct HerdrEvent: Decodable, Sendable {
    let payload: JSONValue

    init(from decoder: Decoder) throws {
        payload = try JSONValue(from: decoder)
    }
}
