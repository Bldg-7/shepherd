#if os(macOS)
import SwiftUI

/// Presentation only. Never converts unknown/unavailable into connected or
/// changes the launch service's authority/readiness decisions.
nonisolated enum AgentBrowserStatusDisplay {
    enum Tone: Equatable { case neutral, working, waiting, connected, problem }

    static func tone(for status: AgentBrowserStatus) -> Tone {
        switch status {
        case .shell, .unknown, .remoteUnavailable: .neutral
        case .preparing, .launchPending: .working
        case .interactiveReady, .injectedDisconnected: .waiting
        case .connected: .connected
        case .missingInjection, .failed: .problem
        }
    }

    static func tabTitle(for status: AgentBrowserStatus) -> LocalizedStringResource? {
        switch status {
        case .unknown, .shell, .remoteUnavailable: nil
        default: status.title
        }
    }

    static func tooltip(for status: AgentBrowserStatus) -> LocalizedStringResource {
        switch status {
        case .unknown, .remoteUnavailable: "Browser"
        default: status.title
        }
    }
}

struct AgentBrowserStatusBadge: View {
    let status: AgentBrowserStatus
    var failure: String?

    private var color: Color {
        switch AgentBrowserStatusDisplay.tone(for: status) {
        case .neutral: .secondary
        case .working: .blue
        case .waiting: .orange
        case .connected: .green
        case .problem: .red
        }
    }

    var body: some View {
        Image(systemName: "globe")
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityLabel(Text("Browser"))
            .accessibilityValue(Text(status.title))
            .help(failure.map { Text(verbatim: $0) } ?? Text(AgentBrowserStatusDisplay.tooltip(for: status)))
    }
}
#endif
