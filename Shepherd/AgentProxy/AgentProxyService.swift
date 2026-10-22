#if os(macOS)
import Foundation
import Observation

/// "Show Conversations on iPhone and iPad" (SHPHRD-105): the agent proxy,
/// opt-in. While the setting is on, the proxy's LaunchAgent is registered and
/// launchd keeps it running, and the launcher's Claude Code, Codex and Pi on
/// This Mac get a route through it (`route(for:pane:cliVersion:on:)`). Turned
/// off, new launches go without it, the routes of panes that are gone are
/// removed, and once none is left the LaunchAgent is unregistered, so that
/// agents already using the proxy are never cut off.
///
/// Every few seconds while the proxy is registered it is asked how it is
/// (`proxy.status`): a build other than the executable in this app's bundle
/// is asked to restart once idle, so that launchd starts the new one. Its
/// routes (`routes.list`) tell which kinds of agent it turned away for not
/// being signed in with a subscription: those go without the proxy from then
/// on, until the setting is turned off and on again.
@MainActor @Observable
final class AgentProxyService: AgentProxyRouting {
    /// What the service stands on: the app's own, or stand-ins in tests.
    struct Environment {
        var launchAgent: any AgentProxyLaunchAgent
        var control: any AgentProxyControlling
        var loadSetting: () -> Bool
        var saveSetting: (Bool) -> Void
        var loadRejectedKinds: () -> Set<String>
        var saveRejectedKinds: (Set<String>) -> Void
        /// SHA-256 of the executable in this app's bundle, as the proxy
        /// reports its `build`; nil when it can't be read.
        var bundledBuild: @Sendable () async -> String?
        var systemProxyConfigured: () -> Bool
        /// The terminals of the panes in a herdr session on This Mac, read
        /// afresh: empty when no herdr serves the session, nil when that
        /// can't be told.
        var liveTerminals: (_ session: String) async -> Set<String>?
        /// Between two checks while the proxy is registered; nil: only when
        /// asked (tests).
        var checkInterval: Duration? = .seconds(5)
        /// Checks in a row that the proxy may not answer after it was
        /// registered, while launchd starts it, before that is shown.
        var startingChecks = 3
    }

    enum Phase: Equatable {
        case off
        /// Registered; not answering yet, or restarting with this app's build.
        case starting
        case running
        /// Turned off for hrdrhrdrhrdr in System Settings › General › Login Items.
        case needsApproval
        case unavailable(String)
        /// The setting is off; the proxy stays until these agents are gone.
        case stopping(agents: Int)
    }

    private(set) var isOn: Bool
    private(set) var phase: Phase = .off
    /// Kinds of agent the proxy turned away for not being signed in with a
    /// subscription (`AgentProxyRouteKind` raw values).
    private(set) var rejectedKinds: Set<String>
    /// Why the last launch went without the proxy; nil when it got a route.
    private(set) var lastSkip: AgentProxyInjectionPolicy.Skip?

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var routes: [AgentProxyRoute] = []
    /// Routes made for launches not yet started: never swept.
    @ObservationIgnored private var launching: Set<String> = []
    /// The proxy build last asked to restart, so that it is asked once.
    @ObservationIgnored private var restartAsked: String?
    @ObservationIgnored private var unanswered = 0
    @ObservationIgnored private var started = false

    init(environment: Environment) {
        self.environment = environment
        isOn = environment.loadSetting()
        rejectedKinds = environment.loadRejectedKinds()
    }

    /// At the app's start: the proxy as the setting left it.
    func start() {
        guard !started else { return }
        started = true
        Task { await check() }
        scheduleChecks()
    }

    func setOn(_ on: Bool) async {
        guard on != isOn else { return }
        isOn = on
        environment.saveSetting(on)
        unanswered = 0
        if on && !rejectedKinds.isEmpty {
            // Turned on again: every kind of agent is tried with the proxy again.
            rejectedKinds = []
            environment.saveRejectedKinds([])
        }
        await check()
        scheduleChecks()
    }

    func openLoginItems() { environment.launchAgent.openSystemSettings() }

    /// One look at the LaunchAgent and the proxy, and what follows from it;
    /// one at a time. `sweeping`: the routes of panes that are gone are
    /// looked for too, which asks herdr; a launch waiting for its route
    /// doesn't wait for that.
    func check(sweeping: Bool = true) async {
        while let running { await running.value }
        let task = Task { await performCheck(sweeping: sweeping) }
        running = task
        await task.value
        running = nil
    }

    private func scheduleChecks() {
        guard monitor == nil, let interval = environment.checkInterval else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                guard self.isOn || self.phase != .off else { self.monitor = nil; return }
                await self.check()
            }
        }
    }

    private func performCheck(sweeping: Bool) async {
        let agent = environment.launchAgent
        if isOn {
            if agent.state == .notRegistered || agent.state == .notFound {
                do { try agent.register() }
                catch {
                    phase = agent.state == .requiresApproval ? .needsApproval
                        : .unavailable(String(localized: "macOS didn't let hrdrhrdrhrdr add the proxy: \(error.localizedDescription)"))
                    return
                }
                unanswered = 0
            }
            guard agent.state != .requiresApproval else { phase = .needsApproval; return }
            await lookAtProxy()
            if sweeping { await sweep() }
        } else {
            guard agent.state == .enabled || agent.state == .requiresApproval else {
                if phase != .off { phase = .off }
                routes = []
                return
            }
            do {
                routes = try await environment.control.listRoutes()
                unanswered = 0
                noteRejections()
            } catch {
                // Not answering as it should: no agent can be using it.
                unanswered += 1
                if unanswered >= environment.startingChecks { await unregister() } else { phase = .stopping(agents: routes.count) }
                return
            }
            await sweep()
            if routes.isEmpty && launching.isEmpty { await unregister() } else { phase = .stopping(agents: routes.count) }
        }
    }

    /// `proxy.status` and `routes.list`.
    private func lookAtProxy() async {
        let status: AgentProxyStatus
        do {
            status = try await environment.control.status()
            unanswered = 0
        } catch {
            unanswered += 1
            phase = unanswered < environment.startingChecks ? .starting
                : .unavailable(String(localized: "The proxy isn't answering. Agents start without it until it does."))
            return
        }
        if let bundled = await environment.bundledBuild(), status.build != bundled {
            // Another build: it finishes the requests it has, exits, and
            // launchd starts this app's. New agents wait for that.
            if restartAsked != status.build, (try? await environment.control.restartWhenIdle()) != nil { restartAsked = status.build }
            phase = .starting
        } else if status.protocolVersion != AgentProxyControl.protocolVersion {
            phase = .unavailable(String(localized: "The proxy running is from another version of hrdrhrdrhrdr."))
        } else if status.state != .running {
            phase = .starting
        } else {
            phase = .running
        }
        if let listed = try? await environment.control.listRoutes() {
            routes = listed
            noteRejections()
        }
    }

    private func noteRejections() {
        let kinds = Set(routes.filter(\.oauthRejected).map(\.kind.rawValue))
        guard !kinds.isSubset(of: rejectedKinds) else { return }
        rejectedKinds.formUnion(kinds)
        environment.saveRejectedKinds(rejectedKinds)
    }

    /// Removes the routes of panes that are gone: those in a herdr session
    /// whose panes were just read and that no pane of it has. A session that
    /// can't be read keeps its routes.
    private func sweep() async {
        let candidates = routes.filter { !launching.contains($0.routeID) }
        for session in Set(candidates.map(\.session)).sorted() {
            guard let live = await environment.liveTerminals(session) else { continue }
            for route in candidates where route.session == session && !live.contains(route.terminalID) {
                guard (try? await environment.control.removeRoute(route.routeID)) != nil else { continue }
                routes.removeAll { $0.routeID == route.routeID }
            }
        }
    }

    private func unregister() async {
        do {
            try await environment.launchAgent.unregister()
            phase = .off
            routes = []
            unanswered = 0
            restartAsked = nil
        } catch {
            phase = .unavailable(String(localized: "macOS didn't let hrdrhrdrhrdr remove the proxy: \(error.localizedDescription)"))
        }
    }

    // MARK: - Launches

    func route(for kind: AgentKind, pane: AgentPaneIdentity, cliVersion: String?, on machine: Machine) async -> AgentProxyLaunchRoute? {
        if let skip = AgentProxyInjectionPolicy.skip(kind: kind, cliVersion: cliVersion, settingOn: isOn,
                                                    isThisMac: machine.isLocal && pane.herdrMachineID == nil,
                                                    systemProxyConfigured: environment.systemProxyConfigured(),
                                                    rejectedKinds: rejectedKinds) {
            lastSkip = skip
            return nil
        }
        // Asked afresh: only a proxy that answers, runs this app's build and
        // is running is given an agent, so that nothing else listening on
        // its port gets the agent's requests.
        await check(sweeping: false)
        guard isOn, phase == .running, let routeKind = AgentProxyRouteKind(rawValue: kind.rawValue) else {
            lastSkip = .proxyUnavailable
            return nil
        }
        guard !rejectedKinds.contains(kind.rawValue) else { lastSkip = .oauthRejected; return nil }
        // The proxy keeps it with the route: one short line.
        let reported = (cliVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let version = reported.utf8.count <= 64 && !reported.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            ? reported : AgentProxyInjectionPolicy.version(in: reported).map { $0.map(String.init).joined(separator: ".") } ?? ""
        do {
            let created = try await environment.control.createRoute(AgentProxyRouteCreate(
                kind: routeKind, session: pane.session, paneID: pane.paneID, terminalID: pane.terminalID, cliVersion: version))
            guard Self.isBaseURL(created.baseURL) else {
                _ = try? await environment.control.removeRoute(created.routeID)
                lastSkip = .proxyUnavailable
                return nil
            }
            launching.insert(created.routeID)
            lastSkip = nil
            return AgentProxyLaunchRoute(routeID: created.routeID, baseURL: created.baseURL)
        } catch {
            lastSkip = .proxyUnavailable
            return nil
        }
    }

    func started(_ route: AgentProxyLaunchRoute) {
        launching.remove(route.routeID)
    }

    func discard(_ route: AgentProxyLaunchRoute) async {
        launching.remove(route.routeID)
        if (try? await environment.control.removeRoute(route.routeID)) != nil {
            routes.removeAll { $0.routeID == route.routeID }
        }
    }

    /// `http://127.0.0.1:PORT/p/<32 hex>`, as the proxy makes them.
    nonisolated static func isBaseURL(_ value: String) -> Bool {
        guard let match = value.wholeMatch(of: #/http://127\.0\.0\.1:([1-9][0-9]{0,4})/p/[0-9a-f]{32}/#), let port = Int(match.1) else { return false }
        return port <= 65535
    }
}

#endif
