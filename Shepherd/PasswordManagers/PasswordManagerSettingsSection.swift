#if os(macOS)
import SwiftUI
import AppKit

struct PasswordManagerSettingsSection: View {
    let preferences: PasswordManagerPreferences
    let windowID: UUID
    /// Explicit Settings intent. The app-owned coordinator leases one window.
    let connectIntent: @MainActor (PasswordManagerProviderID) -> Void

    var body: some View {
        Section("Password Manager") {
            PasswordManagerPicker(selection: Binding(get: { preferences.selectedManager }, set: {
                preferences.select($0)
            }))
            .help("Selecting a manager does not connect or unlock it.")
            if preferences.selectedManager != .none {
                Button("Connect…") {
                    connectIntent(preferences.selectedManager)
                }
                if preferences.connections.owner == windowID {
                    PasswordManagerConnectionSetupView(coordinator: preferences.connections, owner: windowID)
                        .id(preferences.selectedManager)
                    if let grant = preferences.connections.credentialGrantController {
                        CredentialGrantView(controller: grant, connection: preferences.connections)
                    } else {
                        Text("Credential broker unavailable. Connection is not browser authorization.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if preferences.connections.owner != nil {
                    Text("Connection setup is open in another window.").font(.caption)
                }
            }
        }
    }
}

struct PasswordManagerPicker: View {
    @Binding var selection: PasswordManagerProviderID
    var body: some View {
        Picker("Password Manager", selection: $selection) {
            Text("None").tag(PasswordManagerProviderID.none)
            Text(verbatim: "1Password").tag(PasswordManagerProviderID.onePassword)
            Text(verbatim: "Bitwarden").tag(PasswordManagerProviderID.bitwarden)
        }
    }
}

/// Inline Settings page: no nested sheet, and only the leased window renders it.
struct PasswordManagerOnboardingView: View {
    let preferences: PasswordManagerPreferences
    let owner: UUID
    @State private var selection: PasswordManagerProviderID = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Password Manager").font(.title2)
            Text("You can skip and keep the browser enabled. Change your manager later in Settings.")
            PasswordManagerPicker(selection: $selection)
            Text("Not configured. Selecting a manager does not connect or unlock it.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Cancel") {
                    preferences.releasePresentation(owner: owner)
                }
                Spacer()
                Button("Skip") { preferences.complete(owner: owner, manager: .none) }
                Button("Continue") { preferences.complete(owner: owner, manager: selection) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear { selection = preferences.selectedManager }
    }
}
#endif
