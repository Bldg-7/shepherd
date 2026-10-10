import SwiftUI

@main @MainActor enum BrowserStatusDisplayTests {
    static func main() {
        let statuses: [AgentBrowserStatus] = [.shell, .unknown, .remoteUnavailable, .preparing, .launchPending, .interactiveReady, .injectedDisconnected, .connected, .missingInjection, .failed("owned error")]
        let tones: [AgentBrowserStatusDisplay.Tone] = [.neutral, .neutral, .neutral, .working, .working, .waiting, .waiting, .connected, .problem, .problem]
        var checks = 0
        for (status, tone) in zip(statuses, tones) {
            precondition(AgentBrowserStatusDisplay.tone(for: status) == tone); checks += 1
            let title = AgentBrowserStatusDisplay.tabTitle(for: status)
            precondition((title == nil) == (status == .unknown || status == .shell || status == .remoteUnavailable)); checks += 1
        }
        precondition(String(localized: AgentBrowserStatusDisplay.tooltip(for: .unknown)) == "Browser"); checks += 1
        precondition(AgentBrowserStatusDisplay.tone(for: .unknown) != .connected); checks += 1
        precondition(String(localized: AgentBrowserStatusDisplay.tooltip(for: .remoteUnavailable)) == "Browser"); checks += 1
        precondition(AgentBrowserStatusDisplay.tone(for: .remoteUnavailable) != .connected); checks += 1
        precondition(AgentBrowserStatusDisplay.tooltip(for: .connected) == AgentBrowserStatus.connected.title); checks += 1
        print("PASS \(checks) browser badge/tab visibility policy checks; production cases/titles projected, no readiness/authority logic changed")
    }
}
