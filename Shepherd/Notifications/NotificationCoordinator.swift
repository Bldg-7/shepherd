import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Tells the person, with a notification, when an agent on any of their
/// machines needs their input or has finished — and takes the notification
/// back once they are looking at the pane, or the agent has gone back to
/// work. One for the app, running from launch to quit, window or no window.
///
/// What it is told:
/// - Snapshots, from the `MachineMonitor` of every machine — the same ones
///   the board shows, read over the same connection — each through a
///   `NotificationFeed`. It has `MachineMonitors` keep every machine's
///   monitor running while there is anything to look for (see `reconcile`),
///   window or no window.
/// - Which panes the person is looking at (`setViewedPanes`).
///
/// What it does with a snapshot: an `AgentEventDeriver` per herdr server
/// turns it into events; each event is checked again
/// `confirmationDelay` later, over the connection it came over, and is
/// dropped unless the pane is still as it says — herdr's own notifications
/// wait for a status to hold too. What holds goes through
/// `NotificationPolicy`, and is shown by `UserNotificationPresenter`, in
/// place of what was shown for the same pane before. A click takes the
/// person to the pane (`navigationRequest`).
@MainActor @Observable
final class NotificationCoordinator {
    static let shared = NotificationCoordinator()

    /// Whether this run of the app gives notifications at all: not the
    /// fixtures debug builds run for tests, which have no person to notify
    /// and no business asking for permission.
    static let isAvailable: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return !["SHEPHERD_BROWSER_FEATURE_FIXTURE", "SHEPHERD_AGENT_LAUNCH_FIXTURE", "SHEPHERD_NATIVE_B_PROBE",
                 "SHEPHERD_BROWSER_PHASE2_FIXTURE", "SHEPHERD_BROWSER_SELFTEST", "SHEPHERD_OWNED_OPERATOR_ROOT"]
            .contains { environment[$0] != nil }
        #else
        return true
        #endif
    }()

    /// How long an event has to hold before it is shown.
    static let confirmationDelay: Duration = .milliseconds(1500)
    /// How long a click on a notification waits for its pane to be listed.
    private static let navigationTimeout: Duration = .seconds(15)
    /// How long the machines and the preferences are left to settle before
    /// the monitors are told which machines to watch: an edit can change
    /// them several times in a row, and a monitor shouldn't connect and
    /// disconnect for each.
    private static let reconcileDelay: Duration = .seconds(1)

    let preferences = NotificationPreferences()
    private(set) var authorization: NotificationAuthorization = .unknown
    /// The pane of the notification last clicked, until the window has
    /// selected it or given up.
    var navigationRequest: NotificationNavigationRequest?

    /// The app's machines, set before launch finishes (see `ShepherdApp`).
    @ObservationIgnored var machineStore: MachineStore?
    /// What opens the app's one window again once it has been closed, from
    /// the window when it first appears.
    @ObservationIgnored var openWindow: OpenWindowAction?

    @ObservationIgnored private let presenter = UserNotificationPresenter()
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var machines: [Machine] = []
    @ObservationIgnored private var derivers: [NotificationServerKey: AgentEventDeriver] = [:]
    @ObservationIgnored private var viewedPanes: Set<NotificationPaneKey> = []
    /// What is shown, by notification identifier (the event's
    /// `collapse_key`), with the pane it is about.
    @ObservationIgnored private var shown: [String: (pane: NotificationPaneKey, at: Date)] = [:]
    /// When a kind of notification was last shown for a pane.
    @ObservationIgnored private var lastPresented: [String: Date] = [:]
    /// The events dealt with lately, oldest first, so that none is dealt
    /// with twice.
    @ObservationIgnored private var handledEventIDs: [String] = []
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var madeProducer: AgentEvent.Producer?

    private init() {}

    /// This installation of Shepherd, as the producer of the events it
    /// makes — with an ID of its own, made the first time one is needed.
    private var producer: AgentEvent.Producer {
        if let madeProducer { return madeProducer }
        let instanceKey = "Notifications.producerInstance"
        let instance = UserDefaults.standard.string(forKey: instanceKey) ?? {
            let made = UUID().uuidString
            UserDefaults.standard.set(made, forKey: instanceKey)
            return made
        }()
        let producer = AgentEvent.Producer(kind: "shepherd-macos", version: AppVersion.current.version, instance: instance)
        madeProducer = producer
        return producer
    }

    // MARK: Lifecycle

    /// Becomes the one clicked notifications go to. Called while the app is
    /// launching, before it has finished.
    func prepare() {
        guard Self.isAvailable else { return }
        presenter.becomeDelegate { [weak self] route in
            self?.open(route)
        }
    }

    /// Starts watching, for as long as the app runs. Called once the app has
    /// finished launching, whether or not its window came up with it.
    func start() {
        guard Self.isAvailable, !isStarted, machineStore != nil else { return }
        isStarted = true
        trackMachines()
        trackPreferences()
        #if os(macOS)
        // Notifications may have been allowed, or turned off, in System
        // Settings while the app was in the background.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAuthorization() }
        }
        #endif
        refreshAuthorization()
    }

    /// Whether there is anything to look for: a kind of notification turned
    /// on, and macOS not refusing them.
    private var isWatching: Bool {
        preferences.kinds.any && authorization != .denied
    }

    /// Keeps `machines` up to date with the store, and the monitors with
    /// both. Observation tells of one change at a time: each takes looking
    /// again, which is what tells of the next.
    private func trackMachines() {
        guard let machineStore else { return }
        machines = withObservationTracking { machineStore.allMachines } onChange: {
            Task { @MainActor in NotificationCoordinator.shared.trackMachines() }
        }
        scheduleReconcile()
    }

    /// Starts or stops watching as kinds of notification are turned on and
    /// off.
    private func trackPreferences() {
        _ = withObservationTracking { preferences.kinds } onChange: {
            Task { @MainActor in NotificationCoordinator.shared.trackPreferences() }
        }
        scheduleReconcile()
    }

    func refreshAuthorization() {
        guard isStarted else { return }
        Task {
            update(authorization: await presenter.authorization())
        }
    }

    /// Asks macOS for permission, from the Notifications page in Settings.
    func requestAuthorization() {
        guard isStarted else { return }
        Task {
            update(authorization: await presenter.requestAuthorization())
        }
    }

    private func update(authorization status: NotificationAuthorization) {
        guard status != authorization else { return }
        authorization = status
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        guard isStarted else { return }
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.reconcileDelay)) != nil else { return }
            self?.reconcile()
        }
    }

    /// Has every machine watched — its monitor kept running whether or not
    /// the board shows it — or none, while there is nothing to look for. A
    /// monitor the board holds runs either way, and feeds the notifications
    /// all the same.
    private func reconcile() {
        guard let machineStore else { return }
        MachineMonitors.shared.watch(isWatching ? machines : [], in: machineStore)
    }

    // MARK: Events

    /// One snapshot of one herdr, from a `NotificationFeed`. `refetch` takes
    /// another over the same connection.
    func ingest(_ observations: [AgentObservation], from machine: Machine, on herdrMachine: HerdrMachine?, startsRun: Bool,
                refetch: @escaping @Sendable () async throws -> [AgentObservation]) {
        guard isStarted, let machineStore, machineStore.isCurrentConnection(machine), isWatching else { return }
        let server = NotificationServerKey(connection: machine.connectionIdentity, herdrMachineID: herdrMachine?.id)
        let now = Date()
        let herdr = eventSource(for: (try? machineStore.currentMachine(matching: machine)) ?? machine, on: herdrMachine)
        var deriver = derivers[server] ?? AgentEventDeriver(source: herdr)
        deriver.source = herdr
        let events = deriver.observe(observations, at: now, asBaseline: startsRun)
        derivers[server] = deriver
        forgetOldNews(now: now)
        for event in events {
            let route = NotificationRoute(machineID: machine.id, herdrMachineID: herdrMachine?.id,
                                          paneID: event.subject.paneID, terminalID: event.subject.terminalID)
            hold(event, on: server, route: route, refetch: refetch)
        }
    }

    /// The herdr a deriver looks at. Its instance ID is Shepherd's own ID
    /// for the machine, which means nothing on another device — hence
    /// `device_local` — followed by the herdr machine's profile ID for one
    /// of those.
    private func eventSource(for machine: Machine, on herdrMachine: HerdrMachine?) -> AgentEventSource {
        let instanceID = herdrMachine.map { "\(machine.id.uuidString)/\($0.id)" } ?? machine.id.uuidString
        let session = herdrMachine?.session ?? (machine.sessionName.isEmpty ? "default" : machine.sessionName)
        return AgentEventSource(
            herdr: AgentEvent.HerdrInstance(instanceID: instanceID, scope: .deviceLocal, session: session),
            machineLabel: herdrMachine?.label ?? machine.displayName,
            producer: producer
        )
    }

    /// Checks `event` again once it has had `confirmationDelay` to hold, and
    /// deals with it if it has. Nothing is checked for what would be
    /// dropped anyway.
    private func hold(_ event: AgentEvent, on server: NotificationServerKey, route: NotificationRoute,
                      refetch: @escaping @Sendable () async throws -> [AgentObservation]) {
        guard !handledEventIDs.contains(event.id) else { return }
        let pane = NotificationPaneKey(server: server, terminalID: event.subject.terminalID)
        switch decision(for: event, pane: pane, now: Date()) {
        case .present: break
        case .retract: guard shown[event.subject.collapseKey] != nil else { return }
        case .drop: return
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationDelay)
            let holds: Bool
            do {
                holds = AgentEventDeriver.stillHolds(event, in: try await refetch())
            } catch {
                // The connection it came over has gone — the machine's
                // monitor reconnected or stopped, say. Then the last look at
                // the pane, from wherever, has to do.
                holds = self?.derivers[server]?.latest(terminalID: event.subject.terminalID)
                    .map { AgentEventDeriver.stillHolds(event, in: [$0]) } ?? false
            }
            guard holds else { return }
            self?.deliver(event, pane: pane, route: route)
        }
    }

    private func deliver(_ event: AgentEvent, pane: NotificationPaneKey, route: NotificationRoute) {
        guard isStarted, !handledEventIDs.contains(event.id) else { return }
        handledEventIDs.append(event.id)
        let now = Date()
        let identifier = event.subject.collapseKey
        switch decision(for: event, pane: pane, now: now) {
        case .present:
            let showsMachine = machines.count > 1 || pane.server.herdrMachineID != nil
            guard let content = NotificationText.content(for: event, showsMachine: showsMachine) else { return }
            lastPresented[Self.presentationKey(event)] = now
            shown[identifier] = (pane, now)
            let thread = event.subject.herdr.instanceID
            Task {
                update(authorization: await presenter.present(identifier: identifier, content: content, route: route, threadIdentifier: thread))
            }
        case .retract:
            if shown.removeValue(forKey: identifier) != nil {
                presenter.retract(identifiers: [identifier])
            }
        case .drop:
            break
        }
    }

    private func decision(for event: AgentEvent, pane: NotificationPaneKey, now: Date) -> NotificationPolicy.Decision {
        NotificationPolicy.decide(event, enabled: preferences.kinds, isViewed: viewedPanes.contains(pane),
                                  lastPresented: lastPresented[Self.presentationKey(event)], now: now)
    }

    private static func presentationKey(_ event: AgentEvent) -> String {
        event.subject.collapseKey + " " + event.kind.rawValue
    }

    /// Lets go of what can't matter any more: herdrs not heard from in a
    /// while, notifications long since shown, events long since dealt with.
    private func forgetOldNews(now: Date) {
        derivers = derivers.filter { $0.value.lastObservedAt.map { now.timeIntervalSince($0) < 600 } ?? false }
        shown = shown.filter { now.timeIntervalSince($0.value.at) < AgentEventDeriver.lifetime }
        lastPresented = lastPresented.filter { now.timeIntervalSince($0.value) < NotificationPolicy.repeatInterval }
        if handledEventIDs.count > 1000 {
            handledEventIDs.removeFirst(handledEventIDs.count - 1000)
        }
    }

    // MARK: The person

    /// The panes on screen in front of the person: the selected pane, or
    /// every pane of the selected tab, while the window is key. Nothing is
    /// shown about them, and what was shown is taken back.
    func setViewedPanes(_ panes: Set<NotificationPaneKey>) {
        guard panes != viewedPanes else { return }
        viewedPanes = panes
        guard isStarted else { return }
        let seen = shown.filter { panes.contains($0.value.pane) }.map(\.key)
        guard !seen.isEmpty else { return }
        for identifier in seen {
            shown[identifier] = nil
        }
        presenter.retract(identifiers: seen)
    }

    /// A click on a notification: brings the window up and has it go to the
    /// pane (see `ContentView`).
    private func open(_ route: NotificationRoute) {
        #if os(macOS)
        NSApp.activate()
        if let openWindow {
            // The app's one window (`ShepherdApp`), opened again if it was
            // closed, brought forward if not.
            openWindow(id: "main")
        } else {
            Self.reopen()
        }
        #endif
        let request = NotificationNavigationRequest(route: route)
        navigationRequest = request
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.navigationTimeout)) != nil else { return }
            if self?.navigationRequest?.id == request.id {
                self?.navigationRequest = nil
            }
        }
    }

    #if os(macOS)
    /// What a click on the Dock icon does, for a window that hasn't been
    /// open in this run of the app and so left no way to open it.
    private static func reopen() {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: [.noReply], timeout: 1)
    }
    #endif
}
