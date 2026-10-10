#if os(macOS)
import Foundation
import Observation

/// Browser lifetimes and public routes are authoritative only after a
/// successful full snapshot, never from a board's selection or a failed
/// connection. In phase 2 the public loopback origin resolves local hosts
/// only; a bare pane ID can never select an SSH/nested machine.
@MainActor @Observable
final class MachineBrowserService {
    static let shared = MachineBrowserService(store: .shared)
    nonisolated struct ResolvedPane: Sendable {
        let key: BrowserKey
        let terminalID: String
    }
    private let store: BrowserStore
    private var machines: [UUID: Machine] = [:]
    private var panes: [BrowserKey: String] = [:]
    private var polling: [UUID: Task<Void, Never>] = [:]
    private(set) var errors: [UUID: String] = [:]
    /// One app-owned snapshot consumer; never called for failed/disconnected polls.
    @ObservationIgnored var acceptedSnapshot: (@MainActor ([AgentSummary], Machine) -> Void)?

    init(store: BrowserStore) { self.store = store }

    func isLocal(_ key: BrowserKey) -> Bool {
        machines[key.machineID]?.isLocal == true && key.herdrMachineID == nil
    }

    /// All local sessions are polled, so an agent can make its first browser
    /// without ever selecting that machine in a window. SSH ownership moves
    /// here in phase 4; no transport or credential is invented now.
    func update(machines current: [Machine], localSocketPaths: [UUID: String] = [:]) {
        let currentIDs = Set(current.map(\.id))
        for id in Array(machines.keys) where !currentIDs.contains(id) || machines[id] != current.first(where: { $0.id == id }) {
            polling.removeValue(forKey: id)?.cancel()
            panes = panes.filter { $0.key.machineID != id }
            errors[id] = nil
        }
        machines = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        store.reconcile(machines: current)
        for machine in current where machine.isLocal && polling[machine.id] == nil {
            let session = machine.sessionName
            let defaultPath = LocalHerdrTransport.defaultSocketPath
            let derivedPath = session.isEmpty ? defaultPath : URL(fileURLWithPath: defaultPath).deletingLastPathComponent()
                .appending(path: "sessions").appending(path: session).appending(path: "herdr.sock").path
            let path = localSocketPaths[machine.id] ?? derivedPath
            let client = HerdrClient(transport: LocalHerdrTransport(socketPath: path))
            polling[machine.id] = Task {
                await withTaskCancellationHandler {
                    var delay = 2
                    while !Task.isCancelled {
                        do {
                            try await client.connect()
                            let snapshot = try await client.snapshot()
                            try Task.checkCancellation()
                            accept(snapshot.panes, on: machine)
                            errors[machine.id] = nil
                            delay = 2
                        } catch {
                            if Task.isCancelled { break }
                            errors[machine.id] = "Local browser pane polling failed; last successful snapshot retained."
                            delay = min(delay * 2, 30)
                        }
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    await client.disconnect()
                } onCancel: { Task { await client.disconnect() } }
            }
        }
    }

    /// Also used by the disposable runtime fixture. A successful snapshot is
    /// the only evidence that permits deletion or terminal-ID reconciliation.
    func resume() { update(machines: Array(machines.values)) }

    func accept(_ snapshot: [AgentSummary], on machine: Machine) {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        machines[machine.id] = machine
        store.reconcile(machineID: machine.id, herdrMachineID: nil, panes: snapshot)
        panes = panes.filter { !$0.key.isOn(machineID: machine.id, herdrMachineID: nil) }
        for pane in snapshot where pane.herdrMachine == nil { panes[BrowserKey(machine: machine, pane: pane)] = pane.terminalID }
        acceptedSnapshot?(snapshot, machine)
    }

    func resolve(_ route: CDPRoute) -> ResolvedPane? {
        guard ShepherdBrowserFeature.shared.isEnabled else { return nil }
        var candidates: [ResolvedPane] = []
        for machine in machines.values where machine.isLocal && BrowserKey.session(named: machine.sessionName) == route.session {
            let requested = BrowserKey(machineID: machine.id, herdrMachineID: nil, session: route.session, paneID: route.pane)
            guard let key = store.canonicalKey(for: requested), let terminal = panes[key] else { continue }
            candidates.append(ResolvedPane(key: key, terminalID: terminal))
        }
        // Two configured aliases of the same local session are ambiguous;
        // reject rather than infer a Machine from the unqualified URL.
        return candidates.count == 1 ? candidates[0] : nil
    }

    func stop() { polling.values.forEach { $0.cancel() }; polling = [:] }
}
#endif
