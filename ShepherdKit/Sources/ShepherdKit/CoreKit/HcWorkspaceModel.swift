import Foundation
import Observation

private nonisolated struct HcWorkspaceTerminalInitial: Decodable, Sendable { let terminals: [HcTerminalRecord] }

/// The hc workspace screen's model. Composes actual RPC/event storage, device
/// focus and durable partial-operation recovery — not a HerdrClient adapter.
/// One instance per connection scope; no fallback to the legacy backend.
@MainActor @Observable public final class HcWorkspaceModel {
    public enum State: Equatable { case idle, connecting, connected, failed, closed }
    public enum Failure: Error, Equatable { case unavailable, stale, conflict, uncertain, recoveryRequired }
    public struct OperationReview: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let record: CoreWorkspaceRecovery.Record
        public let expectedVersion: UInt64
        public let canApplyLayout: Bool
        fileprivate let generation: UUID
    }
    public private(set) var operationReview: OperationReview?
    public private(set) var state: State = .idle
    public private(set) var workspace: CoreWorkspaceStore.View?
    public private(set) var terminals: [HcTerminalRecord] = []
    public private(set) var focus = CoreWorkspaceFocus()
    public private(set) var recoveryRecords: [CoreWorkspaceRecovery.Record] = []
    public private(set) var operationBusy = false
    public private(set) var failure: Failure?
    public private(set) var coreID: String?
    @ObservationIgnored private let connection: CoreRPCConnection
    @ObservationIgnored private var store: CoreWorkspaceStore?
    @ObservationIgnored private var journal: CoreWorkspaceRecovery?
    @ObservationIgnored private var events: CoreStream?
    @ObservationIgnored private var documentTask: Task<Void, Never>?
    @ObservationIgnored private var terminalTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let savedRecovery: Data?
    @ObservationIgnored private let savedFocus: Data?
    @ObservationIgnored private let saveRecovery: @Sendable (Data) throws -> Void
    @ObservationIgnored private let saveFocus: (Data) throws -> Void

    public init(connection: CoreRPCConnection, savedRecovery: Data? = nil, savedFocus: Data? = nil,
                saveRecovery: @escaping @Sendable (Data) throws -> Void, saveFocus: @escaping (Data) throws -> Void) {
        self.connection = connection; self.savedRecovery = savedRecovery; self.savedFocus = savedFocus
        self.saveRecovery = saveRecovery; self.saveFocus = saveFocus
    }
    isolated deinit {
        documentTask?.cancel(); terminalTask?.cancel()
        let store = store, events = events, connection = connection
        Task { try? await events?.close(); try? await store?.close(); try? await connection.close() }
    }
    /// One read-only compound reply; never joins terminal records to an alias
    /// directory from a different moment. No remote layout, attach or mutation.
    public func readGatewayDirectory() async throws -> HcGatewaySnapshot {
        guard state == .connected else { throw Failure.unavailable }
        let token = generation
        let snapshot = try await HcGatewaySnapshot.read(connection: connection)
        guard token == generation, state == .connected, snapshot.hub.id == coreID,
              snapshot.epoch == connection.epoch else { throw Failure.stale }
        return snapshot
    }
    public var document: CoreWorkspaceDocument? { workspace?.snapshot?.document }
    public var canEdit: Bool { state == .connected && workspace?.canWrite == true && !operationBusy && operationReview == nil }
    public func canApply(_ review: OperationReview) -> Bool {
        state == .connected && !operationBusy && operationReview?.id == review.id && review.generation == generation
            && review.canApplyLayout && workspace?.canWrite == true && workspace?.snapshot?.version == review.expectedVersion
    }
    public var selectedTab: CoreWorkspaceDocument.Tab? {
        guard let id = focus.workspaceID, let tabID = focus.tabByWorkspace[id] else { return nil }
        return document?.workspaces.first(where: { $0.id == id })?.tabs.first(where: { $0.id == tabID })
    }
    public func start() async throws {
        guard state == .idle else { throw Failure.stale }
        state = .connecting
        let token = generation
        do {
            let hello: CoreHello
            if await connection.state == .idle { hello = try await connection.connect() }
            else if let existing = await connection.hello { hello = existing }
            else { throw Failure.unavailable }
            guard token == generation else { throw Failure.stale }
            coreID = hello.core.id
            if let savedFocus { focus = try CoreWorkspaceFocus.restore(savedFocus, coreID: hello.core.id) }
            let journal = try CoreWorkspaceRecovery(coreID: hello.core.id, epoch: connection.epoch, restoring: savedRecovery, persist: saveRecovery)
            self.journal = journal; recoveryRecords = await journal.snapshot()
            let store = try await CoreWorkspaceStore(connection: connection)
            self.store = store
            let updates = try await store.updates()
            let initial = try await store.start()
            guard token == generation else { try await store.close(); throw Failure.stale }
            apply(initial)
            let events = try await connection.openStream("events.subscribe")
            guard token == generation else { try await events.close(); throw Failure.stale }
            self.events = events
            let baseline: HcWorkspaceTerminalInitial = try events.initialReply.result()
            terminals = try Self.direct(baseline.terminals)
            state = .connected
            documentTask = Task { [weak self] in
                for await _ in updates {
                    guard let self, self.generation == token else { return }
                    // A queued view may predate an explicit refresh/commit.
                    // Read the store's current full view instead of regressing.
                    let current = await store.view()
                    guard self.generation == token else { return }
                    self.apply(current)
                }
            }
            let connection = connection
            terminalTask = Task { [weak self] in
                do {
                    var lines = try CoreEventLines(maximumLineBytes: 1 << 20)
                    while let packet = try await events.next(timeout: .seconds(45)) {
                        guard packet.frame.kind == .data else { break }
                        var changed = false
                        try lines.receive(packet.frame.payload) { bytes in
                            struct Notice: Decodable {
                                struct Params: Decodable { let type: String? }
                                let jsonrpc: String; let method: String; let params: Params
                            }
                            let note = try JSONDecoder().decode(Notice.self, from: bytes)
                            guard note.jsonrpc == "2.0", ["event","missed","snapshot","heartbeat"].contains(note.method) else { throw Failure.unavailable }
                            changed = changed || note.method == "missed" || note.method == "snapshot" || (note.method == "event" && note.params.type != "doc")
                        }
                        if changed {
                            let list = try await HcTerminalBoard(connection: connection).list(all: true)
                            guard let self, self.generation == token else { return }
                            self.terminals = try Self.direct(list)
                        }
                        try await events.acknowledge(packet)
                    }
                    try lines.finish()
                    throw Failure.unavailable
                } catch {
                    guard let self, self.generation == token else { return }
                    self.state = .failed; self.failure = .unavailable
                    try? await events.close()
                }
            }
        } catch {
            if token == generation { state = .failed; failure = .unavailable }
            try await disconnect(markClosed: false)
            throw error
        }
    }
    private static func direct(_ records: [HcTerminalRecord]) throws -> [HcTerminalRecord] {
        guard records.count <= 4096 else { throw CoreWorkspaceFailure.limitExceeded }
        let result = records.filter { !$0.address.contains("/") }
        guard Set(result.map(\.address)).count == result.count else { throw CoreWorkspaceFailure.invalidReference }
        return result
    }
    private func apply(_ view: CoreWorkspaceStore.View) {
        workspace = view
        // Never clear focus based on unavailable data or another origin.
        focus.reconcile(view.snapshot)
        if let coreID, let bytes = try? focus.encoded(coreID: coreID) { try? saveFocus(bytes) }
        if view.phase == .failed { state = .failed; failure = .unavailable }
    }
    public func select(tab: UUID) throws {
        guard state == .connected, let document else { throw Failure.unavailable }
        try focus.select(tab: tab, in: document); try persistFocus()
    }
    public func select(pane: UUID) throws {
        guard state == .connected, let document else { throw Failure.unavailable }
        try focus.select(pane: pane, in: document); try persistFocus()
    }
    public func zoom(pane: UUID?) throws {
        guard state == .connected, let document else { throw Failure.unavailable }
        try focus.zoom(pane: pane, in: document); try persistFocus()
    }
    private func persistFocus() throws { if let coreID { try saveFocus(focus.encoded(coreID: coreID)) } }
    private func baseline() throws -> (CoreWorkspaceStore, CoreWorkspaceCAS.Snapshot) {
        guard state == .connected, workspace?.canWrite == true, let store, let snapshot = workspace?.snapshot else { throw Failure.unavailable }
        return (store, snapshot)
    }
    private func commit(_ edit: CoreWorkspaceEdit, snapshot: CoreWorkspaceCAS.Snapshot, store: CoreWorkspaceStore) async throws {
        let token = generation
        let result = try await store.edit(edit, expectedVersion: snapshot.version)
        guard token == generation else { throw Failure.stale }
        let latest = try await store.refresh()
        guard token == generation else { throw Failure.stale }
        apply(latest)
        switch result {
        case .acknowledged: break
        case .conflict: failure = .conflict; throw Failure.conflict
        case .uncertain: failure = .uncertain; throw Failure.uncertain
        }
    }
    @discardableResult public func createWorkspace(name: String) async throws -> UUID {
        guard !operationBusy else { throw Failure.unavailable }
        let (store, snapshot) = try baseline(), workspace = CoreWorkspaceDocument.Workspace(name: name)
        operationBusy = true; defer { operationBusy = false }
        try await commit(.appendWorkspace(workspace), snapshot: snapshot, store: store)
        if let document { try focus.select(workspace: workspace.id, in: document); try persistFocus() }
        return workspace.id
    }
    public func renameTab(_ id: UUID, name: String) async throws {
        guard !operationBusy else { throw Failure.unavailable }
        let (store, snapshot) = try baseline()
        operationBusy = true; defer { operationBusy = false }
        try await commit(.renameTab(id, name), snapshot: snapshot, store: store)
    }
    public func renamePane(_ id: UUID, name: String) async throws {
        guard !operationBusy else { throw Failure.unavailable }
        let (store, snapshot) = try baseline()
        operationBusy = true; defer { operationBusy = false }
        try await commit(.renamePane(id, name), snapshot: snapshot, store: store)
    }
    /// Creates placeholder metadata BEFORE launching. The run is sent once and
    /// bound via a journaled CAS attempt. Any uncertain outcome remains visible
    /// in recoveryRecords. No label-based adoption, automatic rerun or kill.
    public func launchTab(workspaceID: UUID, name: String, argv: [String], cwd: String? = nil) async throws {
        guard !operationBusy, let journal else { throw Failure.unavailable }
        let (store, snapshot) = try baseline(), pane = CoreWorkspaceDocument.Pane()
        let tab = CoreWorkspaceDocument.Tab(name: name, layout: .leaf(pane))
        let token = generation
        operationBusy = true; defer { operationBusy = false }
        try await commit(.appendTab(workspace: workspaceID, tab: tab), snapshot: snapshot, store: store)
        guard token == generation, let document else { throw Failure.stale }
        try focus.select(tab: tab.id, in: document); try persistFocus()
        try await launchInto(pane: pane, argv: argv, cwd: cwd ?? document.workspaces.first(where: { $0.id == workspaceID })?.cwd, journal: journal, store: store, token: token)
    }
    public func launchSplit(paneID: UUID, axis: CoreWorkspaceDocument.Axis, argv: [String], cwd: String? = nil) async throws {
        guard !operationBusy, let journal else { throw Failure.unavailable }
        let (store, snapshot) = try baseline(), pane = CoreWorkspaceDocument.Pane(), token = generation
        operationBusy = true; defer { operationBusy = false }
        try await commit(.splitPane(paneID, axis: axis, ratio: 0.5, newPane: pane), snapshot: snapshot, store: store)
        guard token == generation, let document else { throw Failure.stale }
        try focus.select(pane: pane.id, in: document); try persistFocus()
        try await launchInto(pane: pane, argv: argv, cwd: cwd, journal: journal, store: store, token: token)
    }
    private func launchInto(pane: CoreWorkspaceDocument.Pane, argv: [String], cwd: String?, journal: CoreWorkspaceRecovery, store: CoreWorkspaceStore, token: UUID) async throws {
        guard token == generation, let document else { throw Failure.stale }
        let ticket = try await journal.beginLaunch(paneID: pane.id, document: document)
        do {
            guard token == generation else { throw Failure.stale }
            let terminal = try await HcTerminalBoard(connection: connection).run(argv: argv, cwd: cwd, labels: ticket.label)
            // Save the receipt even if the screen disconnected during run.
            try await journal.finishLaunch(ticket, terminal: .init(coreID: journal.coreID, terminalID: terminal.address))
        } catch {
            // A failed persistence may have already left an in-flight record;
            // restore treats it as uncertain. Never try terminal.run again.
            try? await journal.finishLaunch(ticket, terminal: nil)
            recoveryRecords = await journal.snapshot(); failure = .uncertain; throw error
        }
        guard token == generation else { recoveryRecords = await journal.snapshot(); throw Failure.stale }
        let latest = try await store.refresh()
        guard token == generation else { throw Failure.stale }
        apply(latest)
        guard latest.canWrite, let fresh = latest.snapshot else { recoveryRecords = await journal.snapshot(); throw Failure.recoveryRequired }
        let attempt = try await journal.prepareLayoutAfterReview(ticket, snapshot: fresh)!
        let result: CoreWorkspaceCAS.WriteResult
        do { result = try await store.edit(attempt.edit, expectedVersion: attempt.expectedVersion) }
        catch { try? await journal.finishLayout(attempt, result: .uncertain); recoveryRecords = await journal.snapshot(); throw error }
        try await journal.finishLayout(attempt, result: result)
        recoveryRecords = await journal.snapshot()
        guard token == generation else { throw Failure.stale }
        let refreshed = try await store.refresh()
        guard token == generation else { throw Failure.stale }
        apply(refreshed)
        if case .acknowledged = result { return }
        failure = .recoveryRequired; throw Failure.recoveryRequired
    }
    /// Explicitly show a freshly fetched canonical terminal. This is a new view,
    /// not adoption from operation labels or a retry of an uncertain launch.
    public func showTerminal(_ address: String, workspaceID: UUID) async throws {
        guard !operationBusy else { throw Failure.unavailable }
        let (store, snapshot) = try baseline(), token = generation
        operationBusy = true; defer { operationBusy = false }
        let record = try await HcTerminalBoard(connection: connection).get(address)
        guard token == generation, record.address == address, record.state == "live", let coreID else { throw Failure.stale }
        let pane = CoreWorkspaceDocument.Pane(terminal: .init(coreID: coreID, terminalID: record.address))
        let tab = CoreWorkspaceDocument.Tab(name: record.name ?? record.address, layout: .leaf(pane))
        try await commit(.appendTab(workspace: workspaceID, tab: tab), snapshot: snapshot, store: store)
        if let document { try focus.select(tab: tab.id, in: document); try persistFocus() }
    }
    public func closePane(_ id: UUID) async throws {
        guard !operationBusy else { throw Failure.unavailable }
        let (store, snapshot) = try baseline()
        operationBusy = true; defer { operationBusy = false }
        try await commit(.removePane(id), snapshot: snapshot, store: store)
    }
    /// Closing the tab hides its views, not its programs. Termination must be a
    /// separate explicit user action; no unreviewed batch kill is dispatched.
    public func closeTab(_ id: UUID) async throws {
        guard !operationBusy, let journal else { throw Failure.unavailable }
        let (store, snapshot) = try baseline(), token = generation
        guard let document = snapshot.document else { throw Failure.unavailable }
        operationBusy = true; defer { operationBusy = false }
        let ticket = try await journal.beginClose(tabID: id, document: document, endPrograms: false)
        let attempt = try await journal.prepareLayoutAfterReview(ticket, snapshot: snapshot)!
        do {
            let result = try await store.edit(attempt.edit, expectedVersion: attempt.expectedVersion)
            try await journal.finishLayout(attempt, result: result)
            recoveryRecords = await journal.snapshot()
            if case .acknowledged = result {} else { throw Failure.recoveryRequired }
            let refreshed = try await store.refresh()
            guard token == generation else { throw Failure.stale }
            apply(refreshed)
        } catch { try? await journal.finishLayout(attempt, result: .uncertain); recoveryRecords = await journal.snapshot(); throw error }
    }
    /// Reading/reconciling is separate from a new human-approved layout CAS.
    /// This never reruns a launch, looks up operation labels or dispatches kills.
    public func prepareOperationReview(_ operationID: UUID) async throws -> OperationReview {
        guard state == .connected, !operationBusy, operationReview == nil, let journal, let store else { throw Failure.unavailable }
        let token = generation
        operationBusy = true; defer { operationBusy = false }
        let latest = try await store.refresh()
        guard token == generation, latest.canWrite, latest.originCoreID == journal.coreID,
              let snapshot = latest.snapshot else { throw Failure.stale }
        apply(latest)
        guard let before = await journal.snapshot().first(where: { $0.id == operationID }) else { throw CoreWorkspaceRecoveryFailure.staleTicket }
        if before.layout != .confirmed {
            try await journal.retireInFlightForReview(operationID)
            try await journal.reconcileLayout(operationID: operationID, snapshot: snapshot)
        }
        let records = await journal.snapshot()
        guard token == generation, let record = records.first(where: { $0.id == operationID }) else { throw Failure.stale }
        recoveryRecords = records
        let applicable = try await journal.canReapplyLayoutAfterReview(operationID, snapshot: snapshot)
        guard token == generation else { throw Failure.stale }
        let review = OperationReview(id: UUID(), record: record, expectedVersion: snapshot.version, canApplyLayout: applicable, generation: token)
        operationReview = review
        return review
    }
    public func cancelOperationReview(_ review: OperationReview) {
        guard !operationBusy, operationReview?.id == review.id else { return }
        operationReview = nil
    }
    public func applyOperationReview(_ review: OperationReview) async throws {
        guard canApply(review), let journal, let store else { throw Failure.stale }
        let token = generation
        operationBusy = true
        defer { operationBusy = false; operationReview = nil }
        let current = await store.view()
        guard token == generation, current.canWrite, current.originCoreID == journal.coreID, let snapshot = current.snapshot,
              snapshot.version == review.expectedVersion else { throw Failure.stale }
        let attempt = try await journal.prepareRebasedLayoutAfterReview(review.record.id, snapshot: snapshot)
        let result: CoreWorkspaceCAS.WriteResult
        do { result = try await store.edit(attempt.edit, expectedVersion: review.expectedVersion) }
        catch {
            try? await journal.finishLayout(attempt, result: .uncertain)
            recoveryRecords = await journal.snapshot(); failure = .recoveryRequired; throw error
        }
        try await journal.finishLayout(attempt, result: result)
        recoveryRecords = await journal.snapshot()
        guard token == generation else { throw Failure.stale }
        let refreshed = try await store.refresh()
        guard token == generation else { throw Failure.stale }
        apply(refreshed)
        if case .acknowledged = result { return }
        failure = .recoveryRequired; throw Failure.recoveryRequired
    }
    /// Forget tracking only. It is never program termination or a quota eviction.
    public func forgetOperationReview(_ review: OperationReview) async throws {
        guard state == .connected, !operationBusy, operationReview?.id == review.id,
              review.generation == generation, let journal else { throw Failure.stale }
        operationBusy = true; defer { operationBusy = false; operationReview = nil }
        try await journal.forgetAfterUserReview(review.record.id)
        recoveryRecords = await journal.snapshot()
    }

    /// An attach may only be made from this live connection and a reference in
    /// this document. This is UI scoping, NOT native/browser authorization.
    public func session(for pane: CoreWorkspaceDocument.Pane) throws -> HcTerminalSession {
        guard state == .connected, let ref = pane.terminal, ref.coreID == coreID,
              document?.pane(pane.id)?.terminal == ref else { throw Failure.unavailable }
        return HcTerminalSession(connection: connection, terminalID: ref.terminalID)
    }
    public func disconnect(markClosed: Bool = true) async throws {
        generation = UUID(); operationReview = nil
        if markClosed { state = .closed }
        let docTask = documentTask, termTask = terminalTask, events = events, store = store
        documentTask = nil; terminalTask = nil; self.events = nil; self.store = nil
        docTask?.cancel(); termTask?.cancel()
        var error: (any Error)?
        do { try await events?.close() } catch let caught { error = caught }
        do { try await store?.close() } catch let caught { error = caught }
        do { try await connection.close() } catch let caught { error = caught }
        await docTask?.value; await termTask?.value
        if let error { throw error }
    }
}
