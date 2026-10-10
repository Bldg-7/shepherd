import Foundation

/// A loosely-typed JSON value for decoding herdr socket API payloads whose
/// exact shape isn't pinned down yet (confirm against `herdr api schema --json`
/// once available, then tighten these into concrete Codable types).
enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    nonisolated subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    nonisolated var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    nonisolated var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    nonisolated var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    nonisolated var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
