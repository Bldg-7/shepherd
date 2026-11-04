import Foundation
import Observation

/// Owns only the selected account's read-only capture connection. Neither
/// terminal IDs nor names are compared with hc to adopt a native session.
@MainActor @Observable public final class CaptureHistorySource {
    public private(set) var transport: ConversationLineConnection?
    public private(set) var message: String?
    public private(set) var cleanupFailed = false
    public var isCurrent: Bool { store.isCurrentConnection(machine) }
    private let machine: Machine
    private let store: MachineStore
    private var token = UUID()
    private var retiring: Task<Void, Error>?
    public init(machine: Machine, store: MachineStore) { self.machine = machine; self.store = store }
    private func retire() async throws {
        if let previous = transport {
            transport = nil
            let barrier = retiring
            retiring = Task { try await barrier?.value; try await previous.close() }
        }
        try await retiring?.value
    }
    public func prepare() async -> ConversationLineConnection? {
        let generation = UUID(); token = generation; message = nil
        do { try await retire() }
        catch { cleanupFailed = true; message = "Capture connection cleanup could not be confirmed."; return nil }
        guard !cleanupFailed else { message = "Capture connection cleanup could not be confirmed."; return nil }
        guard token == generation, !Task.isCancelled, isCurrent else { return nil }
        let store = store, machine = machine
        let connection = ConversationLineConnection { endpoint in
            try await store.makeConversationByteTransport(for: machine, endpoint: endpoint)
        }
        transport = connection
        return connection // No SSH, credentials or service startup until an explicit read.
    }
    /// A late list/detail task may only retire its own connection, never the
    /// newer source installed by a concurrent refresh.
    public func close(_ expected: ConversationLineConnection) async {
        guard transport === expected else {
            do { try await expected.close() }
            catch { cleanupFailed = true; message = "Capture connection cleanup could not be confirmed." }
            return
        }
        await close()
    }
    public func close() async {
        token = UUID()
        do { try await retire() }
        catch { cleanupFailed = true; message = "Capture connection cleanup could not be confirmed." }
    }
}
