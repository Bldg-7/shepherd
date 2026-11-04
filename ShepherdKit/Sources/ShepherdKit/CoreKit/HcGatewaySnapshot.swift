import Foundation

/// Routing metadata from the same global terminal.list reply as its records.
/// State, aliases and IDs are presentation/routing facts, not native authority.
public nonisolated struct HcGatewayMachine: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let state: String
    public init(id: String, name: String, state: String) { self.id = id; self.name = name; self.state = state }
}

/// Keeps the observed hub record intact; origin references and route addresses
/// are explicit. Never turns a display alias into a durable/native identity.
public nonisolated struct HcOriginTerminal: Sendable {
    public let reference: CoreWorkspaceDocument.TerminalReference
    public let observed: HcTerminalRecord
    public var routingAddress: String { reference.coreID + "/" + reference.terminalID }
}

/// Read-only first-level gateway directory. terminal.list ignores `on` in
/// official 0.1.17, so select by the permanent ID's alias IN THIS SAME reply.
/// A snapshot is not a mutation lease: config can change after the read, and
/// the official core's id/name collision bug is not repaired by this reducer.
public nonisolated struct HcGatewaySnapshot: Sendable {
    public enum Failure: Error, Equatable, Sendable { case limit, invalidMetadata, ambiguousSelector, unknownOrigin, invalidAddress }
    public let hub: CoreHello.Identity
    public let epoch: UUID
    public let machines: [HcGatewayMachine]
    private let terminals: [HcTerminalRecord]
    private static func identifier(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 256 && s.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)
        }
    }
    private static func alias(_ s: String) -> Bool {
        guard let first = s.utf8.first else { return false }
        return s.utf8.count <= 32 && ((97...122).contains(first) || (48...57).contains(first))
            && s.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) }
            && !CoreTerminalID.isCanonical(s)
    }
    public init(hub: CoreHello.Identity, epoch: UUID, machines: [HcGatewayMachine], terminals: [HcTerminalRecord]) throws {
        guard machines.count <= 256, terminals.count <= 4096 else { throw Failure.limit }
        guard Self.identifier(hub.id), Self.alias(hub.name),
              machines.allSatisfy({ Self.identifier($0.id) && Self.alias($0.name) && Self.identifier($0.state) && $0.state.utf8.count <= 64 }),
              Set(machines.map(\.id) + [hub.id]).count == machines.count + 1,
              Set(machines.map(\.name) + [hub.name]).count == machines.count + 1 else { throw Failure.invalidMetadata }
        let ids = Set(machines.map(\.id) + [hub.id])
        guard (!ids.contains(hub.name) || hub.name == hub.id),
              machines.allSatisfy({ !ids.contains($0.name) || $0.name == $0.id }) else { throw Failure.ambiguousSelector }
        self.hub = hub; self.epoch = epoch; self.machines = machines; self.terminals = terminals
    }
    public func terminals(on coreID: String) throws -> [HcOriginTerminal] {
        let prefix: String?
        if coreID == hub.id { prefix = nil }
        else {
            guard let machine = machines.first(where: { $0.id == coreID }) else { throw Failure.unknownOrigin }
            prefix = machine.name
        }
        var result: [HcOriginTerminal] = []
        var seen = Set<String>()
        for record in terminals {
            let parts = record.address.split(separator: "/", omittingEmptySubsequences: false)
            let id: String
            if let prefix {
                guard parts.count == 2, parts[0] == prefix else { continue } // Deeper origins are not this origin.
                id = String(parts[1])
            } else {
                guard parts.count == 1 else { continue }
                id = String(parts[0])
            }
            guard CoreTerminalID.isCanonical(id), seen.insert(id).inserted else { throw Failure.invalidAddress }
            result.append(.init(reference: .init(coreID: coreID, terminalID: id), observed: record))
        }
        return result
    }
    /// One compound read, never a terminal list joined to a later alias lookup.
    public static func read(connection: CoreRPCConnection) async throws -> HcGatewaySnapshot {
        guard await connection.state == .ready, let hello = await connection.hello else { throw CoreConnectionFailure.notReady }
        struct Reply: Decodable, Sendable { let terminals: [HcTerminalRecord]; let machines: [HcGatewayMachine]? }
        let reply: Reply = try await connection.call("terminal.list", parameters: Data("{\"all\":true}".utf8)).result()
        guard await connection.state == .ready else { throw CoreConnectionFailure.closed }
        return try HcGatewaySnapshot(hub: hello.core, epoch: connection.epoch, machines: reply.machines ?? [], terminals: reply.terminals)
    }
}
