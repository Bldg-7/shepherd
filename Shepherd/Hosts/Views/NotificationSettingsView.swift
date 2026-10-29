#if os(macOS)
import AppKit
import SwiftUI

/// The Notifications page of Settings: whether macOS lets Shepherd show
/// notifications at all, which agent events it gives them for, the Dock
/// icon's badge, which machines it watches, and how they go with herdr's
/// own.
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
                    LabeledContent("Notifications from hrdrhrdrhrdr") {
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
                    Toggle(isOn: $preferences.notifiesExited) {
                        HStack {
                            Text("An agent has quit while working")
                            InfoButton(accessibilityLabel: "About Quit While Working Notifications",
                                       explanation: "When an agent that was working a moment ago is gone from its pane, and the pane is still open: it was stopped, or it crashed. Closing the pane, or quitting an agent that had already been done for a while, isn't reported.")
                        }
                    }
                    .accessibilityIdentifier("settings.notifications.exited")
                } header: {
                    Text("Notify Me When")
                } footer: {
                    Text("hrdrhrdrhrdr watches the agents on the machines turned on below, the active one and the others, for as long as it is running — with its window closed, too. A pane you are looking at doesn't notify.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Show agents waiting for input on the Dock icon", isOn: $preferences.showsBadge)
                        .accessibilityIdentifier("settings.notifications.badge")
                    if preferences.showsBadge, coordinator.authorization == .allowed, coordinator.badgesAreOff {
                        HStack {
                            Text("Badges for hrdrhrdrhrdr are turned off in System Settings.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open System Settings") { openSystemSettings() }
                        }
                        .accessibilityIdentifier("settings.notifications.badge-off")
                    }
                }
                Section {
                    ForEach(coordinator.machineStore?.allMachines ?? []) { machine in
                        Toggle(machine.displayName, isOn: Binding(
                            get: { !preferences.isMuted(machine.id) },
                            set: { preferences.setMuted(!$0, machine.id) }
                        ))
                        .accessibilityIdentifier("settings.notifications.machine.\(machine.id.uuidString)")
                    }
                } header: {
                    Text("Machines")
                } footer: {
                    Text("A machine turned off gets no notifications and adds nothing to the Dock icon, and isn't connected to for them while the board isn't showing it. Its herdr machines go with it.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("herdr's own notifications")
                        InfoButton(accessibilityLabel: "About herdr's Own Notifications",
                                   explanation: "herdr shows notifications of its own only while herdr itself is open in a terminal app, never through hrdrhrdrhrdr. If you have it open there, you may get both: to keep only hrdrhrdrhrdr's, set delivery = \"off\" under [ui.toast] in herdr's config.toml. hrdrhrdrhrdr doesn't read or change herdr's settings.")
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
