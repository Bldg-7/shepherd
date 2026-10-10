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
