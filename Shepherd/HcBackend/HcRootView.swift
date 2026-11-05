import SwiftUI

private enum HcInspectionLaunchFailure: Error, LocalizedError {
    case shellOnly
    var errorDescription: String? { "This private inspection environment supports Shell only. Claude Code, Codex and Pi are not connected to your installed CLIs or accounts. No program was started." }
}

private struct HcRootChanges: Equatable {
    let machine: Machine.ConnectionIdentity?
    let state: HcWorkspaceModel.State?
    let document: CoreWorkspaceDocument?
    let focus: CoreWorkspaceFocus?
    let busy: Bool
    let writable: Bool
    let sheets: [Bool]
}

/// Product root. Scope selection invalidates the old screen synchronously;
/// async teardown/connect never makes an old model look like the new host.
struct HcRootView: View {
    let machineStore: MachineStore
    @State private var connection: HcMachineConnection
    private let localTransport: (any CoreByteTransport)?
    private let inspectionOnly: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @State private var installation = false
    @State private var launchSheet = false
    @State private var switcher = false
    @State private var origins = false
    @State private var tracking = false
    @State private var closeRequests = 0
    @State private var launcherUsesCurrentWorkspace = false
    @State private var renamingTitle = false
    @AppStorage(AgentBoardView.showsTabsKey) private var showsTabs = false
    @State private var routeNotice: String?
    @State private var operationError: String?
    @State private var viewingEpoch = UUID()
    @State private var commandOwner = UUID()
    @AppStorage("hc.browserRetirementNoticeDismissed") private var retirementDismissed = false
    init(machineStore: MachineStore, connection: HcMachineConnection? = nil, localTransport: (any CoreByteTransport)? = nil, inspectionOnly: Bool = false) {
        self.machineStore = machineStore; self.localTransport = localTransport; self.inspectionOnly = inspectionOnly
        _connection = State(initialValue: connection ?? HcMachineConnection())
    }
    private var scopedModel: HcWorkspaceModel? {
        guard let machine = machineStore.activeMachine, connection.identity == machine.connectionIdentity,
              machineStore.isCurrentConnection(machine) else { return nil }
        return connection.model
    }
    private var changes: HcRootChanges {
        let model = scopedModel
        return HcRootChanges(machine: machineStore.activeMachine?.connectionIdentity, state: model?.state,
            document: model?.document, focus: model?.focus, busy: model?.operationBusy ?? false,
            writable: model?.workspace?.canWrite ?? false, sheets: [launchSheet,switcher,settings,installation,origins,tracking,renamingTitle,model?.operationReview != nil])
    }
    var body: some View {
        dialogs
            .task(id: machineStore.activeMachine?.connectionIdentity) {
                guard let machine = machineStore.activeMachine else { await connection.close(); return }
                await connection.open(machine: machine, store: machineStore, localTransport: localTransport)
            }
            .onAppear(perform: appeared)
            .onChange(of: changes) { routeAndViewed() }
            .onChange(of: machineStore.activeMachine?.connectionIdentity) { origins = false; tracking = false; launchSheet = false; switcher = false }
            .onChange(of: scenePhase) { if scenePhase == .active { HcNotificationCoordinator.shared.refreshAuthorization() }; routeAndViewed() }
            .onChange(of: HcNotificationCoordinator.shared.navigationRequest, initial: true) { routeAndViewed() }
            .onDisappear(perform: disappeared)
    }
    private var dialogs: some View {
        contents
            .sheet(isPresented: $tracking) { if let model = scopedModel { HcOperationTrackingView(model: model) } }
            .sheet(isPresented: $switcher) { if let model = scopedModel { HcPaneSwitcher(model: model) } }
            .sheet(isPresented: $settings) { MachinesSettingsView(machineStore: machineStore) }
            .sheet(isPresented: $installation) { HcInstallationView(machine: machineStore.activeMachine) }
            .sheet(isPresented: $origins) { if let model = scopedModel { HcGatewayDirectoryView(model: model) } }
            .alert("Workspace operation", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                Button("OK") { operationError = nil }
            } message: { Text(operationError ?? "") }
    }
    private var contents: some View {
        HcWorkspaceView(model: scopedModel, machine: machineStore.activeMachine, machineStore: machineStore,
            closeRequests: closeRequests,
            onSettings: { if !launchSheet && !switcher && !tracking { settings = true } },
            onLaunch: { openLauncher(currentWorkspace: false) },
            onSwitcher: { if !launchSheet && !tracking { switcher = true } },
            onOrigins: { origins = true }, onTracking: { tracking = true },
            onReconnect: {
                guard let machine = machineStore.activeMachine else { return }
                Task { await connection.open(machine: machine, store: machineStore, localTransport: localTransport) }
            }, onRenameVisibility: { renamingTitle = $0 }, unavailable: AnyView(unavailable))
        .overlay {
            if launchSheet, let model = scopedModel {
                NewTabLauncher(targets: launchTargets(model), preset: launcherPreset(model),
                    standalonePrograms: true,
                    allowedStandalonePrograms: inspectionOnly ? [.shell] : LaunchProgram.allCases,
                    standaloneProgramNotice: inspectionOnly ? "Private UI inspection: Shell only, temporary HOME, network disabled. Installed agent CLIs and accounts are not connected." : nil,
                    describeFailure: { error in
                        if let inspection = error as? HcInspectionLaunchFailure { return inspection.localizedDescription }
                        return hcConnectionFailureDescription(error) + " If a view was created, review its saved outcome before another launch."
                    },
                    create: { request, handOff in try await launch(request, model: model, handOff: handOff) },
                    onClose: { launchSheet = false })
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let routeNotice { Text(routeNotice).font(.caption).padding(8) }
            if !retirementDismissed && UserDefaults.standard.bool(forKey: ShepherdBrowserFeature.preferenceKey) {
                HStack {
                    Text("In-app Browser and injected integrations are unavailable. Existing programs and data are preserved.").font(.caption)
                    Spacer(); Button("Dismiss") { retirementDismissed = true }
                }.padding(8)
            }
        }
    }
    private func launchTargets(_ model: HcWorkspaceModel) -> [LaunchTarget] {
        [.init(herdrMachine: nil, label: machineStore.activeMachine?.displayName ?? "Machine",
            workspaces: (model.document?.workspaces ?? []).map {
                .init(workspace: .init(workspaceID: $0.id.uuidString, label: $0.name), tabCount: $0.tabs.count)
            }, unavailableReason: model.canEdit ? nil : "Connection is not writable.")]
    }
    private func launcherPreset(_ model: HcWorkspaceModel) -> LaunchPreset? {
        guard launcherUsesCurrentWorkspace, let id = model.focus.workspaceID,
              let workspace = model.document?.workspaces.first(where: { $0.id == id }) else { return nil }
        return .init(targetID: "host", workspace: .init(workspaceID: id.uuidString, label: workspace.name))
    }
    private func openLauncher(currentWorkspace: Bool) {
        guard scopedModel?.canEdit == true, !switcher, !settings, !installation, !origins, !tracking else { return }
        launcherUsesCurrentWorkspace = currentWorkspace
        launchSheet.toggle()
    }
    private func launch(_ request: LaunchRequest, model: HcWorkspaceModel, handOff: @escaping @MainActor () -> Void) async throws {
        guard scopedModel === model, model.canEdit, request.herdrMachine == nil else { throw HcWorkspaceModel.Failure.stale }
        // Reject unsupported inspection intent BEFORE even creating workspace
        // or placeholder metadata. Never borrow the user's CLI/config instead.
        guard !inspectionOnly || request.program == .shell else { throw HcInspectionLaunchFailure.shellOnly }
        let workspaceID: UUID
        switch request.workspace {
        case .existing(let selected):
            guard let id = UUID(uuidString: selected.workspaceID), model.document?.workspaces.contains(where: { $0.id == id }) == true else {
                throw HcWorkspaceModel.Failure.stale
            }
            workspaceID = id
        case .new(let name):
            workspaceID = try await model.createWorkspace(name: name ?? "Workspace")
        }
        guard scopedModel === model else { throw HcWorkspaceModel.Failure.stale }
        let argv: [String]
        switch request.program {
        case .shell: argv = []
        case .claude: argv = ["claude"]
        case .codex: argv = ["codex", "--no-daemon"]
        case .pi: argv = ["pi"]
        }
        try await model.launchTab(workspaceID: workspaceID, name: request.tabName ?? String(localized: request.program.title), argv: argv)
        guard scopedModel === model else { return }
        handOff()
    }
    private var unavailable: some View {
        VStack(spacing: 16) {
            if connection.phase == .connecting { ProgressView("Connecting to hc…") }
            else {
                Image(systemName: "terminal").font(.largeTitle)
                Text(connection.phase == .missingExecutable ? "hc is not installed" : "hc connection unavailable").font(.title2)
                Text(connection.message ?? "Add or select a machine to connect.").textSelection(.enabled).multilineTextAlignment(.center).frame(maxWidth: 560)
                if case .approveHostKey(let fingerprint) = connection.phase, let machine = machineStore.activeMachine {
                    Text(machine.username + "@" + machine.hostname + ":" + String(machine.port)).font(.headline)
                    Text(fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Approve this host key and connect") { Task { await connection.approve(machine: machine, store: machineStore) } }
                }
                Button("Installation / compatibility help") { installation = true }
            }
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var actions: HcWindowActions {
        let model = scopedModel, tab = model?.selectedTab
        let available = !launchSheet && !switcher && !settings && !installation && !origins && !tracking && !renamingTitle && model?.operationReview == nil
        return HcWindowActions(canLaunch: available && model?.canEdit == true, canClose: available && model?.canEdit == true && tab != nil,
            canSwitch: available && model?.state == .connected, canSettings: available, closeTitle: showsTabs ? "Close Tab" : "Close Pane",
            launch: {
                guard let current = scopedModel, current.canEdit, !launchSheet, !switcher, !settings, !installation, !origins else { return }
                openLauncher(currentWorkspace: false)
            }, close: {
                guard scopedModel?.canEdit == true, !origins, !tracking else { return }
                closeRequests += 1
            }, switcher: {
                guard scopedModel?.state == .connected, scopedModel?.operationReview == nil,
                      !launchSheet, !switcher, !settings, !installation, !origins else { return }
                switcher = true
            }, settings: {
                guard scopedModel?.operationReview == nil, !launchSheet, !switcher, !settings, !installation, !origins else { return }
                settings = true
            }, launchCurrentWorkspace: { openLauncher(currentWorkspace: true) })
    }
    private func appeared() {
        HcWindowCommandState.shared.claim(commandOwner, actions: actions)
        HcNotificationCoordinator.shared.openWindow = openWindow; routeAndViewed()
    }
    private func disappeared() {
        HcWindowCommandState.shared.release(commandOwner)
        Task { await HcNotificationCoordinator.shared.setViewed(machine: nil, coreID: nil); await connection.close() }
    }
    private func routeAndViewed() {
        HcWindowCommandState.shared.update(commandOwner, actions: actions)
        let epoch = UUID(); viewingEpoch = epoch
        let notifications = HcNotificationCoordinator.shared
        if let route = notifications.navigationRequest, let model = scopedModel, model.state == .connected, machineStore.activeMachineID == route.machineID {
            if model.coreID == route.coreID, let pane = model.document?.panes.first(where: { $0.terminal?.coreID == route.coreID && $0.terminal?.terminalID == route.terminalID }) {
                do { try model.select(pane: pane.id); routeNotice = nil } catch { routeNotice = "Could not save the local selection." }
            } else { routeNotice = "That notification no longer has a view in this origin. Nothing was launched or retargeted; choose a live core terminal explicitly." }
            notifications.navigationRequest = nil
        }
        guard scenePhase == .active, let model = scopedModel, model.state == .connected, let tab = model.selectedTab else {
            Task { guard viewingEpoch == epoch else { return }; await notifications.setViewed(machine: nil, coreID: nil) }; return
        }
        let zoom = model.focus.zoomByTab[tab.id]
        let panes = (tab.layout?.panes ?? []).filter { zoom == nil || $0.id == zoom }
        let ids = Set(panes.compactMap { $0.terminal?.coreID == model.coreID ? $0.terminal?.terminalID : nil })
        let machine = machineStore.activeMachine
        Task {
            guard viewingEpoch == epoch, scopedModel === model, machineStore.activeMachineID == machine?.id else { return }
            await notifications.setViewed(machine: machine, coreID: model.coreID, terminalIDs: ids)
        }
    }
}

private struct HcInstallationView: View {
    let machine: Machine?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("hc installation and compatibility").font(.title2)
            Text(machine?.isLocal == true ? "Install for this Mac's account." : "Run the official installer on the selected SSH host, as the same account you connect with. iPhone and iPad do not install a local core.")
            Text(HcReleasePolicy.installCommand)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Link("Review the official installer", destination: URL(string: "https://releases.herdr.dev/core/install.sh")!)
            Text("Shepherd checks API generation and required methods when connecting. For an older core, update hc; for a newer API generation, update Shepherd. A successful handshake does not qualify every renderer feature.")
            Text(HcReleasePolicy.installationNotice)
            Text(HcReleasePolicy.renderingNotice).foregroundStyle(.secondary)
            Text(HcReleasePolicy.privacyNotice).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 590)
    }
}
