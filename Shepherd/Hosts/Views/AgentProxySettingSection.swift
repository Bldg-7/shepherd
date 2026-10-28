#if os(macOS)
import SwiftUI

/// "Show Conversations on iPhone and iPad" (SHPHRD-105), the same on
/// Settings' iPhone and iPad page and on its Add iPhone or iPad page: the
/// agent proxy's opt-in (`AgentProxyService`), how the proxy is doing, and,
/// while the window shows a machine other than This Mac, greyed out with why,
/// as Add Device… is (see `LocalOnlyAddition`).
struct AgentProxySettingSection: View {
    let service: AgentProxyService
    /// Why it can't be changed now, or nil when it can.
    var unavailableReason: String?
    /// The page's accessibility identifiers start with this.
    let identifier: String
    @State private var confirmClear = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { service.isOn }, set: { on in Task { await service.setOn(on) } })) {
                Text("Show Conversations on iPhone and iPad")
            }
            .disabled(unavailableReason != nil)
            .accessibilityIdentifier(identifier + ".conversations")
            status
            Text("Saved history is subject to a 30-day, 256-conversation and 256 MiB policy when storage is maintained. Turning this setting off keeps saved history.")
                .foregroundStyle(.secondary)
            if service.isOn && service.phase == .running { historyStorageStatus }
            Button("Clear Saved Conversations…", role: .destructive) { confirmClear = true }
                .disabled(unavailableReason != nil || service.clearingSavedHistory ||
                          !((service.isOn && service.phase == .running) || (!service.isOn && service.phase == .off)))
                .accessibilityIdentifier(identifier + ".conversations.clear")
            Text("Backups and snapshots may retain copies; physical or cryptographic erasure is not guaranteed.")
                .foregroundStyle(.secondary)
            if let message = service.savedHistoryMessage {
                Text(verbatim: message).foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier + ".conversations.clear-status")
            }
            if let unavailableReason {
                Label(unavailableReason, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier + ".conversations.unavailable")
            }
        } footer: {
            Text("Claude Code, Codex and Pi that you start on this Mac from New Tab, signed in with a Claude or ChatGPT subscription, send their requests through a proxy on this Mac, so that iPhone and iPad can show their conversations. Claude Code's Remote Control is turned off for them. The first time you turn this on, macOS shows a “Background Items Added” notification for the proxy.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier + ".conversations.about")
        }
        .confirmationDialog("Clear Saved Conversations?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Saved Conversations", role: .destructive) { Task { await service.clearSavedHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved conversation files on this Mac will be removed where possible. Backups, snapshots, already delivered content and older volatile conversations may remain. New captures may include history sent again by the agent.")
        }
    }

    @ViewBuilder
    private var historyStorageStatus: some View {
        if let status = service.historyStatus {
            if status.mode == "degraded" || status.blockedConversations > 0 {
                Text("Some saved history is unavailable or could not be saved. Live capture may continue.")
                    .foregroundStyle(.orange)
            } else if status.mode == "healthy" {
                Text("The last storage check succeeded; recent changes may still be saving.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Saved history storage has not been verified.").foregroundStyle(.secondary)
            }
        } else {
            Text("Saved history status is unavailable.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch service.phase {
        case .off:
            EmptyView()
        case .starting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Starting the proxy…")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier + ".conversations.status")
        case .running:
            line(Text("The proxy is running. Agents you start from now on go through it."), symbol: "checkmark.circle.fill", color: .green)
        case .needsApproval:
            VStack(alignment: .leading, spacing: 8) {
                line(Text("The proxy is turned off in System Settings › General › Login Items & Extensions. Turn hrdrhrdrhrdr on there to use it."),
                     symbol: "exclamationmark.triangle.fill", color: .orange)
                Button("Open Login Items Settings…") { service.openLoginItems() }
                    .accessibilityIdentifier(identifier + ".conversations.login-items")
            }
        case .unavailable(let message):
            line(Text(verbatim: message), symbol: "exclamationmark.triangle.fill", color: .orange)
        case .stopping(let agents):
            line(Text("Stops once the \(agents) agents using it have ended."), symbol: "hourglass", color: .secondary)
        }
    }

    private func line(_ text: Text, symbol: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier + ".conversations.status")
    }
}
#endif
