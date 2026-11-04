import Foundation

/// One hc terminal as the board shows it, decoded from the core's public record.
/// PID/status/turn/labels are presentation facts; none of them authorize input,
/// termination, browser access or a native session. Unknown fields are ignored
/// so a newer core can add facts without breaking an older board.
public nonisolated struct HcTerminalRecord: Decodable, Equatable, Sendable {
    public struct OSCStatus: Decodable, Equatable, Sendable { public let state: String }
    public let address: String
    public let name: String?
    public let labels: [String: String]
    public let argv: [String]
    public let cwd: String
    public let state: String
    public let pid: UInt32?
    public let exitCode: Int32?
    public let reason: String?
    public let title: String
    public let cols: UInt16
    public let rows: UInt16
    public let createdMs: UInt64
    public let finishedMs: UInt64?
    public let status: OSCStatus?
    public let reported: Bool
    public let turn: UInt64
    private enum CodingKeys: String, CodingKey {
        case address, name, labels, argv, cwd, state, pid, exit_code, reason, title, cols, rows
        case created_ms, finished_ms, status, reported, turn
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        argv = try c.decodeIfPresent([String].self, forKey: .argv) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        state = try c.decode(String.self, forKey: .state)
        pid = try c.decodeIfPresent(UInt32.self, forKey: .pid)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exit_code)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cols = try c.decodeIfPresent(UInt16.self, forKey: .cols) ?? 0
        rows = try c.decodeIfPresent(UInt16.self, forKey: .rows) ?? 0
        createdMs = try c.decodeIfPresent(UInt64.self, forKey: .created_ms) ?? 0
        finishedMs = try c.decodeIfPresent(UInt64.self, forKey: .finished_ms)
        status = try c.decodeIfPresent(OSCStatus.self, forKey: .status)
        reported = try c.decodeIfPresent(Bool.self, forKey: .reported) ?? false
        turn = try c.decodeIfPresent(UInt64.self, forKey: .turn) ?? 0
    }
}

/// A minimal hc board: list/get/run/read/kill/attach on one already-negotiated
/// connection. This is the hc replacement for the herdr board's terminal
/// surface (`listPanes`/`readPane`/`runCommand`/`attach`), not the full agent or
/// workspace/notification layer. The caller owns the connection and stops the core.
public actor HcTerminalBoard {
    public struct ReadResult: Equatable, Sendable { public let text: String; public let complete: Bool }
    private struct ListResult: Decodable { let terminals: [HcTerminalRecord]; let hidden_finished: Int }
    private struct ReadEnvelope: Decodable { let text: String; let complete: Bool? }
    private struct RemoveEnvelope: Decodable { let removed: String }
    private let connection: CoreRPCConnection

    public init(connection: CoreRPCConnection) { self.connection = connection }

    private func params(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    public func list(all: Bool = false) async throws -> [HcTerminalRecord] {
        let envelope: ListResult = try await connection.call("terminal.list", parameters: try params(["all": all])).result()
        return envelope.terminals
    }

    public func get(_ address: String) async throws -> HcTerminalRecord {
        try await connection.call("terminal.get", parameters: try params(["terminal": address])).result()
    }

    /// Runs a program and returns its fresh record. The caller supplies argv;
    /// no shell line is parsed here, so injection/quoting stays the caller's.
    @discardableResult
    public func run(argv: [String], cwd: String? = nil, labels: [String: String] = [:], noParent: Bool = true) async throws -> HcTerminalRecord {
        var request: [String: Any] = ["argv": argv, "no_parent": noParent]
        if let cwd { request["cwd"] = cwd }
        if !labels.isEmpty { request["labels"] = labels }
        return try await connection.call("terminal.run", parameters: try params(request)).result()
    }

    public func read(_ address: String, lines: Int = 0) async throws -> ReadResult {
        let envelope: ReadEnvelope = try await connection.call("terminal.read", parameters: try params(["terminal": address, "lines": lines])).result()
        return ReadResult(text: envelope.text, complete: envelope.complete ?? false)
    }

    @discardableResult
    public func kill(_ address: String) async throws -> HcTerminalRecord {
        try await connection.call("terminal.kill", parameters: try params(["terminal": address])).result()
    }

    public func remove(_ address: String) async throws -> Bool {
        let envelope: RemoveEnvelope = try await connection.call("terminal.rm", parameters: try params(["terminal": address])).result()
        return !envelope.removed.isEmpty
    }

    public nonisolated func attach(_ address: String, timeout: Duration = .seconds(10)) -> HcTerminalSession {
        HcTerminalSession(connection: connection, terminalID: address, timeout: timeout)
    }
}
