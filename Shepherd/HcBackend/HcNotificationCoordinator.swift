import SwiftUI
import AppKit
import CryptoKit

@MainActor protocol HcNotificationsPresenting: AnyObject {
    func becomeHcDelegate(onOpen: @escaping (HcNotificationRoute) -> Void)
    func authorization() async -> NotificationAuthorization
    func badgesAreOff() async -> Bool
    func requestAuthorization() async -> NotificationAuthorization
    func presentHc(identifier: String, content: NotificationText.Content, route: HcNotificationRoute) async -> Bool
    func retract(identifiers: [String])
    func retractHc(machineIDs: Set<UUID>, before: Date?) async
    func setBadge(_ count: Int)
    func clearBadgeBeforeQuitting()
}
extension UserNotificationPresenter: HcNotificationsPresenting {}

/// Product notifications use only hc read/subscription APIs, independently of
/// the visible board. No MachineMonitor/HerdrClient, agent injection or native
/// authority derived from status/PID. OS presentation stays in the presenter.
@MainActor @Observable final class HcNotificationCoordinator {
    static let shared = HcNotificationCoordinator()
    static var isAvailable: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return !["SHEPHERD_HC_UI_ROOT", "SHEPHERD_OWNED_OPERATOR_ROOT", "SHEPHERD_BROWSER_TEST_ROOT"].contains { env[$0] != nil }
        #else
        return true
        #endif
    }
    let preferences: NotificationPreferences
    @ObservationIgnored private let available: Bool
    @ObservationIgnored private let connect: @MainActor (MachineStore, Machine) async throws -> CoreRPCConnection
    private(set) var authorization: NotificationAuthorization = .unknown
    private(set) var badgesAreOff = false
    private(set) var coverageNotice: String?
    var navigationRequest: HcNotificationRoute?
    @ObservationIgnored var machineStore: MachineStore?
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored private let presenter: any HcNotificationsPresenting
    @ObservationIgnored private var started = false
    private struct Watch {
        let id: UUID; let machine: Machine; let task: Task<Void,Never>
    }
    @ObservationIgnored private var watches: [UUID: Watch] = [:]
    @ObservationIgnored private var monitors: [UUID: HcAttentionMonitor] = [:]
    @ObservationIgnored private var counts: [UUID:Int] = [:]
    @ObservationIgnored private var viewed: [UUID:(core: String, ids: Set<String>)] = [:]
    @ObservationIgnored private var shown: [String:(route: HcNotificationRoute, key: CoreAttentionFeed.Key)] = [:]
    @ObservationIgnored private var viewedGeneration = UUID()
    init(preferences: NotificationPreferences = NotificationPreferences(),
         presenter: any HcNotificationsPresenting = UserNotificationPresenter(),
         available: Bool = HcNotificationCoordinator.isAvailable,
         connect: @escaping @MainActor (MachineStore, Machine) async throws -> CoreRPCConnection = { try await $0.makeHcConnection(for: $1) }) {
        self.preferences = preferences; self.presenter = presenter; self.available = available; self.connect = connect
    }
    func stop() async {
        started = false
        let old = watches.values.map(\.task); watches.removeAll()
        for task in old { task.cancel() }
        for task in old { await task.value }
        monitors.removeAll(); counts.removeAll(); viewed.removeAll()
        presenter.retract(identifiers: Array(shown.keys)); shown.removeAll(); badge()
    }

    func prepare() {
        guard available else { return }
        presenter.becomeHcDelegate { [weak self] route in
            guard let self, let store = self.machineStore, store.allMachines.contains(where: { $0.id == route.machineID }) else { return }
            store.activeMachineID = route.machineID
            self.navigationRequest = route; self.openWindow?(id: "main"); NSApp.activate()
        }
    }
    func start() {
        guard available, !started else { return }
        started = true; track(); refreshAuthorization()
        let startedAt = Date()
        if let store = machineStore { Task { await presenter.retractHc(machineIDs: Set(store.allMachines.map(\.id)), before: startedAt) } }
    }
    private func track() {
        guard started, let store = machineStore else { return }
        let selection = withObservationTracking {
            (store.allMachines, preferences.kinds.any, preferences.showsBadge, preferences.mutedMachineIDs)
        } onChange: { [weak self] in Task { @MainActor in self?.track() } }
        let eligible = selection.0.filter { !selection.3.contains($0.id) }
        coverageNotice = eligible.count > 32 ? "Notifications monitor at most 32 enabled trusted machine connections. Additional machines are not monitored." :
            eligible.contains(where: { !$0.isLocal && $0.pinnedHostKeyFingerprint == nil }) ? "Hosts awaiting SSH key approval are not monitored for notifications." : nil
        let machines = selection.0.filter { !selection.3.contains($0.id) && ($0.isLocal || $0.pinnedHostKeyFingerprint != nil) }
        let desired = (selection.1 || selection.2) && authorization != .denied ? Array(machines.prefix(32)) : []
        let ids = Set(desired.map(\.id))
        for (id, watch) in watches {
            let replacement = desired.first { $0.id == id }
            if replacement?.connectionIdentity != watch.machine.connectionIdentity || replacement?.pinnedHostKeyFingerprint != watch.machine.pinnedHostKeyFingerprint {
                watches[id] = nil; watch.task.cancel(); monitors[id] = nil; counts[id] = nil
                let identifiers = shown.filter { $0.value.route.machineID == id }.map(\.key)
                presenter.retract(identifiers: identifiers)
                for key in identifiers { shown[key] = nil }
            }
        }
        let disabled = shown.filter { !allows($0.value.key.kind) || selection.3.contains($0.value.route.machineID) }.map(\.key)
        presenter.retract(identifiers: disabled); for key in disabled { shown[key] = nil }
        for machine in desired where watches[machine.id] == nil {
            let id = UUID()
            let task = Task<Void,Never> { [weak self] in guard let self else { return }; await self.watch(machine, id: id) }
            watches[machine.id] = Watch(id: id, machine: machine, task: task)
        }
        counts = counts.filter { ids.contains($0.key) }; badge()
        let muted = preferences.mutedMachineIDs
        Task { await presenter.retractHc(machineIDs: muted, before: nil) }
    }
    private func current(_ machine: Machine, id: UUID) -> Bool {
        watches[machine.id]?.id == id && machineStore?.isCurrentConnection(machine) == true && !preferences.isMuted(machine.id)
    }
    private func watch(_ machine: Machine, id: UUID) async {
        var retry: Int64 = 2
        while current(machine, id: id), !Task.isCancelled {
            var rpc: CoreRPCConnection?
            do {
                guard let store = machineStore else { return }
                let connection = try await connect(store, machine); rpc = connection
                guard current(machine, id: id), !Task.isCancelled else { throw CancellationError() }
                let monitor = try await HcAttentionMonitor(connection: connection)
                monitors[machine.id] = monitor
                if let view = viewed[machine.id], view.core == monitor.coreID { _ = try await monitor.setViewed(view.ids) }
                retry = 2
                try await monitor.run(state: { [weak self] state in
                    await self?.observed(state, machine: machine, id: id)
                }, attention: { [weak self, monitor] candidate, _ in
                    guard let self else { return false }
                    return await self.present(candidate, machine: machine, id: id, monitor: monitor)
                })
            } catch { /* Retry reads only, with a new epoch/baseline. No mutation replay. */ }
            do { try await rpc?.close() } catch { return } // Never reconnect past unconfirmed cleanup.
            guard current(machine, id: id), !Task.isCancelled else { return }
            monitors[machine.id] = nil; counts[machine.id] = nil; badge()
            let old = shown.filter { $0.value.route.machineID == machine.id }.map(\.key)
            presenter.retract(identifiers: old); for key in old { shown[key] = nil }
            do { try await Task.sleep(for: .seconds(retry)) } catch { return }
            retry = min(60, retry * 2)
        }
    }
    private func observed(_ state: HcAttentionMonitor.View, machine: Machine, id: UUID) {
        guard current(machine, id: id) else { return }
        counts[machine.id] = state.unreadBlocked; badge()
        let obsolete = shown.filter { _, value in
            guard value.route.machineID == machine.id else { return false }
            guard let record = state.terminals.first(where: { $0.address == value.route.terminalID }) else { return true }
            if viewed[machine.id]?.ids.contains(record.address) == true { return true }
            switch value.key.kind {
            case .blocked: return !["blocked", "error"].contains(record.status?.state ?? "") || record.status_ms != value.key.timestamp
            case .done: return record.status?.state != "done" || record.status_ms != value.key.timestamp
            case .exitedWhileWorking: return record.state != "finished" || record.finished_ms != value.key.timestamp
            }
        }.map(\.key)
        presenter.retract(identifiers: obsolete); for key in obsolete { shown[key] = nil }
    }
    private func allows(_ kind: CoreAttentionFeed.Kind) -> Bool {
        switch kind {
        case .blocked: preferences.notifiesNeedsInput
        case .done: preferences.notifiesFinished
        case .exitedWhileWorking: preferences.notifiesExited
        }
    }
    private func present(_ candidate: CoreAttentionFeed.Candidate, machine: Machine, id: UUID, monitor: HcAttentionMonitor) async -> Bool {
        guard current(machine, id: id) else { return false }
        guard allows(candidate.key.kind) else { return false }
        authorization = await presenter.authorization()
        if authorization == .notDetermined { authorization = await presenter.requestAuthorization() }
        guard authorization == .allowed, current(machine, id: id), allows(candidate.key.kind),
              (try? await monitor.confirm(candidate)) != nil else { return false }
        let route = HcNotificationRoute(machineID: machine.id, coreID: monitor.coreID, terminalID: candidate.key.terminal.terminalID)
        let hash = SHA256.hash(data: Data((machine.id.uuidString + ":" + route.coreID + ":" + route.terminalID).utf8)).map { String(format:"%02x",$0) }.joined()
        let title: String
        switch candidate.key.kind {
        case .blocked: title = "Program reports that it needs input"
        case .done: title = "Program reports that it is done"
        case .exitedWhileWorking: title = "Program exited while reporting work"
        }
        let displayName = (try? machineStore?.currentMachine(matching: machine).displayName) ?? machine.displayName
        let delivered = await presenter.presentHc(identifier: hash, content: .init(title: title, subtitle: displayName, body: route.terminalID), route: route)
        if delivered, current(machine, id: id), allows(candidate.key.kind), viewed[machine.id]?.ids.contains(route.terminalID) != true {
            shown[hash] = (route, candidate.key)
        } else if delivered { presenter.retract(identifiers: [hash]) }
        return delivered
    }
    func setViewed(machine: Machine?, coreID: String?, terminalIDs: Set<String> = []) async {
        guard available else { return }
        let generation = UUID(); viewedGeneration = generation
        viewed.removeAll()
        if let machine, let coreID { viewed[machine.id] = (coreID, terminalIDs) }
        for (id, monitor) in monitors {
            let ids = viewed[id].flatMap { $0.core == monitor.coreID ? $0.ids : nil } ?? []
            _ = try? await monitor.setViewed(ids)
            guard viewedGeneration == generation else { return }
        }
    }
    private func badge() {
        guard available else { return }
        presenter.setBadge(preferences.showsBadge && authorization == .allowed ? counts.values.reduce(0,+) : 0)
    }
    func refreshAuthorization() {
        guard available else { return }
        Task { authorization = await presenter.authorization(); badgesAreOff = await presenter.badgesAreOff(); track(); badge() }
    }
    func requestAuthorization() {
        guard available else { return }
        Task { authorization = await presenter.requestAuthorization(); badgesAreOff = await presenter.badgesAreOff(); track(); badge() }
    }
    func clearBadgeBeforeQuitting() { if available { presenter.clearBadgeBeforeQuitting() } }
}
