import SwiftUI

#if os(macOS)
/// Normal view is one status row. Detailed checks live in the page's conditional
/// Diagnostics section; advanced preferences share its inline disclosure group.
struct AgentSkillSection: View {
    let machine: Machine
    private var service: AgentLaunchService { .shared }

    var body: some View {
        Section("Agents") {
            if machine.isLocal {
                HStack {
                    Text("Preparation")
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("About agent integration")
                        .help("Prepared automatically for Shepherd sessions. Claude uses a session skill plugin; Codex receives MCP and instructions; Pi uses a session-only TUI extension and skill. Requires Node 20+ (Pi: 22.19+). Preparation does not verify login.")
                    Spacer()
                    preparationStatus
                        .help("Global CLI settings and skill folders are not modified. Running agents are not restarted automatically.")
                }
            } else {
                Text("Remote browser agents are unavailable. Shell tabs remain available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: machine.id) {
            if machine.isLocal { service.prepareSkillsAutomatically() }
        }
    }

    @ViewBuilder private var preparationStatus: some View {
        switch service.skillPreparation.state {
        case .off: Text("Off")
        case .waitingForHost: Text("Waiting for This Mac")
        case .preparing: HStack { ProgressView().controlSize(.small); Text("Preparing…") }
        case .stopping: HStack { ProgressView().controlSize(.small); Text("Stopping…") }
        case .ready: Text("Resources ready")
        case .failed: Text("Preparation failed").foregroundStyle(.red)
        }
    }
}
#endif
