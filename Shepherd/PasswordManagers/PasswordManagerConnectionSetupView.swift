#if os(macOS)
import SwiftUI
import AppKit

/// Only this human-owned view holds transient password/token input.
/// No session output or token persistence; changing authentication retires grants.
struct PasswordManagerConnectionSetupView: View {
    let coordinator: PasswordManagerConnectionCoordinator
    let owner: UUID
    @State private var metadata = PasswordManagerConnectionMetadata()
    @State private var masterPassword = ""
    @State private var serviceAccountToken = ""

    init(coordinator: PasswordManagerConnectionCoordinator, owner: UUID) {
        self.coordinator = coordinator; self.owner = owner
        _metadata = State(initialValue: coordinator.metadata(for: coordinator.providerID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.providerID == .onePassword {
                Picker("Authentication method", selection: Binding(
                    get: { metadata.onePasswordAuthentication ?? .desktopApp },
                    set: { method in updateMetadata { $0.onePasswordAuthentication = method } }
                )) {
                    Text("1Password app").tag(OnePasswordAuthenticationMethod.desktopApp)
                    Text("Service Account token").tag(OnePasswordAuthenticationMethod.serviceAccount)
                }
                .accessibilityIdentifier("password-manager.onepassword.authentication")
                if metadata.onePasswordAuthentication == .serviceAccount {
                    Text("Vault permissions are configured in 1Password, not here.")
                        .help("Built-in Personal, Private, Employee and default Shared vaults cannot be granted to a Service Account. Use a separate vault. Shepherd does not create accounts or change provider permissions.")
                } else {
                    Text("Authenticate with the 1Password app.")
                        .help("Enable desktop CLI integration yourself. Vendor approval may appear. This method uses your account permissions.")
                }
            }
            pathRow("Official CLI executable", value: metadataBinding(\.executable), directory: false)
                .help("CLI targets: op 2.32.0 / bw 2025.11.0. Installed CLI availability is a prerequisite, not vendor E2E qualification.")
            pathRow("Explicit HOME directory", value: metadataBinding(\.homeDirectory), directory: true)
            pathRow("Provider configuration directory", value: metadataBinding(\.configurationDirectory), directory: true)
                .help("Choose your official CLI and its configuration explicitly. No installation, login or vendor trust-setting changes are performed.")
            TextField("Runtime PATH (absolute directories separated by colon)", text: metadataBinding(\.runtimeSearchPath))
            TextField("Account ID", text: metadataBinding(\.accountID))
            if coordinator.providerID == .onePassword && metadata.onePasswordAuthentication == .serviceAccount {
                SecureField("Service Account token", text: $serviceAccountToken)
                    .help("Create a Service Account with the required Vault permissions in 1Password. Use read-only permissions where possible. The token stays in memory and must be entered again after disconnect or restart.")
            }
            if coordinator.providerID == .bitwarden {
                TextField("Bitwarden server URL (HTTPS, exact status URL)", text: metadataBinding(\.serverURL))
                SecureField("Bitwarden master password", text: $masterPassword)
                    .help("Use a previously signed-in Bitwarden CLI context. Complete login, SSO and 2FA externally first.")
            }
            HStack {
                Button("Cancel Connection") { clearSecrets(); coordinator.close(owner: owner) }
                Button("Connect Explicitly") {
                    let password = masterPassword, token = serviceAccountToken
                    clearSecrets()
                    coordinator.submit(owner: owner, metadata: metadata, masterPassword: password, serviceAccountToken: token)
                }
                .disabled(coordinator.state == .connecting ||
                          (coordinator.providerID == .bitwarden && masterPassword.isEmpty) ||
                          (coordinator.providerID == .onePassword && metadata.onePasswordAuthentication == .serviceAccount && serviceAccountToken.isEmpty))
                .help("Only authentication method, paths and account/server metadata are saved. Passwords, tokens and sessions stay transient; the selected vendor context may be read or written by its CLI.")
            }
            Text(detail).font(.caption)
            if coordinator.providerID == .onePassword, let access = coordinator.serviceAccountAccess {
                Text("Readable vaults").fontWeight(.medium)
                    .help("These vaults were reported as readable by the Service Account. This does not prove that write, share or vault-creation permissions are absent. Configure least privilege in 1Password.")
                ForEach(access.vaults, id: \.id) { vault in
                    LabeledContent { Text(verbatim: vault.id).textSelection(.enabled) }
                        label: { Text(verbatim: vault.name) }
                }
                Text("Read access confirmed; other permissions are not audited.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .disabled(coordinator.owner != owner)
        .onDisappear { clearSecrets(); coordinator.close(owner: owner) }
        .onChange(of: coordinator.generation) { _, _ in clearSecrets() }
    }

    private func clearSecrets() { masterPassword = ""; serviceAccountToken = "" }

    private func updateMetadata(_ update: (inout PasswordManagerConnectionMetadata) -> Void) {
        // Invalidate synchronously in the binding setter, before SwiftUI redraw.
        coordinator.configurationChanged(owner: owner)
        clearSecrets()
        update(&metadata)
    }

    private func metadataBinding(_ key: WritableKeyPath<PasswordManagerConnectionMetadata, String>) -> Binding<String> {
        Binding(get: { metadata[keyPath: key] }, set: { value in updateMetadata { $0[keyPath: key] = value } })
    }

    private func pathRow(_ title: LocalizedStringKey, value: Binding<String>, directory: Bool) -> some View {
        HStack {
            TextField(title, text: value)
            Button("Choose…") {
                let epoch = coordinator.generation
                let panel = NSOpenPanel()
                panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
                panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
                // No default vendor path, directory scan, or executable invocation.
                panel.begin { response in
                    guard response == .OK, let url = panel.url,
                          coordinator.generation == epoch, coordinator.owner == owner else { return }
                    value.wrappedValue = url.path
                }
            }
            .disabled(coordinator.state == .connecting)
        }
    }

    private var detail: LocalizedStringKey {
        switch coordinator.state {
        case .notConfigured: "Not configured. Selecting a manager does not connect or unlock it."
        case .connecting: "Checking the explicit account context…"
        case .ready: "Connected to the explicit account. This does not verify item access or browser fill."
        case .locked: "Unlock failed or the context is locked. No vendor-global lock or signout was performed."
        case .disconnected: "No authenticated connection. Sign in using the official vendor tools in the selected configuration, then retry explicitly."
        case .unavailable: "The selected CLI is unavailable. Install and configure it yourself; nothing is installed automatically."
        case .error(let failure):
            switch failure {
            case .unsupportedVersion: "Unsupported CLI version. Targets are op 2.32.0 and bw 2025.11.0; real vendor compatibility has not been verified."
            case .accountMismatch: "Account or server mismatch. No connection was accepted."
            case .invalidServiceAccountToken: "Enter a valid Service Account token. No other authentication method will be tried."
            case .serviceAccountRequired: "The token did not authenticate an active Service Account."
            case .serviceAccountScopeUnavailable: "The Service Account's readable vaults could not be verified. No connection was accepted."
            case .serviceAccountScopeChanged: "The Service Account identity or readable vaults changed. Existing approvals were revoked. Reconnect explicitly."
            case .notConfigured: "Enter valid absolute paths, runtime PATH, account ID and the required HTTPS Bitwarden server URL."
            default: "Connection failed. Sensitive command output is not displayed. Retry only after checking the official vendor setup."
            }
        }
    }
}
#endif
