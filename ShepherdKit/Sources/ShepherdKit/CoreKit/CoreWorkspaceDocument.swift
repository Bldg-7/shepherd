import Foundation

public nonisolated enum CoreWorkspaceFailure: Error, Equatable, Sendable {
    case invalidDocument, unsupportedSchema, unknownFields, limitExceeded, duplicateID, invalidReference
}

/// App-owned layout only. References nominate terminals; they never authorize
/// input, process control, browser access or a native session. Routing aliases,
/// focus, zoom and credentials deliberately do not belong in this document.
public nonisolated struct CoreWorkspaceDocument: Equatable, Sendable {
    public static let documentName = "3rdr-workspace-v1"
    public static let maximumBytes = 1 << 20
    public static let maximumDepth = 32
    public static let maximumItems = 4096
    public let workspaces: [Workspace]

    public struct TerminalReference: Codable, Equatable, Hashable, Sendable {
        public let coreID: String
        public let terminalID: String
        public init(coreID: String, terminalID: String) { self.coreID = coreID; self.terminalID = terminalID }
    }
    public struct Pane: Codable, Equatable, Sendable {
        public let id: UUID
        public let title: String?
        /// Nil is an unbound placeholder, NOT permission to launch a program.
        public let terminal: TerminalReference?
        public init(id: UUID = UUID(), title: String? = nil, terminal: TerminalReference? = nil) {
            self.id = id; self.title = title; self.terminal = terminal
        }
    }
    public enum Axis: String, Codable, Sendable { case horizontal, vertical }
    public indirect enum Layout: Codable, Equatable, Sendable {
        case leaf(Pane)
        case split(axis: Axis, ratio: Double, first: Layout, second: Layout)
        private enum CodingKeys: String, CodingKey { case type, pane, axis, ratio, first, second }
        private enum Kind: String, Codable { case leaf, split }
        public init(from decoder: any Decoder) throws {
            guard decoder.codingPath.count <= CoreWorkspaceDocument.maximumDepth + 8 else { throw CoreWorkspaceFailure.limitExceeded }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .type) {
            case .leaf: self = .leaf(try c.decode(Pane.self, forKey: .pane))
            case .split:
                self = .split(axis: try c.decode(Axis.self, forKey: .axis), ratio: try c.decode(Double.self, forKey: .ratio),
                              first: try c.decode(Layout.self, forKey: .first), second: try c.decode(Layout.self, forKey: .second))
            }
        }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let pane): try c.encode(Kind.leaf, forKey: .type); try c.encode(pane, forKey: .pane)
            case .split(let axis, let ratio, let first, let second):
                try c.encode(Kind.split, forKey: .type); try c.encode(axis, forKey: .axis); try c.encode(ratio, forKey: .ratio)
                try c.encode(first, forKey: .first); try c.encode(second, forKey: .second)
            }
        }
    }
    public struct Tab: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let layout: Layout?
        public init(id: UUID = UUID(), name: String, layout: Layout? = nil) { self.id = id; self.name = name; self.layout = layout }
    }
    public struct Workspace: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let cwd: String?
        public let tabs: [Tab]
        public init(id: UUID = UUID(), name: String, cwd: String? = nil, tabs: [Tab] = []) {
            self.id = id; self.name = name; self.cwd = cwd; self.tabs = tabs
        }
    }
    private struct Wire: Codable { let schemaVersion: UInt32; let workspaces: [Workspace] }

    public init(workspaces: [Workspace] = []) throws {
        self.workspaces = workspaces
        _ = try encoded() // Validate even locally constructed values before they become a document.
    }

    /// Use this entry point for persisted input: bounded bytes and layout depth,
    /// no silent unknown-field dropping, no legacy/other-app document migration.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CoreWorkspaceFailure.limitExceeded }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            try preflight(object)
            // Validate and decode the same effective object, even when an
            // input repeats keys. Do not let two parsers choose different values.
            // CAS UInt64 versions are outside this layout codec.
            let canonical = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            guard canonical.count <= maximumBytes else { throw CoreWorkspaceFailure.limitExceeded }
            let wire = try JSONDecoder().decode(Wire.self, from: canonical)
            guard wire.schemaVersion == 1 else { throw CoreWorkspaceFailure.unsupportedSchema }
            return try Self(workspaces: wire.workspaces)
        } catch let error as CoreWorkspaceFailure { throw error }
        catch { throw CoreWorkspaceFailure.invalidDocument } // Never include document/user text in errors.
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Wire(schemaVersion: 1, workspaces: workspaces))
        guard data.count <= Self.maximumBytes else { throw CoreWorkspaceFailure.limitExceeded }
        return data
    }

    private func validate() throws {
        var ids = Set<UUID>(), count = 0
        func item(_ id: UUID?) throws {
            count += 1
            guard count <= Self.maximumItems else { throw CoreWorkspaceFailure.limitExceeded }
            if let id, !ids.insert(id).inserted { throw CoreWorkspaceFailure.duplicateID }
        }
        func text(_ value: String?, limit: Int) throws {
            if let value, value.utf8.count > limit || value.utf8.contains(0) { throw CoreWorkspaceFailure.invalidDocument }
        }
        func reference(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
            }
        }
        func layout(_ node: Layout, depth: Int) throws {
            guard depth <= Self.maximumDepth else { throw CoreWorkspaceFailure.limitExceeded }
            switch node {
            case .leaf(let pane):
                try item(pane.id); try text(pane.title, limit: 1024)
                if let terminal = pane.terminal, !reference(terminal.coreID) || !reference(terminal.terminalID) {
                    throw CoreWorkspaceFailure.invalidReference
                }
            case .split(_, let ratio, let first, let second):
                try item(nil)
                guard ratio.isFinite && ratio > 0 && ratio < 1 else { throw CoreWorkspaceFailure.invalidDocument }
                try layout(first, depth: depth + 1); try layout(second, depth: depth + 1)
            }
        }
        for workspace in workspaces {
            try item(workspace.id); try text(workspace.name, limit: 1024); try text(workspace.cwd, limit: 4096)
            for tab in workspace.tabs {
                try item(tab.id); try text(tab.name, limit: 1024)
                if let node = tab.layout { try layout(node, depth: 1) }
            }
        }
    }

    private static func preflight(_ value: Any) throws {
        func object(_ value: Any?, _ fields: Set<String>) throws -> [String: Any] {
            guard let object = value as? [String: Any] else { throw CoreWorkspaceFailure.invalidDocument }
            guard Set(object.keys).isSubset(of: fields) else { throw CoreWorkspaceFailure.unknownFields }
            return object
        }
        func array(_ value: Any?) throws -> [Any] {
            guard let values = value as? [Any] else { throw CoreWorkspaceFailure.invalidDocument }
            guard values.count <= maximumItems else { throw CoreWorkspaceFailure.limitExceeded }
            return values
        }
        func present(_ value: Any?) -> Bool { value != nil && !(value is NSNull) }
        var nodes = 0
        func node(_ value: Any?, depth: Int) throws {
            nodes += 1
            guard depth <= maximumDepth, nodes <= maximumItems else { throw CoreWorkspaceFailure.limitExceeded }
            guard let raw = value as? [String: Any], let kind = raw["type"] as? String else { throw CoreWorkspaceFailure.invalidDocument }
            switch kind {
            case "leaf":
                let leaf = try object(raw, ["type","pane"])
                let pane = try object(leaf["pane"], ["id","title","terminal"])
                if present(pane["terminal"]) { _ = try object(pane["terminal"], ["coreID","terminalID"]) }
            case "split":
                let split = try object(raw, ["type","axis","ratio","first","second"])
                try node(split["first"], depth: depth + 1); try node(split["second"], depth: depth + 1)
            default: throw CoreWorkspaceFailure.invalidDocument
            }
        }
        let root = try object(value, ["schemaVersion","workspaces"])
        // Exact numeric schema validation is also performed by the typed decoder.
        guard let schema = root["schemaVersion"] as? NSNumber, schema == 1 else { throw CoreWorkspaceFailure.unsupportedSchema }
        for entry in try array(root["workspaces"]) {
            let workspace = try object(entry, ["id","name","cwd","tabs"])
            for entry in try array(workspace["tabs"]) {
                let tab = try object(entry, ["id","name","layout"])
                if present(tab["layout"]) { try node(tab["layout"], depth: 1) }
            }
        }
    }
}
