#if os(macOS)
import SwiftUI

/// A single detail page: essentials first, advanced controls inline, diagnostics
/// only when a real issue exists. No third navigation level or nested sheet.
struct ExperimentalFeaturesSettingsView: View {
    let machineStore: MachineStore
    let passwordManagerWindowID: UUID
    let onBack: () -> Void
    @State private var browserPort = UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? 9333
    @State private var browserPortFailure: String?
    @State private var agentFailure: String?
    @State private var advancedExpanded = false
    @State private var checkingPrerequisites = false
    @Environment(\.dismiss) private var dismiss

    private var feature: ShepherdBrowserFeature { .shared }
    private var service: AgentLaunchService { .shared }
    private var showsOnboarding: Bool {
        feature.isEnabled && feature.passwordManagers.presentationOwner == passwordManagerWindowID
    }
    private var preparationFailure: String? {
        if case .failed(let message) = service.skillPreparation.state { return message }
        return nil
    }
    private var messages: [String] {
        ExperimentalSettingsDiagnostics.messages(browserEnabled: feature.isEnabled, refusal: feature.refusal,
            errors: [preparationFailure, agentFailure, browserPortFailure, CDPProxy.shared.error,
                     service.reconciliationError,
                     (1...65535).contains(browserPort) ? nil : String(localized: "Port must be between 1 and 65535.")])
    }
    private var showsDiagnostics: Bool {
        ExperimentalSettingsDiagnostics.shouldShow(browserEnabled: feature.isEnabled, messages: messages,
            preparationFailed: preparationFailure != nil, availability: Array(service.diagnostics.values))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onBack) { Label("Machines", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Back to Machines")
                    .accessibilityIdentifier("settings.experimental-features.back")
                Divider().frame(height: 14)
                Text("Experimental Features").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // This outer page stays alive when onboarding replaces the form.
            if showsOnboarding {
                PasswordManagerOnboardingView(preferences: feature.passwordManagers,
                                              owner: passwordManagerWindowID)
            } else {
                featuresForm.formStyle(.grouped)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .accessibilityIdentifier("settings.experimental-features.page")
        .onAppear {
            feature.passwordManagers.beginVisit(owner: passwordManagerWindowID, browserEnabled: feature.isEnabled)
        }
        .onDisappear { feature.passwordManagers.endVisit(owner: passwordManagerWindowID) }
    }

    private var featuresForm: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { feature.isEnabled },
                    set: { enabled in Task { await feature.setEnabled(enabled, presentationOwner: passwordManagerWindowID) } }
                )) {
                    HStack {
                        Text("Shepherd Browser (Experimental)")
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("About Shepherd Browser")
                            .help("An in-app pane browser. Codex resume confirmation may wait until the first user turn; live agents are never restarted automatically.")
                    }
                }
                .disabled(feature.isTransitioning)
                .help("Turning this off preserves saved tabs, profiles, cookies, and runtime settings. An already initialized idle browser engine may remain resident until quit.")
            }
            if feature.isEnabled {
                PasswordManagerSettingsSection(preferences: feature.passwordManagers,
                    windowID: passwordManagerWindowID, connectIntent: { manager in
                        feature.passwordManagers.connections.begin(owner: passwordManagerWindowID, manager: manager)
                    })
                if let activeMachine = machineStore.activeMachine {
                    AgentSkillSection(machine: activeMachine).id(activeMachine.id)
                }
                advancedSettings
            }
            if showsDiagnostics { diagnosticsSection }
        }
    }

    private var advancedSettings: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                HStack {
                    TextField("Loopback port", value: $browserPort, format: .number.grouping(.never))
                        .help("Port used only for authenticated browser connections on this Mac.")
                    Button("Apply") {
                        guard (1...65535).contains(browserPort) else { return }
                        Task {
                            do { try await service.setBrowserPort(browserPort); browserPortFailure = nil }
                            catch { browserPortFailure = connectionFailureDescription(error) }
                        }
                    }
                    .disabled(!(1...65535).contains(browserPort) || service.modeChangeBlocked)
                }
                Toggle("Block other browser tools", isOn: Binding(
                    get: { service.preferences.disableCompetingBrowsers },
                    set: { value in
                        service.preferences.disableCompetingBrowsers = value
                        saveAgentPreferences()
                    }
                ))
                .help("Only affects future Shepherd launches. Keeps agents from using competing browser tools; does not change global CLI settings.")
                if service.preferences.disableCompetingBrowsers {
                    TextField("Browser MCP servers to block", text: Binding(
                        get: { service.preferences.competingBrowserServers.joined(separator: ", ") },
                        set: { value in
                            service.preferences.competingBrowserServers = value.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                            saveAgentPreferences()
                        }
                    ), prompt: Text(verbatim: "playwright, chrome-devtools"))
                    .help("Comma-separated names from your agent's MCP configuration. This does not rename Shepherd's MCP server.")
                    .accessibilityIdentifier("settings.experimental-features.competing-servers")
                }
            }
            .accessibilityIdentifier("settings.experimental-features.advanced")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            ForEach(messages, id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .help(message.contains("global") || message.contains("duplicate-registration")
                        ? Text("An existing global Shepherd registration must be removed explicitly before session-only integration can be prepared.")
                        : Text(verbatim: message))
            }
            if feature.isEnabled {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    LabeledContent {
                        if let value = service.diagnostics[kind] {
                            Text(diagnostic(value)).font(.caption)
                        } else { Text("Not checked").font(.caption) }
                    } label: { Text(kind.title) }
                }
                if let installation = service.installation {
                    Text("Runtime version: \(installation.version)").font(.caption).textSelection(.enabled)
                }
                if let port = CDPProxy.shared.port {
                    Text("Listening on loopback port \(port). Authentication required.").font(.caption)
                }
                HStack {
                    if preparationFailure != nil {
                        Button("Retry Preparation") {
                            agentFailure = nil
                            service.prepareSkillsAutomatically(retry: true)
                        }
                        .disabled(service.skillPreparation.isBusy || checkingPrerequisites)
                    }
                    Button("Check Prerequisites Again") { Task { await checkPrerequisites() } }
                        .disabled(checkingPrerequisites || service.skillPreparation.isBusy || machineStore.activeMachine?.isLocal != true)
                    if checkingPrerequisites { ProgressView().controlSize(.small) }
                }
                if browserPortFailure != nil || !(1...65535).contains(browserPort) {
                    Button("Review Advanced Settings") { advancedExpanded = true }
                }
            }
        }
        .accessibilityIdentifier("settings.experimental-features.diagnostics")
    }

    private func saveAgentPreferences() {
        do { try service.savePreferences(); agentFailure = nil }
        catch { agentFailure = connectionFailureDescription(error) }
    }

    private func diagnostic(_ value: AgentCLIAvailability) -> String {
        switch value.readiness {
        case .missing: String(localized: "CLI missing; install it on This Mac")
        case .unsupported: value.kind == .pi ? String(localized: "Pi package or version has not been qualified") : String(localized: "CLI capability unsupported; update the CLI")
        case .unsupportedPrerequisite: value.kind == .pi ? String(localized: "Pi requires Node 22.19 or newer") : String(localized: "Node 20 or newer required")
        case .integrationUnavailable: String(localized: "Pi detected; managed browser launch is not enabled yet")
        case .availableAuthenticationUnknown: String(localized: "\(value.version ?? "Unknown version"); login unknown until launch")
        }
    }

    private func checkPrerequisites() async {
        guard let machine = machineStore.activeMachine, machine.isLocal else { return }
        checkingPrerequisites = true; agentFailure = nil
        defer { checkingPrerequisites = false }
        do {
            let client = HerdrClient(transport: try machineStore.makeHerdrTransport(for: machine))
            do {
                try await client.connect()
                try await service.check(using: client, on: machine)
                await client.disconnect()
            } catch { await client.disconnect(); throw error }
        } catch { agentFailure = connectionFailureDescription(error) }
    }
}
#endif
