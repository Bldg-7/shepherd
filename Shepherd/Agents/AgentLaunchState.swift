import Foundation

nonisolated enum AgentBrowserStatus: Equatable, Sendable {
    case shell, preparing, launchPending, interactiveReady, injectedDisconnected, connected
    case missingInjection, unknown, remoteUnavailable, failed(String)

    var title: LocalizedStringResource {
        switch self {
        case .shell: "Shell"
        case .preparing: "Preparing browser agent…"
        case .launchPending: "Waiting for agent readiness…"
        case .interactiveReady: "Agent ready; browser not connected"
        case .injectedDisconnected: "Browser injected; not connected"
        case .connected: "Browser connected"
        case .missingInjection: "Browser injection missing"
        case .unknown: "Browser status unknown"
        case .remoteUnavailable: "Remote browser agents unavailable"
        case .failed: "Agent launch failed"
        }
    }

    static func inspect(agent: AgentSummary, process: PaneProcessInfo?, prepared: PreparedAgentLaunch?, socketConnected: Bool, mode: AgentInjectionMode, fresh: Bool) -> Self {
        guard fresh else { return .unknown }
        if let name = agent.agentName, let kind = AgentKind(herdrName: name), !kind.supportsLegacySessionInspection { return .unknown }
        if socketConnected { return .connected }
        if agent.launchPending == true { return .launchPending }
        guard let name = agent.agentName else { return .shell }
        guard let kind = AgentKind(herdrName: name), let argv = process?.agentArguments(for: kind), !argv.isEmpty else { return .unknown }
        // Global injection is not argv-provable. Only a live socket proves it.
        if mode == .global { return .unknown }
        guard let prepared, prepared.kind == kind else { return .unknown }
        return prepared.isInjected(processArguments: argv) ? .injectedDisconnected : .missingInjection
    }
}

/// When a launch takes the agent it started for ready (`AgentLaunchService`'s
/// wait after the start command). herdr's `agent.start` answers as soon as
/// the command is typed into the shell, so the launch reads `agent.list` until
/// the row of the same pane and terminal shows the kind it started, ready:
///
/// - Claude Code and Codex: herdr's `interactive_ready`, which it marks only on
///   an agent it started itself once it sees it idle, and no `launch_pending`.
/// - Pi, typed in by Shepherd rather than started by herdr: idle or done, and
///   no `launch_pending`. Until herdr has read Pi's screen once the state is
///   unknown, and a prompt sent then goes unobserved by herdr.
///
/// `handedOff`: the launcher has closed on the new tab already, and the user
/// may have sent a prompt before herdr saw the agent idle, so a working agent
/// is ready too — Claude Code and Codex with `launch_pending` still set, as
/// herdr leaves it until it has seen them idle. Blocked and unknown never are.
nonisolated enum AgentLaunchReadiness {
    static func isReady(_ agent: AgentSummary, kind: AgentKind, paneID: String, terminalID: String, handedOff: Bool) -> Bool {
        guard agent.paneID == paneID, agent.terminalID == terminalID,
              agent.agentName.flatMap(AgentKind.init(herdrName:)) == kind else { return false }
        let working = handedOff && agent.state == .working
        switch kind {
        case .pi:
            return agent.launchPending != true && (agent.state.isQuiescent || working)
        case .claude, .codex:
            return working || (agent.interactiveReady == true && agent.launchPending != true)
        }
    }
}

nonisolated enum AgentResumeEligibility {
    static func sessionID(agent: AgentSummary, process: PaneProcessInfo?, status: AgentBrowserStatus, fresh: Bool) -> String? {
        guard fresh, status == .missingInjection, agent.state.isQuiescent, agent.interactiveReady == true,
              agent.launchPending != true, agent.screenDetectionSkipped != true, let name = agent.agentName, let kind = AgentKind(herdrName: name),
              kind.supportsLegacySessionInspection, process?.agentArguments(for: kind) != nil else { return nil }
        return agent.sessionReference?.resumeID(for: kind)
    }

    /// Revision/sequence/session are revalidated just before any destructive action.
    static func unchanged(_ expected: AgentSummary, _ current: AgentSummary) -> Bool {
        expected.paneID == current.paneID && expected.terminalID == current.terminalID &&
        expected.herdrMachine?.id == current.herdrMachine?.id && expected.revision == current.revision &&
        expected.stateChangeSequence == current.stateChangeSequence && expected.sessionReference == current.sessionReference &&
        current.agentName == expected.agentName && current.state.isQuiescent && current.interactiveReady == true && current.launchPending != true && current.screenDetectionSkipped != true
    }
}

/// Argv-only preparation of a directly-run agent. Shepherd's own registration
/// in that argv (a launch from before an app restart), or one whose folder is
/// gone, holds for as long as the same process runs: stay unknown, report
/// nothing, and prepare again only for different argv in the pane.
nonisolated enum AgentDirectPreparation {
    /// A failed preparation (argv) or pane registration (nil argv), and when
    /// to try it again. Each failure in a row doubles the wait.
    struct Retry: Equatable, Sendable {
        let argv: [String]?
        let attempts: Int
        let notBefore: ContinuousClock.Instant
        /// The failure's description, shown again while it waits.
        let message: String
    }

    static func shouldPrepare(_ argv: [String], rejected: [String]?, retry: Retry? = nil,
                              now: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
        argv != rejected && !isWaiting(retry, argv: argv, now: now)
    }

    /// Different argv is never held back by another argv's failure.
    static func isWaiting(_ retry: Retry?, argv: [String]?, now: ContinuousClock.Instant) -> Bool {
        guard let retry, retry.argv == argv else { return false }
        return now < retry.notBefore
    }

    /// After a failure isQuiet does not cover. setup-busy is a passing lock
    /// conflict: it is tried again at once and keeps the count it had.
    static func nextRetry(after previous: Retry?, argv: [String]?, error: Error, message: String,
                          now: ContinuousClock.Instant) -> Retry? {
        let same = previous?.argv == argv ? previous : nil
        if case AgentRuntimeError.rejected("setup-busy") = error { return same }
        let attempts = (same?.attempts ?? 0) + 1
        return Retry(argv: argv, attempts: attempts, notBefore: now.advanced(by: delay(attempts: attempts)), message: message)
    }

    /// 30 s, 60 s, 120 s, 240 s, then every 5 minutes.
    static func delay(attempts: Int) -> Duration {
        .seconds(min(30 << min(max(attempts - 1, 0), 4), 300))
    }

    /// Any other failure is reported and retried after `delay`.
    static func isQuiet(_ error: Error) -> Bool {
        guard case AgentRuntimeError.rejected(let code) = error else { return false }
        return code == "duplicate-registration" || code == "uninspectable-claude-registration"
    }
}

/// A launch's or resume's own runtime calls (`AgentLaunchService`). The
/// browser check registers a new pane from the same snapshot a launch
/// accepts, and the two can start Node within milliseconds of each other:
/// `runtime.mjs` refuses the second with setup-busy before it changes
/// anything. The browser check tries again on its next check (`nextRetry`
/// above); a launch has no next check, so it makes the same call again every
/// `interval` for up to `limit`. Any other failure ends it at once, and so
/// does cancellation while it waits.
nonisolated enum AgentRuntimeLockWait {
    static let interval: Duration = .milliseconds(100)
    static let limit: Duration = .seconds(5)

    static func run<T>(isolation: isolated (any Actor)? = #isolation,
                       sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                       now: () -> ContinuousClock.Instant = { ContinuousClock().now },
                       _ operation: () async throws -> T) async throws -> T {
        let deadline = now().advanced(by: limit)
        while true {
            do { return try await operation() }
            catch AgentRuntimeError.rejected("setup-busy") where now() < deadline { try await sleep(interval) }
        }
    }
}

/// The browser check asks herdr for every pane's processes every two
/// seconds. An agent pane whose snapshot pane and agent.list row are both
/// unchanged keeps the processes last read, for at most `maximumAge`; a pane
/// with no agent is always read again.
nonisolated enum AgentInspectionReuse {
    static let maximumAge: Duration = .seconds(30)

    static func canReuse(pane: AgentSummary, row: AgentSummary?, previousPane: AgentSummary?, previousRow: AgentSummary?,
                         processAge: Duration?) -> Bool {
        guard let row, row.hasAgent, let previousRow, let processAge else { return false }
        return pane == previousPane && row == previousRow && processAge < maximumAge
    }
}
