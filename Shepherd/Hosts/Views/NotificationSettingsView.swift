#if os(macOS)
import AppKit
import SwiftUI

/// The Notifications page of Settings: whether macOS lets Shepherd show
/// notifications at all, which agent events it gives them for, and how they
/// go with herdr's own.
struct NotificationSettingsView: View {
    let onBack: () -> Void

    private var coordinator: NotificationCoordinator { .shared }

    var body: some View {
        @Bindable var preferences = coordinator.preferences
        VStack(spacing: 0) {
            SettingsPageHeader(title: "Notifications",
                               backAccessibilityIdentifier: "settings.notifications.back",
                               onBack: onBack)

            Form {
                Section {
                    LabeledContent("Notifications from Shepherd") {
                        permission
                    }
                }
                Section {
                    Toggle(isOn: $preferences.notifiesNeedsInput) {
                        HStack {
                            Text("An agent is waiting for your input")
                            InfoButton(accessibilityLabel: "About Needs Input Notifications",
                                       explanation: "When herdr reports an agent as blocked: waiting for an answer, or for your approval to go on. herdr doesn't recognize every prompt, and one it doesn't gets no notification.")
                        }
                    }
                    .accessibilityIdentifier("settings.notifications.needs-input")
                    Toggle(isOn: $preferences.notifiesFinished) {
                        HStack {
                            Text("An agent has finished")
                            InfoButton(accessibilityLabel: "About Finished Notifications",
                                       explanation: "When an agent that was working, or waiting for your input, goes idle or done. An agent that has only just started isn't reported.")
                        }
                    }
                    .accessibilityIdentifier("settings.notifications.finished")
                } header: {
                    Text("Notify Me When")
                } footer: {
                    Text("Shepherd watches the agents on all of your machines, the active one and the others, for as long as it is running — with its window closed, too. A pane you are looking at doesn't notify.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("herdr's own notifications")
                        InfoButton(accessibilityLabel: "About herdr's Own Notifications",
                                   explanation: "herdr shows notifications of its own only while herdr itself is open in a terminal app, never through Shepherd. If you have it open there, you may get both: to keep only Shepherd's, set delivery = \"off\" under [ui.toast] in herdr's config.toml. Shepherd doesn't read or change herdr's settings.")
                    }
                }
            }
            .formStyle(.grouped)
            SettingsPageFooter()
        }
        .accessibilityIdentifier("settings.notifications.page")
        .onAppear { coordinator.refreshAuthorization() }
    }

    /// What macOS allows, and the way to change it.
    @ViewBuilder
    private var permission: some View {
        switch coordinator.authorization {
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        case .denied:
            HStack {
                Text("Turned Off")
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { openSystemSettings() }
            }
        case .notDetermined:
            Button("Allow Notifications…") { coordinator.requestAuthorization() }
                .accessibilityIdentifier("settings.notifications.allow")
        case .unknown:
            ProgressView().controlSize(.small)
        }
    }

    /// System Settings' Notifications pane, at Shepherd's entry.
    private func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
            ?? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
#endif
