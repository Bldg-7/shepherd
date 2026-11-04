import Foundation
import Observation

private nonisolated struct HcMobileInputAck: Decodable, Sendable { let turn: UInt64 }

/// Snapshot conversation UI over a fresh hc connection. Reading never attaches.
/// Explicit type-only input uses a brief attach at the current grid (no focus
/// command), since generation-1 named keys do not encode arbitrary Unicode.
/// No input replay, status-derived authority, login or injected runtime.
@MainActor @Observable public final class HcConversationModel {
    public private(set) var output: String?
    public private(set) var record: HcTerminalRecord?
    public private(set) var connected = false
    public private(set) var busy = false
    public private(set) var message: String?
    public var draft = ""
    private let machine: Machine
    private let store: MachineStore
    private let origin: String
    private let terminalID: String
    private var rpc: CoreRPCConnection?
    private var opening: Task<CoreRPCConnection, Error>?
    private var token = UUID()
    private var cleanupFailed = false
    private let makeConnection: @MainActor () async throws -> CoreRPCConnection
    public init(machine: Machine, store: MachineStore, origin: String, terminalID: String,
                connect: (@MainActor () async throws -> CoreRPCConnection)? = nil) {
        self.machine = machine; self.store = store; self.origin = origin; self.terminalID = terminalID
        makeConnection = connect ?? { try await store.makeHcConnection(for: machine) }
    }
    public func run() async {
        guard !cleanupFailed else { connected = false; message = "Previous connection cleanup could not be verified. Close this screen before reconnecting; do not restart the core or its programs."; return }
        let generation = UUID(); token = generation; connected = false; busy = false; message = nil
        let previous = rpc, pending = opening; rpc = nil; opening = nil
        pending?.cancel()
        if let pending, case .success(let connection) = await pending.result { try? await connection.close() }
        do { try await previous?.close() }
        catch { if token == generation { cleanupFailed = true; message = "Previous connection cleanup could not be verified." }; return }
        guard token == generation, !Task.isCancelled else { return }
        var owned: CoreRPCConnection?
        do {
            let makeConnection = makeConnection
            let job = Task { try await makeConnection() }; opening = job
            let rpc = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            owned = rpc
            if token == generation { opening = nil }
            guard token == generation, await rpc.hello?.core.id == origin else { throw HcWorkspaceModel.Failure.stale }
            self.rpc = rpc
            let events = try await rpc.openStream("events.subscribe")
            guard token == generation else { throw CancellationError() }
            try await refresh()
            guard token == generation else { throw CancellationError() }
            connected = true
            var lines = try CoreEventLines(maximumLineBytes: 1 << 20)
            while let packet = try await events.next(timeout: .seconds(45)) {
                guard token == generation, packet.frame.kind == .data else { throw HcWorkspaceModel.Failure.unavailable }
                var changed = false
                try lines.receive(packet.frame.payload) { data in
                    struct Note: Decodable { let method: String }
                    let method = try JSONDecoder().decode(Note.self, from: data).method
                    guard ["event", "snapshot", "missed", "heartbeat"].contains(method) else { throw HcWorkspaceModel.Failure.unavailable }
                    changed = changed || method != "heartbeat"
                }
                if changed { try await refresh() }
                try await events.acknowledge(packet)
            }
            throw HcWorkspaceModel.Failure.unavailable
        } catch {
            if token == generation { connected = false; message = error is CancellationError ? "Disconnected; saved screen only." : hcConnectionFailureDescription(error) }
        }
        do { try await owned?.close() }
        catch { if token == generation { cleanupFailed = true; message = "Connection cleanup could not be verified." } }
        if token == generation { rpc = nil; connected = false }
    }
    public func pause() async {
        token = UUID(); connected = false; busy = false
        let old = rpc, pending = opening; rpc = nil; opening = nil
        pending?.cancel()
        if let pending, case .success(let connection) = await pending.result { try? await connection.close() }
        do { try await old?.close() }
        catch { cleanupFailed = true; message = "Connection cleanup could not be verified." }
    }
    public func refresh() async throws {
        guard let rpc, store.isCurrentConnection(machine), await rpc.hello?.core.id == origin else { throw HcWorkspaceModel.Failure.stale }
        let generation = token, board = HcTerminalBoard(connection: rpc)
        let fresh = try await board.get(terminalID)
        guard fresh.address == terminalID else { throw HcWorkspaceModel.Failure.stale }
        let read = try await board.read(terminalID, lines: 1000)
        guard token == generation, store.isCurrentConnection(machine) else { throw HcWorkspaceModel.Failure.stale }
        record = fresh
        output = (read.text.count > 120000 ? "[Older output omitted]\n" : "") + String(read.text.suffix(120000))
    }
    public func send(keys: [String]? = nil, textOnly: Bool = false) async {
        guard connected, !busy, let rpc, let viewed = record, viewed.state == "live", !draft.isEmpty || keys != nil else { return }
        let generation = token, text = draft
        guard text.utf8.count <= 65536 else { message = "Input is too long."; return }
        busy = true; defer { if token == generation { busy = false } }
        var attachment: HcTerminalSession?
        do {
            let fresh = try await HcTerminalBoard(connection: rpc).get(terminalID)
            guard token == generation, store.isCurrentConnection(machine), fresh.address == terminalID,
                  fresh.createdMs == viewed.createdMs, fresh.pid == viewed.pid, fresh.state == "live" else { throw HcWorkspaceModel.Failure.stale }
            if textOnly && keys == nil {
                guard !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw CoreRPCFailure.invalidParameters }
                let session = HcTerminalSession(connection: rpc, terminalID: terminalID)
                attachment = session
                try await session.start(columns: Int(fresh.cols), rows: Int(fresh.rows))
                guard token == generation, store.isCurrentConnection(machine) else { throw HcWorkspaceModel.Failure.stale }
                // No output is rendered from this short-lived input-only attach;
                // its unused output remains credit-bounded until close. Flush
                // DATA before closing, or close would discard queued input.
                try await session.writeAndFlush(Data(text.utf8))
                try await session.stop(); attachment = nil
            } else {
                let method = keys == nil ? "terminal.send" : "terminal.keys"
                let params: [String: Any] = keys.map { ["terminal":terminalID, "keys":$0] } ?? ["terminal":terminalID, "text":text, "force":false, "wait":false]
                let _: HcMobileInputAck = try await rpc.call(method, parameters: JSONSerialization.data(withJSONObject: params)).result()
            }
            guard token == generation else { return }
            if keys == nil && draft == text { draft = "" }
            message = "Input sent. Program processing and readiness are not inferred from delivery."
            try await refresh()
        } catch {
            try? await attachment?.stop()
            guard token == generation else { return }
            message = "Delivery was not confirmed. Review the screen before retrying; nothing is automatically resent. " + hcConnectionFailureDescription(error)
        }
    }
}
