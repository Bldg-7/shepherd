#if os(macOS)
import Foundation
import Observation

/// The app's sole launch/inspection/output consumer. Native browser ownership
/// and route admission remain in MachineBrowserService/BrowserStore/CDPProxy.
@MainActor @Observable
final class AgentLaunchService {
    #if DEBUG
    static let shared = OwnedOperatorFixture.launchService()
    #else
    static let shared = AgentLaunchService()
    #endif

    nonisolated struct HostContext: Sendable {
        let root: String
        let resources: String
        let node: String
        let claudeSettings: String
        let claudeSkills: String
        let codexHome: String
        let executionSearchPath: String?

        init(root: String, resources: String, node: String, claudeSettings: String,
             claudeSkills: String, codexHome: String, executionSearchPath: String? = nil) {
            self.root = root; self.resources = resources; self.node = node
            self.claudeSettings = claudeSettings; self.claudeSkills = claudeSkills
            self.codexHome = codexHome; self.executionSearchPath = executionSearchPath
        }

        static func thisMac(bundle: Bundle = .main) throws -> Self {
            let env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let executables = try AgentHostExecutables.resolve(home: home, environment: env)
            let claudeHome = env["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            #if DEBUG
            let name = "AgentRuntime-Debug"
            #else
            let name = "AgentRuntime"
            #endif
            return Self(root: support.appending(path: Bundle.main.bundleIdentifier ?? "com.bldg-7.shepherd").appending(path: name).path,
                        resources: try AgentSkillSetup.bundledResourceDirectory(in: bundle), node: executables.node,
                        claudeSettings: claudeHome + "/settings.json", claudeSkills: claudeHome + "/skills",
                        codexHome: env["CODEX_HOME"] ?? home + "/.codex", executionSearchPath: executables.searchPath)
        }

        func runtime(using client: HerdrClient) -> AgentRuntime {
            AgentSkillSetup.runtime(root: root, resources: resources, nodeExecutable: node,
                                    executionSearchPath: executionSearchPath, using: client)
        }
    }

    private struct Snapshot {
        let machine: Machine
        let panes: [AgentSummary]
        let received: ContinuousClock.Instant
    }
    private struct Inspection {
        let agent: AgentSummary
        let process: PaneProcessInfo
        let received: ContinuousClock.Instant
        /// What `process` was read against (AgentInspectionReuse).
        let pane: AgentSummary
        let row: AgentSummary?
        let processReceived: ContinuousClock.Instant
    }

    #if DEBUG
    /// Set only by the private owned fixture; never production logging.
    var resumeObservation: (([String: Any]) -> Void)?
    func fixturePiCoordinator(for pane: AgentPaneIdentity) -> PiLaunchCoordinator? { piLaunches[pane] }
    #endif

    private let context: () throws -> HostContext
    private let defaults: UserDefaults
    private let makeLocalClient: (Machine) -> HerdrClient
    private var machines: [Machine] = []
    private var snapshots: [UUID: Snapshot] = [:]
    private var inspections: [AgentPaneIdentity: Inspection] = [:]
    private var agentObservations: [UUID: [AgentSummary]] = [:]
    private var activityReceived: [UUID: ContinuousClock.Instant] = [:]
    private var unsafeForeground: [UUID: Bool] = [:]
    private var activityInspectionFailed: Set<UUID> = []
    private var plans: [AgentPaneIdentity: PreparedAgentLaunch] = [:]
    /// Direct-agent argv whose argv-only prepare was quietly rejected.
    private var rejectedPreparations: [AgentPaneIdentity: [String]] = [:]
    /// Failed preparations and registrations wait before the next attempt.
    private var preparationRetries: [AgentPaneIdentity: AgentDirectPreparation.Retry] = [:]
    private var registrationRetries: [AgentPaneIdentity: AgentDirectPreparation.Retry] = [:]
    private var piLaunches: [AgentPaneIdentity: PiLaunchCoordinator] = [:]
    /// The settings each pane was last registered with.
    private var registered: [AgentPaneIdentity: AgentRuntimePreferences] = [:]
    /// When the settings were last saved: the field saves them as they are typed.
    private var preferencesSaved: ContinuousClock.Instant?
    private var disappeared: Set<AgentPaneIdentity> = []
    private var failures: [AgentPaneIdentity: String] = [:]
    private var pending: Set<UUID> = []
    private var preparingPanes: Set<AgentPaneIdentity> = []
    private var launchingPanes: Set<AgentPaneIdentity> = []
    private var modeOperation = false
    private var consumer: Task<Void, Never>?
    private var consumerDirty = false
    private var stopping = false
    let skillPreparation = AgentSkillPreparation()
    private(set) var installation: AgentRuntimeInstallation?
    private(set) var diagnostics: [AgentKind: AgentCLIAvailability] = [:]
    private(set) var reconciliationError: String?
    var preferences: AgentRuntimePreferences

    init(context: @escaping () throws -> HostContext = { try HostContext.thisMac() }, defaults: UserDefaults = .standard,
         makeLocalClient: @escaping (Machine) -> HerdrClient = { HerdrClient(transport: LocalHerdrTransport(socketPath: AgentLaunchService.socketPath(for: $0))) }) {
        self.context = context; self.defaults = defaults; self.makeLocalClient = makeLocalClient
        preferences = defaults.data(forKey: "agentRuntimePreferences").flatMap { try? JSONDecoder().decode(AgentRuntimePreferences.self, from: $0) } ?? .init()
    }

    func start() {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        stopping = false
        MachineBrowserService.shared.acceptedSnapshot = { [weak self] panes, machine in self?.accept(panes, on: machine) }
        prepareSkillsAutomatically()
    }

    func stop() async {
        stopping = true
        consumerDirty = false
        MachineBrowserService.shared.acceptedSnapshot = nil
        await skillPreparation.stop()
        for launch in piLaunches.values { await launch.stop() }
        // Drain the current finite operation naturally. Canceling a shell
        // pipeline is not evidence that its Node child has terminated.
        await consumer?.value
        consumer = nil
    }

    func update(machines: [Machine]) {
        self.machines = machines
        prepareSkillsAutomatically()
    }

    func prepareSkillsAutomatically(retry: Bool = false) {
        guard ShepherdBrowserFeature.shared.isEnabled, !stopping else { return }
        let prepare: (@MainActor () async throws -> Void)?
        if !BrowserEngine.isAvailable {
            prepare = { throw AgentRuntimeError.rejected("native-browser-unavailable") }
        } else if let machine = machines.first(where: \.isLocal) {
            prepare = { [self] in
                let client = makeLocalClient(machine)
                do {
                    try await client.connect()
                    try await install(using: client, on: machine)
                    await client.disconnect()
                } catch { await client.disconnect(); throw error }
            }
        } else { prepare = nil }
        if retry { resetPreparationRetries(); skillPreparation.retry(prepare: prepare) }
        else { skillPreparation.enable(prepare: prepare) }
    }

    var browserDisableBlocked: Bool {
        skillPreparation.isBusy || piLaunches.values.contains(where: \.hasWork) || !pending.isEmpty || !preparingPanes.isEmpty || !launchingPanes.isEmpty ||
            consumer != nil || modeOperation || machines.contains { $0.isLocal && activityInspectionFailed.contains($0.id) } ||
            (!machines.filter(\.isLocal).isEmpty && modeChangeBlocked)
    }

    /// Fresh, complete snapshots for every configured local session are required.
    /// A hidden pane or a different local Machine can hold the same host config.
    var modeChangeBlocked: Bool {
        if skillPreparation.isBusy || modeOperation || !pending.isEmpty || !disappeared.isEmpty || CDPProxy.shared.activeConnections > 0 { return true }
        let local = machines.filter(\.isLocal)
        guard !local.isEmpty else { return true }
        return local.contains { machine in
            guard let snapshot = snapshots[machine.id], snapshot.machine == machine,
                  snapshot.received.duration(to: ContinuousClock().now) < .seconds(6),
                  MachineBrowserService.shared.errors[machine.id] == nil else { return true }
            guard let received = activityReceived[machine.id], received.duration(to: ContinuousClock().now) < .seconds(6),
                  unsafeForeground[machine.id] == false else { return true }
            return snapshot.panes.contains { $0.hasAgent || $0.launchPending == true } ||
                agentObservations[machine.id]?.contains { $0.hasAgent || $0.launchPending == true } != false
        }
    }

    func setBrowserPort(_ port: Int) async throws {
        guard ShepherdBrowserFeature.shared.isEnabled else { throw AgentRuntimeError.rejected("shepherd-browser-disabled") }
        guard (1...65535).contains(port), !modeChangeBlocked else { throw AgentRuntimeError.rejected("agents-pending-live-or-inspection-stale") }
        modeOperation = true; defer { modeOperation = false }
        defaults.set(port, forKey: "browserAgentPort")
        await CDPProxy.shared.restart(port: port)
        registered.removeAll(); resetPreparationRetries(); scheduleConsumer()
        if CDPProxy.shared.port == nil { throw AgentRuntimeError.rejected("browser-listener-not-ready") }
    }

    func savePreferences() throws {
        guard ShepherdBrowserFeature.shared.isEnabled else { throw AgentRuntimeError.rejected("shepherd-browser-disabled") }
        // Host-global registration is no longer an activation option.
        preferences.mode = .plugin
        defaults.set(try JSONEncoder().encode(preferences), forKey: "agentRuntimePreferences")
        // The browser check registers the panes again once these have stayed
        // the same for a second, not at every key typed into the field.
        preferencesSaved = ContinuousClock().now
        resetPreparationRetries()
    }

    /// The user changed or retried something: failed preparations are tried
    /// again on the next check instead of after their wait.
    private func resetPreparationRetries() {
        if !preparationRetries.isEmpty { preparationRetries.removeAll() }
        if !registrationRetries.isEmpty { registrationRetries.removeAll() }
    }

    func check(using client: HerdrClient, on machine: Machine) async throws {
        guard ShepherdBrowserFeature.shared.isEnabled else { throw AgentRuntimeError.rejected("shepherd-browser-disabled") }
        guard machine.isLocal else { throw AgentRuntimeError.remoteUnavailable }
        resetPreparationRetries()
        let host = try context(), runtime = host.runtime(using: client)
        installation = try await runtime.installation(on: .thisMac)
        if let installation, installation.mode != .plugin { throw AgentRuntimeError.rejected("legacy-global-registration-present") }
        try await runtime.checkScope(claudeSettingsFile: host.claudeSettings, claudeSkillDirectory: host.claudeSkills,
                                     codexHome: host.codexHome, on: .thisMac)
        preferences.mode = .plugin
        for kind in AgentKind.allCases { diagnostics[kind] = try await runtime.availability(of: kind, executable: kind.rawValue, on: .thisMac) }
    }

    func install(using client: HerdrClient, on machine: Machine, setUpCodex: Bool = false) async throws {
        guard ShepherdBrowserFeature.shared.isEnabled else { throw AgentRuntimeError.rejected("shepherd-browser-disabled") }
        guard machine.isLocal else { throw AgentRuntimeError.remoteUnavailable }
        guard !modeOperation, pending.isEmpty else { throw AgentRuntimeError.rejected("launch-or-mode-change-pending") }
        guard !setUpCodex else { throw AgentRuntimeError.rejected("session-only-policy") }
        let operation = UUID(); pending.insert(operation); defer { pending.remove(operation) }
        let host = try context(), runtime = host.runtime(using: client)
        installation = try await runtime.install(on: .thisMac)
        try await check(using: client, on: machine)
        registered.removeAll(); resetPreparationRetries(); scheduleConsumer()
    }

    func setMode(_ mode: AgentInjectionMode, using client: HerdrClient, on machine: Machine) async throws {
        guard ShepherdBrowserFeature.shared.isEnabled else { throw AgentRuntimeError.rejected("shepherd-browser-disabled") }
        guard machine.isLocal else { throw AgentRuntimeError.remoteUnavailable }
        throw AgentRuntimeError.rejected("session-only-policy")
    }

    /// Reserve before create; select the returned shell before any later failure.
    /// A failed start never retries, closes the pane, or cleans prepared state.
    func launch(kind: AgentKind, on machine: Machine, client: HerdrClient,
                create: ([String: String]) async throws -> HerdrClient.CreatedTab,
                select: (HerdrClient.CreatedTab) -> Void) async throws -> HerdrClient.CreatedTab {
        guard machine.isLocal else { throw AgentRuntimeError.remoteUnavailable }
        guard ShepherdBrowserFeature.shared.isEnabled else { throw AgentRuntimeError.rejected("shepherd-browser-disabled") }
        guard BrowserEngine.isAvailable else { throw AgentRuntimeError.rejected("native-browser-unavailable") }
        guard !modeOperation, !skillPreparation.isBusy else { throw AgentRuntimeError.rejected("runtime-preparation-pending") }
        let operation = UUID(); pending.insert(operation); defer { pending.remove(operation) }
        let host = try context(), runtime = host.runtime(using: client)
        guard kind.supportsManagedBrowserLaunch else { throw AgentRuntimeError.rejected("pi-launch-unqualified") }
        if kind == .pi { return try await launchPi(on: machine, client: client, runtime: runtime, create: create, select: select) }
        let available = try await runtime.availability(of: kind, executable: kind.rawValue, on: .thisMac)
        diagnostics[kind] = available
        guard available.readiness == .availableAuthenticationUnknown else {
            throw AgentRuntimeError.rejected(available.nodeSupported ? (available.readiness == .missing ? "cli-missing" : "cli-unsupported") : "node-version-unsupported")
        }
        installation = try await runtime.install(on: .thisMac)
        preferences.mode = installation!.mode
        let reservation = try await runtime.reserveLaunch(on: .thisMac)
        let created: HerdrClient.CreatedTab
        do { created = try await create(reservation.environment) }
        catch { try await runtime.discardReservation(reservation, on: .thisMac); throw error }
        select(created)
        let createdIdentity = AgentPaneIdentity(key: BrowserKey(machine: machine, pane: created.pane), terminalID: created.pane.terminalID)
        preparingPanes.insert(createdIdentity)
        defer { preparingPanes.remove(createdIdentity); launchingPanes.remove(createdIdentity) }
        var identity: AgentPaneIdentity?
        var preparationAttempted = false
        do {
            let resolved = try await waitForShell(created.pane, on: machine, client: client)
            let pane = AgentPaneIdentity(key: resolved.key, terminalID: resolved.terminalID)
            identity = pane
            guard let endpoint = CDPProxy.shared.endpoint(for: resolved.key) else { throw AgentRuntimeError.rejected("browser-listener-not-ready") }
            // From this point an interrupted prepare might have bound the reservation.
            // Leave it for proven disappearance cleanup, never discard on guesswork.
            preparationAttempted = true
            let plan = try await runtime.prepare(kind: kind, executable: kind.rawValue, pane: pane,
                endpoint: AgentBrowserEndpoint(endpoint), preferences: preferences, codexHome: host.codexHome,
                claudeSettingsFile: host.claudeSettings, reservation: reservation, on: .thisMac)
            plans[pane] = plan
            // Preparation can suspend. Recheck the same authoritative terminal
            // and foreground shell before sending the destructive start RPC.
            _ = try await waitForShell(created.pane, on: machine, client: client)
            preparingPanes.remove(createdIdentity); launchingPanes.insert(createdIdentity)
            // herdr refuses a name a live agent already holds, so the bare kind
            // would allow only one launch of each kind per session.
            let result = try await client.agentStart(name: kind.rawValue + "-" + String(reservation.reservationID.prefix(8)), kind: kind, paneID: resolved.key.paneID, arguments: plan.arguments)
            guard result.agent.terminalID == pane.terminalID else { throw AgentRuntimeError.rejected("started-terminal-identity-changed") }
            try await waitForAgent(kind: kind, pane: pane, on: machine, client: client)
            // Snapshot + process inspection remain authority for subsequent state.
            MachineBrowserService.shared.accept(try await client.launchSnapshot().panes, on: machine)
            failures[pane] = nil
            return created
        } catch {
            failures[identity ?? createdIdentity] = connectionFailureDescription(error)
            if !preparationAttempted { try await runtime.discardReservation(reservation, on: .thisMac) }
            throw error
        }
    }

    private func launchPi(on machine: Machine, client: HerdrClient, runtime: AgentRuntime,
                          create: ([String: String]) async throws -> HerdrClient.CreatedTab,
                          select: (HerdrClient.CreatedTab) -> Void) async throws -> HerdrClient.CreatedTab {
        installation = try await runtime.install(on: .thisMac)
        let stage = try await runtime.stagePi(on: .thisMac)
        let created = try await create(stage.environment)
        select(created)
        let pane = AgentPaneIdentity(key: BrowserKey(machine: machine, pane: created.pane), terminalID: created.pane.terminalID)
        preparingPanes.insert(pane)
        defer { preparingPanes.remove(pane); launchingPanes.remove(pane) }
        do {
            _ = try await waitForShell(created.pane, on: machine, client: client)
            let process = try await client.processInfo(paneID: pane.paneID)
            guard let pid = process.shellPID, pid <= UInt32(Int32.max), process.isShellForeground else { throw PiBridgeFailure.identity }
            let cwd = try PiProcessIdentity.capture(pid: Int32(pid)).cwd
            let coordinator = try PiLaunchCoordinator(stage: stage, owner: pane, machine: machine,
                client: makeLocalClient(machine), cwd: cwd, preferences: preferences)
            piLaunches[pane] = coordinator
            try await coordinator.prepare()
            _ = try await waitForShell(created.pane, on: machine, client: client)
            preparingPanes.remove(pane); launchingPanes.insert(pane)
            let result = try await client.agentStart(name: "pi-" + String(stage.id.prefix(8)), kind: .pi, paneID: pane.paneID, arguments: stage.arguments)
            guard result.agent.terminalID == pane.terminalID else { throw PiBridgeFailure.identity }
            try await waitForAgent(kind: .pi, pane: pane, on: machine, client: client)
            try await coordinator.waitUntilReady()
            failures[pane] = nil
            return created
        } catch {
            await piLaunches[pane]?.stop()
            failures[pane] = connectionFailureDescription(error)
            throw error
        }
    }

    private func waitForAgent(kind: AgentKind, pane: AgentPaneIdentity, on machine: Machine, client: HerdrClient) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(30))
        while ContinuousClock().now < deadline {
            let snapshot = try await client.launchSnapshot()
            MachineBrowserService.shared.accept(snapshot.panes, on: machine)
            guard snapshot.panes.contains(where: { $0.terminalID == pane.terminalID && $0.paneID == pane.paneID }) else {
                throw AgentRuntimeError.rejected("started-terminal-identity-changed")
            }
            let agents = try await client.agentList()
            agentObservations[machine.id] = agents
            if let current = agents.first(where: { $0.paneID == pane.paneID && $0.terminalID == pane.terminalID }),
               current.interactiveReady == true, current.launchPending != true,
               current.agentName.flatMap(AgentKind.init(herdrName:)) == kind { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AgentRuntimeError.rejected("agent-readiness-timeout-check-cli-login-and-terminal")
    }

    private func waitForShell(_ expected: AgentSummary, on machine: Machine, client: HerdrClient) async throws -> MachineBrowserService.ResolvedPane {
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while ContinuousClock().now < deadline {
            let snapshot = try await client.launchSnapshot()
            MachineBrowserService.shared.accept(snapshot.panes, on: machine)
            guard let current = snapshot.panes.first(where: { $0.terminalID == expected.terminalID }), current.paneID == expected.paneID else {
                throw AgentRuntimeError.rejected("created-pane-identity-changed")
            }
            let agentRows = try await client.agentList()
            if !current.hasAgent, current.launchPending != true,
               !agentRows.contains(where: { $0.terminalID == expected.terminalID }),
               try await client.processInfo(paneID: current.paneID).isShellForeground,
               let resolved = resolved(current, on: machine) { return resolved }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw AgentRuntimeError.rejected("shell-readiness-timeout")
    }

    func status(for agent: AgentSummary, on machine: Machine) -> AgentBrowserStatus {
        guard ShepherdBrowserFeature.shared.isEnabled, machine.isLocal, agent.herdrMachine == nil else { return agent.hasAgent || agent.launchPending == true ? .remoteUnavailable : .shell }
        let key = BrowserKey(machine: machine, pane: agent), identity = AgentPaneIdentity(key: key, terminalID: agent.terminalID)
        if let failure = failures[identity] { return .failed(failure) }
        if preparingPanes.contains(identity) { return .preparing }
        if launchingPanes.contains(identity) { return .launchPending }
        if let pi = piLaunches[identity], agent.agentName.flatMap(AgentKind.init(herdrName:)) == .pi {
            if let failure = pi.failure { return .failed(failure) }
            guard pi.isReady else { return .unknown }
            return BrowserStore.shared.browser(for: key)?.agentSocketConnected == true ? .connected : .injectedDisconnected
        }
        let inspection = inspections[identity]
        let observed = inspection?.agent ?? agent
        let fresh = inspection.map { $0.received.duration(to: ContinuousClock().now) < .seconds(6) && $0.agent.terminalID == agent.terminalID && $0.agent.paneID == agent.paneID && $0.agent.revision == agent.revision } == true && MachineBrowserService.shared.errors[machine.id] == nil
        if !observed.hasAgent && observed.launchPending != true {
            return fresh && inspection?.process.isShellForeground == true ? .shell : .unknown
        }
        return .inspect(agent: observed, process: inspection?.process, prepared: plans[identity],
                        socketConnected: BrowserStore.shared.browser(for: key)?.agentSocketConnected == true,
                        mode: installation?.mode ?? .plugin, fresh: fresh)
    }

    func failure(for agent: AgentSummary, on machine: Machine) -> String? {
        failures[AgentPaneIdentity(key: BrowserKey(machine: machine, pane: agent), terminalID: agent.terminalID)]
    }

    func canResume(_ agent: AgentSummary, on machine: Machine) -> Bool {
        guard ShepherdBrowserFeature.shared.isEnabled, machine.isLocal, agent.herdrMachine == nil,
              !skillPreparation.isBusy, !modeOperation, pending.isEmpty else { return false }
        let identity = AgentPaneIdentity(key: BrowserKey(machine: machine, pane: agent), terminalID: agent.terminalID)
        guard let inspection = inspections[identity], inspection.agent.revision == agent.revision,
              inspection.agent.terminalID == agent.terminalID, inspection.received.duration(to: ContinuousClock().now) < .seconds(6) else { return false }
        let inspectedStatus = AgentBrowserStatus.inspect(agent: inspection.agent, process: inspection.process, prepared: plans[identity],
            socketConnected: BrowserStore.shared.browser(for: BrowserKey(machine: machine, pane: agent))?.agentSocketConnected == true,
            mode: installation?.mode ?? .plugin, fresh: MachineBrowserService.shared.errors[machine.id] == nil)
        return AgentResumeEligibility.sessionID(agent: inspection.agent, process: inspection.process, status: inspectedStatus, fresh: true) != nil
    }

    /// Explicit user action only. Prepare argv-only before touching the live CLI;
    /// failures retain the pane, browser, session and all prepared descriptors.
    func resume(_ agent: AgentSummary, on machine: Machine, client: HerdrClient) async throws {
        guard ShepherdBrowserFeature.shared.isEnabled else { throw AgentRuntimeError.rejected("shepherd-browser-disabled") }
        guard canResume(agent, on: machine) else { throw AgentRuntimeError.rejected("resume-requires-fresh-idle-session") }
        let identity = AgentPaneIdentity(key: BrowserKey(machine: machine, pane: agent), terminalID: agent.terminalID)
        guard let inspection = inspections[identity], let kind = inspection.agent.agentName.flatMap(AgentKind.init(herdrName:)),
              let sessionID = inspection.agent.sessionReference?.resumeID(for: kind),
              let argv = inspection.process.agentArguments(for: kind), let endpoint = CDPProxy.shared.endpoint(for: BrowserKey(machine: machine, pane: agent)) else {
            throw AgentRuntimeError.rejected("resume-inspection-unavailable")
        }
        let expected = inspection.agent
        let operation = UUID(); pending.insert(operation); defer { pending.remove(operation) }
        do {
            try Task.checkCancellation()
            let host = try context(), runtime = host.runtime(using: client)
            let configurationDirectory: String
            switch kind {
            case .claude: configurationDirectory = URL(fileURLWithPath: host.claudeSettings).deletingLastPathComponent().path
            case .codex: configurationDirectory = host.codexHome
            case .pi: throw AgentRuntimeError.rejected("pi-resume-unqualified")
            }
            let persistenceInspection = try await checkedIdle(expected, kind: kind, on: machine, client: client, exactRevision: true)
            guard persistenceInspection.agentArguments(for: kind) == argv else { throw AgentRuntimeError.rejected("resume-foreground-changed") }
            try AgentSavedSession.verify(kind: kind, sessionID: sessionID, cwd: expected.workingDirectory,
                configurationDirectory: configurationDirectory, process: persistenceInspection)
            let plan = try await runtime.prepare(kind: kind, executable: kind.rawValue, pane: identity, endpoint: AgentBrowserEndpoint(endpoint), preferences: preferences,
                arguments: Array(argv.dropFirst()), codexHome: host.codexHome, claudeSettingsFile: host.claudeSettings, reservation: nil, on: .thisMac).resuming(sessionID: sessionID)
            let initial = try await checkedIdle(expected, kind: kind, on: machine, client: client, exactRevision: true)
            guard initial.agentArguments(for: kind) == argv, AgentIdleStopPolicy.isEmptyEditor(kind: kind, ansi: try await client.visiblePaneANSI(paneID: agent.paneID)) else {
                throw AgentRuntimeError.rejected("resume-editor-or-modal-not-empty")
            }
            let beforeStop = try await checkedIdle(expected, kind: kind, on: machine, client: client, exactRevision: true)
            try AgentSavedSession.verify(kind: kind, sessionID: sessionID, cwd: expected.workingDirectory,
                configurationDirectory: configurationDirectory, process: beforeStop)
            try Task.checkCancellation()
            try await client.agentSendKeys(paneID: agent.paneID, keys: ["ctrl+d"])
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            var secondClaudeKey = false
            var shellReady = false
            while ContinuousClock().now < deadline {
                try Task.checkCancellation()
                let snapshot = try await client.launchSnapshot()
                MachineBrowserService.shared.accept(snapshot.panes, on: machine)
                guard snapshot.panes.contains(where: { $0.paneID == agent.paneID && $0.terminalID == agent.terminalID }) else { throw AgentRuntimeError.rejected("resume-terminal-changed") }
                let process = try await client.processInfo(paneID: agent.paneID)
                if process.isShellForeground { shellReady = true; break }
                if kind == .claude && !secondClaudeKey {
                    let current = try await checkedIdle(expected, kind: kind, on: machine, client: client, exactRevision: false)
                    guard current.agentArguments(for: kind) == argv else { throw AgentRuntimeError.rejected("resume-foreground-changed") }
                    try await client.agentSendKeys(paneID: agent.paneID, keys: ["ctrl+d"])
                    secondClaudeKey = true
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard shellReady else { throw AgentRuntimeError.rejected("resume-idle-stop-timeout") }
            let key = BrowserKey(machine: machine, pane: agent)
            // agentConnected includes retiring native leases; socket EOF alone
            // is not acknowledged cleanup. Keep all page/profile state intact.
            while BrowserStore.shared.browser(for: key)?.agentConnected == true && ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard BrowserStore.shared.browser(for: key)?.agentConnected != true else { throw AgentRuntimeError.rejected("resume-browser-cleanup-not-confirmed") }
            _ = try await waitForShell(agent, on: machine, client: client)
            try Task.checkCancellation()
            plans[identity] = plan
            let started = try await client.agentStart(name: kind.rawValue + "-" + operation.uuidString.prefix(8).lowercased(), kind: kind, paneID: agent.paneID, arguments: plan.arguments)
            guard started.agent.terminalID == agent.terminalID else { throw AgentRuntimeError.rejected("resume-terminal-changed") }
            let qualified = AgentResumeConfirmation.Identity(ownerID: "local:\(identity.machineID):\(identity.session)",
                paneID: identity.paneID, terminalID: identity.terminalID)
            _ = try await AgentResumeConfirmation.wait(identity: qualified, expectedKind: kind.rawValue,
                sessionID: sessionID, timeout: .seconds(30), fetch: { [self] deadline in
                    // LOCAL transport cancels its DispatchSource-backed RPCs promptly.
                    // Both RPCs share this absolute deadline; structured cleanup drains
                    // the cancelled loser before returning (no detached work).
                    try await withThrowingTaskGroup(of: AgentResumeConfirmation.Observation.self) { group in
                        group.addTask { try await self.resumeObservation(identity: qualified, kind: kind, on: machine, client: client) }
                        group.addTask {
                            try await ContinuousClock().sleep(until: deadline)
                            throw AgentResumeConfirmation.Failure.timedOut
                        }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                })
            failures[identity] = nil
        } catch { failures[identity] = connectionFailureDescription(error); throw error }
    }

    private func resumeObservation(identity: AgentResumeConfirmation.Identity, kind: AgentKind, on machine: Machine,
                                   client: HerdrClient) async throws -> AgentResumeConfirmation.Observation {
        try Task.checkCancellation()
        guard machine.isLocal, identity.ownerID == "local:\(machine.id.uuidString):\(BrowserKey.session(named: machine.sessionName))" else {
            throw AgentResumeConfirmation.Failure.identityChanged
        }
        let snapshot = try await client.launchSnapshot()
        MachineBrowserService.shared.accept(snapshot.panes, on: machine)
        guard let pane = snapshot.panes.first(where: { $0.paneID == identity.paneID && $0.terminalID == identity.terminalID }),
              pane.herdrMachine == nil else { throw AgentResumeConfirmation.Failure.identityChanged }
        let agents = try await client.agentList()
        try Task.checkCancellation()
        agentObservations[machine.id] = agents
        let row = agents.first { $0.paneID == identity.paneID && $0.terminalID == identity.terminalID }
        guard row?.herdrMachine == nil else { throw AgentResumeConfirmation.Failure.identityChanged }
        #if DEBUG
        resumeObservation?(Self.fixtureObservation(pane, phase: "confirmation-snapshot"))
        if let row { resumeObservation?(Self.fixtureObservation(row, phase: "confirmation-agent")) }
        else { resumeObservation?(["phase": "confirmation-agent-absent", "pane": identity.paneID, "terminal": identity.terminalID]) }
        #endif
        return .init(identity: identity, kind: row?.agentName.flatMap(AgentKind.init(herdrName:))?.rawValue,
            interactiveReady: row?.interactiveReady == true, launchPending: row?.launchPending == true,
            compatibleSessionID: row?.sessionReference?.resumeID(for: kind))
    }

    #if DEBUG
    static func fixtureObservation(_ row: AgentSummary, phase: String) -> [String: Any] {
        ["phase": phase, "pane": row.paneID, "terminal": row.terminalID, "kind": row.agentName ?? "",
         "interactiveReady": row.interactiveReady == true, "launchPending": row.launchPending == true,
         "sessionKind": row.sessionReference?.kind.rawValue ?? "", "sessionSource": row.sessionReference?.source ?? "",
         "sessionValue": row.sessionReference?.value ?? ""]
    }
    #endif

    private func checkedIdle(_ expected: AgentSummary, kind: AgentKind, on machine: Machine, client: HerdrClient, exactRevision: Bool) async throws -> PaneProcessInfo {
        try Task.checkCancellation()
        let snapshot = try await client.launchSnapshot()
        MachineBrowserService.shared.accept(snapshot.panes, on: machine)
        guard snapshot.panes.contains(where: { $0.paneID == expected.paneID && $0.terminalID == expected.terminalID }),
              let current = try await client.agentList().first(where: { $0.paneID == expected.paneID && $0.terminalID == expected.terminalID }),
              AgentIdleStopPolicy.sameIdleSession(expected, current), !exactRevision || current.revision == expected.revision else {
            throw AgentRuntimeError.rejected("resume-state-or-session-changed")
        }
        let process = try await client.processInfo(paneID: expected.paneID)
        guard process.agentArguments(for: kind) != nil,
              snapshots[machine.id]?.panes.contains(where: { $0.paneID == expected.paneID && $0.terminalID == expected.terminalID }) == true else { throw AgentRuntimeError.rejected("resume-foreground-changed") }
        return process
    }

    private func resolved(_ pane: AgentSummary, on machine: Machine) -> MachineBrowserService.ResolvedPane? {
        let key = BrowserKey(machine: machine, pane: pane)
        guard let route = CDPRoute("/v1/herdr/\(key.session)/pane/\(key.paneID)"),
              let resolved = MachineBrowserService.shared.resolve(route), resolved.key.machineID == machine.id,
              resolved.terminalID == pane.terminalID else { return nil }
        return resolved
    }

    private func accept(_ panes: [AgentSummary], on machine: Machine) {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        guard machine.isLocal else { return }
        let previous = snapshots[machine.id]?.panes ?? []
        let terminals = Set(panes.map(\.terminalID))
        for old in previous where !terminals.contains(old.terminalID) {
            disappeared.insert(AgentPaneIdentity(key: BrowserKey(machine: machine, pane: old), terminalID: old.terminalID))
        }
        snapshots[machine.id] = Snapshot(machine: machine, panes: panes, received: ContinuousClock().now)
        // Terminal moves retain plans and output, but use the newest qualified key.
        for pane in panes {
            let current = AgentPaneIdentity(key: BrowserKey(machine: machine, pane: pane), terminalID: pane.terminalID)
            let moved = { (old: AgentPaneIdentity) in old.machineID == current.machineID && old.session == current.session && old.terminalID == current.terminalID && old != current }
            for old in Array(plans.keys) where moved(old) {
                plans[current] = plans.removeValue(forKey: old)
                failures[current] = failures.removeValue(forKey: old)
                registered[old] = nil
            }
            for old in Array(rejectedPreparations.keys) where moved(old) { rejectedPreparations[current] = rejectedPreparations.removeValue(forKey: old) }
            for old in Array(preparationRetries.keys) where moved(old) { preparationRetries[current] = preparationRetries.removeValue(forKey: old) }
            for old in Array(registrationRetries.keys) where moved(old) { registrationRetries[current] = registrationRetries.removeValue(forKey: old) }
        }
        scheduleConsumer()
    }

    private func scheduleConsumer() {
        guard ShepherdBrowserFeature.shared.isEnabled, !stopping else { return }
        consumerDirty = true
        guard consumer == nil else { return }
        consumer = Task {
            while consumerDirty && !stopping && !Task.isCancelled {
                consumerDirty = false
                // Kept until the round ends, and written only when it changes:
                // every write recomputes whatever shows it.
                var roundError: String?
                for snapshot in Array(snapshots.values) {
                    do { if let error = try await reconcile(snapshot) { roundError = error } }
                    catch { roundError = connectionFailureDescription(error) }
                }
                if reconciliationError != roundError { reconciliationError = roundError }
            }
            consumer = nil
        }
    }

    /// Returns the last failure it reported and went on from, if any.
    private func reconcile(_ snapshot: Snapshot) async throws -> String? {
        activityInspectionFailed.insert(snapshot.machine.id)
        let client = makeLocalClient(snapshot.machine)
        var reported: String?
        do {
            try await client.connect()
            let agents = try await client.agentList()
            agentObservations[snapshot.machine.id] = agents
            unsafeForeground[snapshot.machine.id] = true
            var unsafe = false
            var inspectedCount = 0
            // Collected and written at once: the sidebar reads inspections.
            var inspected: [AgentPaneIdentity: Inspection] = [:]
            // Liveness guards cannot depend on Node installation or a working
            // listener: a port conflict must remain recoverable for shell users.
            do {
                for pane in snapshot.panes {
                    let identity = AgentPaneIdentity(key: BrowserKey(machine: snapshot.machine, pane: pane), terminalID: pane.terminalID)
                    let row = agents.first(where: { $0.paneID == pane.paneID && $0.terminalID == pane.terminalID })
                    let previous = inspections[identity]
                    let process: PaneProcessInfo, processReceived: ContinuousClock.Instant
                    if let previous, AgentInspectionReuse.canReuse(pane: pane, row: row, previousPane: previous.pane, previousRow: previous.row,
                                                                   processAge: previous.processReceived.duration(to: ContinuousClock().now)) {
                        process = previous.process; processReceived = previous.processReceived
                    } else {
                        process = try await client.processInfo(paneID: pane.paneID); processReceived = ContinuousClock().now
                    }
                    guard snapshots[snapshot.machine.id]?.panes.contains(where: { $0.paneID == pane.paneID && $0.terminalID == pane.terminalID }) == true else { continue }
                    unsafe = unsafe || !process.isShellForeground
                    inspectedCount += 1
                    inspected[identity] = Inspection(agent: row ?? pane, process: process, received: ContinuousClock().now,
                                                     pane: pane, row: row, processReceived: processReceived)
                }
            } catch {
                if !inspected.isEmpty { inspections.merge(inspected) { _, new in new } }
                throw error
            }
            if !inspected.isEmpty { inspections.merge(inspected) { _, new in new } }
            if snapshots[snapshot.machine.id]?.panes.map(\.terminalID) == snapshot.panes.map(\.terminalID) {
                unsafeForeground[snapshot.machine.id] = unsafe || inspectedCount != snapshot.panes.count
                activityReceived[snapshot.machine.id] = ContinuousClock().now
                activityInspectionFailed.remove(snapshot.machine.id)
            }
            guard !modeOperation, !skillPreparation.isBusy else { await client.disconnect(); return reported }
            let host = try context(), runtime = host.runtime(using: client)
            let installed = try await runtime.installation(on: .thisMac)
            if let installed, installed != installation { installation = installed }
            let settled = preferencesSaved.map { $0.duration(to: ContinuousClock().now) >= .seconds(1) } ?? true
            for pane in snapshot.panes {
                guard !modeOperation, !skillPreparation.isBusy, let installed, snapshots[snapshot.machine.id]?.panes.contains(pane) == true,
                      let resolved = resolved(pane, on: snapshot.machine), let endpoint = CDPProxy.shared.endpoint(for: resolved.key) else { continue }
                let identity = AgentPaneIdentity(key: resolved.key, terminalID: resolved.terminalID)
                guard let inspection = inspections[identity] else { continue }
                let process = inspection.process, observed = inspection.agent
                var currentPreferences = preferences; currentPreferences.mode = installed.mode
                // A new pane is registered at once; a registered one again when
                // the settings it was registered with changed and have settled.
                // Recording the settings used, not just "registered", keeps a save
                // made while this registration runs from being taken as done.
                if registered[identity] != currentPreferences, registered[identity] == nil || settled {
                    // While a failed registration waits, this check stops here
                    // as the failure itself did.
                    if AgentDirectPreparation.isWaiting(registrationRetries[identity], argv: nil, now: ContinuousClock().now),
                       let retry = registrationRetries[identity] {
                        await client.disconnect(); return retry.message
                    }
                    do {
                        try await runtime.registerPane(identity, endpoint: AgentBrowserEndpoint(endpoint), preferences: currentPreferences,
                            executables: ["claude": "claude", "codex": "codex"], codexHome: host.codexHome, claudeSettingsFile: host.claudeSettings, on: .thisMac)
                    } catch {
                        registrationRetries[identity] = AgentDirectPreparation.nextRetry(after: registrationRetries[identity], argv: nil, error: error,
                            message: connectionFailureDescription(error), now: ContinuousClock().now)
                        throw error
                    }
                    registered[identity] = currentPreferences; registrationRetries[identity] = nil
                }
                // Direct agents are checked with their actual argv/config. Unsafe or
                // already injected registrations remain unknown, never called missing,
                // and are prepared again only once the pane runs different argv.
                let kind = observed.agentName.flatMap(AgentKind.init(herdrName:))
                let direct = kind.flatMap { process.agentArguments(for: $0) }
                if preparationRetries[identity].map({ $0.argv != direct }) == true { preparationRetries[identity] = nil }
                if pending.isEmpty, !modeOperation, plans[identity] == nil, let kind,
                   kind.supportsLegacySessionInspection, let argv = direct, !argv.isEmpty, installed.mode == .plugin {
                    if AgentDirectPreparation.shouldPrepare(argv, rejected: rejectedPreparations[identity], retry: preparationRetries[identity], now: ContinuousClock().now) {
                        do {
                            plans[identity] = try await runtime.prepare(kind: kind, executable: kind.rawValue, pane: identity,
                                endpoint: AgentBrowserEndpoint(endpoint), preferences: currentPreferences, arguments: Array(argv.dropFirst()),
                                codexHome: host.codexHome, claudeSettingsFile: host.claudeSettings, on: .thisMac)
                            rejectedPreparations[identity] = nil; preparationRetries[identity] = nil
                        } catch let error where AgentDirectPreparation.isQuiet(error) { rejectedPreparations[identity] = argv; preparationRetries[identity] = nil }
                        catch {
                            let message = connectionFailureDescription(error)
                            preparationRetries[identity] = AgentDirectPreparation.nextRetry(after: preparationRetries[identity], argv: argv, error: error,
                                message: message, now: ContinuousClock().now)
                            reported = message
                        }
                    } else if argv != rejectedPreparations[identity], let retry = preparationRetries[identity] {
                        // Waiting after a failure: Diagnostics keeps showing it.
                        reported = retry.message
                    }
                }
            }
            for identity in Array(disappeared) where identity.machineID == snapshot.machine.id.uuidString && identity.session == BrowserKey.session(named: snapshot.machine.sessionName) {
                // Re-fetch from herdr immediately before cleanup. Failed requests,
                // moves and new identities cannot authorize filesystem removal.
                let current = try await client.launchSnapshot()
                guard !current.panes.contains(where: { $0.terminalID == identity.terminalID }),
                      !(try await client.agentList()).contains(where: { $0.terminalID == identity.terminalID }),
                      snapshots[snapshot.machine.id]?.panes.contains(where: { $0.terminalID == identity.terminalID }) == false,
                      pending.isEmpty else { continue }
                do {
                    try await runtime.cleanup(pane: identity, on: .thisMac)
                    disappeared.remove(identity); registered[identity] = nil; plans[identity] = nil
                    inspections[identity] = nil; failures[identity] = nil; rejectedPreparations[identity] = nil
                    preparationRetries[identity] = nil; registrationRetries[identity] = nil
                } catch { reported = connectionFailureDescription(error) }
            }
            await client.disconnect()
            return reported
        } catch { await client.disconnect(); throw error }
    }

    nonisolated private static func socketPath(for machine: Machine) -> String {
        let path = LocalHerdrTransport.defaultSocketPath
        return machine.sessionName.isEmpty ? path : URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: "sessions").appending(path: machine.sessionName).appending(path: "herdr.sock").path
    }
}
#endif
