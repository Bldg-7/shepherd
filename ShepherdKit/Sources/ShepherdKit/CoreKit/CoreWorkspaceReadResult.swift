import Foundation

/// Typed doc.get envelope. Version NEVER passes through the layout JSON codec.
/// All layout keys survive capture, so the strict document codec can reject
/// future fields instead of a synthesized Decodable silently discarding them.
nonisolated struct CoreWorkspaceReadResult: Decodable, Sendable {
    let version: UInt64
    let document: CoreWorkspaceDocument?
    private enum CodingKeys: String, CodingKey { case version, value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(UInt64.self, forKey: .version)
        guard c.contains(.value) else { throw CoreWorkspaceFailure.invalidDocument }
        if try c.decodeNil(forKey: .value) { document = nil; return }
        var budget = CoreWorkspaceDocument.maximumBytes
        let object = try Self.capture(c.superDecoder(forKey: .value), depth: 0, budget: &budget)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        document = try CoreWorkspaceDocument.decode(data)
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private static func capture(_ decoder: any Decoder, depth: Int, budget: inout Int) throws -> Any {
        guard depth <= CoreWorkspaceDocument.maximumDepth + 8, budget > 0 else { throw CoreWorkspaceFailure.limitExceeded }
        budget -= 1
        if let object = try? decoder.container(keyedBy: Key.self) {
            guard object.allKeys.count <= CoreWorkspaceDocument.maximumItems else { throw CoreWorkspaceFailure.limitExceeded }
            var result: [String: Any] = [:]
            for key in object.allKeys {
                budget -= key.stringValue.utf8.count
                result[key.stringValue] = try capture(object.superDecoder(forKey: key), depth: depth + 1, budget: &budget)
            }
            return result
        }
        if var array = try? decoder.unkeyedContainer() {
            var result: [Any] = []
            while !array.isAtEnd {
                guard result.count < CoreWorkspaceDocument.maximumItems else { throw CoreWorkspaceFailure.limitExceeded }
                result.append(try capture(array.superDecoder(), depth: depth + 1, budget: &budget))
            }
            return result
        }
        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() { return NSNull() }
        if let bool = try? scalar.decode(Bool.self) { return bool }
        if let text = try? scalar.decode(String.self) {
            budget -= text.utf8.count
            guard budget >= 0 else { throw CoreWorkspaceFailure.limitExceeded }
            return text
        }
        // Only schemaVersion and split ratios are numeric in the layout. The
        // envelope's CAS UInt64 above is deliberately NOT captured here.
        let number = try scalar.decode(Double.self)
        guard number.isFinite else { throw CoreWorkspaceFailure.invalidDocument }
        return number
    }
}
