#if os(macOS) && !SHEPHERD_LEGACY_FIXTURES
import SwiftUI

/// The hc Settings page retains File Drop; no browser/runtime initialization.
struct ExperimentalFeaturesSettingsView: View {
    let machineStore: MachineStore
    let passwordManagerWindowID: UUID
    let onBack: () -> Void
    @AppStorage(TerminalFileDropFeature.preferenceKey) private var terminalFileDropEnabled = false
    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: "Experimental Features",
                               backAccessibilityIdentifier: "settings.experimental-features.back",
                               onBack: onBack)
            Form {
                Section {
                    Text("In-app Browser and app-injected agent integrations are unavailable in this release. Existing programs, settings and data are preserved.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Toggle(isOn: $terminalFileDropEnabled) {
                        HStack {
                            Text("Terminal File Drop")
                            InfoButton(accessibilityLabel: "About Terminal File Drop",
                                       explanation: "Drop files from Finder onto a terminal pane to paste their paths. For panes on another machine, PNG, JPEG, GIF, and WebP images are first uploaded to ~/.cache/3rdr/drops on that machine.")
                        }
                    }
                    .help("Uploaded images are removed after 24 hours, the next time you drop files on that machine.")
                    .accessibilityIdentifier("settings.experimental-features.terminal-file-drop")
                }
            }.formStyle(.grouped)
            SettingsPageFooter()
        }.accessibilityIdentifier("settings.experimental-features.page")
    }
}
#endif
