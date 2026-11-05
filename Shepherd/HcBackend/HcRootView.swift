import SwiftUI

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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @State private var installation = false
    @State private var launchSheet = false
    @State private var switcher = false
    @State private var origins = false
    @State private var routeNotice: String?
    @State private var operationError: String?
    @State private var viewingEpoch = UUID()
    @State private var commandOwner = UUID()
    @AppStorage("hc.browserRetirementNoticeDismissed") private var retirementDismissed = false
    init(machineStore: MachineStore, connection: HcMachineConnection? = nil, localTransport: (any CoreByteTransport)? = nil) {
        self.machineStore = machineStore; self.localTransport = localTransport
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
            writable: model?.workspace?.canWrite ?? false, sheets: [launchSheet,switcher,settings,installation,origins,model?.operationReview != nil])
    }
    var body: some View {
        dialogs
            .task(id: machineStore.activeMachine?.connectionIdentity) {
                guard let machine = machineStore.activeMachine else { await connection.close(); return }
                await connection.open(machine: machine, store: machineStore, localTransport: localTransport)
            }
            .onAppear(perform: appeared)
            .onChange(of: changes) { routeAndViewed() }
            .onChange(of: machineStore.activeMachine?.connectionIdentity) { origins = false }
            .onChange(of: scenePhase) { if scenePhase == .active { HcNotificationCoordinator.shared.refreshAuthorization() }; routeAndViewed() }
            .onChange(of: HcNotificationCoordinator.shared.navigationRequest, initial: true) { routeAndViewed() }
            .onDisappear(perform: disappeared)
    }
    private var dialogs: some View {
        contents.frame(minWidth: 760, minHeight: 480)
            .sheet(isPresented: $launchSheet) { if let model = scopedModel { HcLaunchSheet(model: model, machineName: machineStore.activeMachine?.displayName ?? "Machine") } }
            .sheet(isPresented: $switcher) { if let model = scopedModel { HcPaneSwitcher(model: model) } }
            .sheet(isPresented: $settings) { MachinesSettingsView(machineStore: machineStore) }
            .sheet(isPresented: $installation) { HcInstallationView(machine: machineStore.activeMachine) }
            .sheet(isPresented: $origins) { if let model = scopedModel { HcGatewayDirectoryView(model: model) } }
            .alert("Workspace operation", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                Button("OK") { operationError = nil }
            } message: { Text(operationError ?? "") }
    }
    private var contents: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Machine", selection: Binding(get: { machineStore.activeMachineID }, set: { machineStore.activeMachineID = $0 })) {
                    ForEach(machineStore.allMachines) { Text($0.displayName).tag(Optional($0.id)) }
                }.frame(maxWidth: 280)
                Button("New Terminal…") { launchSheet = true }.disabled(scopedModel?.canEdit != true).accessibilityIdentifier("hc.launch.open")
                Button("Core origins…") { origins = true }
                    .disabled(scopedModel?.state != .connected || scopedModel?.operationReview != nil)
                    .accessibilityIdentifier("hc.origins.open")
                Spacer()
                if let coreID = scopedModel?.coreID { Text("hc · " + String(coreID.prefix(12))).font(.caption).foregroundStyle(.secondary) }
                if let machine = machineStore.activeMachine {
                    Button("Reconnect") { Task { await connection.open(machine: machine, store: machineStore, localTransport: localTransport) } }
                }
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
            }.padding(10)
            Divider()
            if !retirementDismissed && UserDefaults.standard.bool(forKey: ShepherdBrowserFeature.preferenceKey) {
                HStack(alignment: .top) {
                    Text("In-app Browser and injected agent integrations are unavailable in this hc release. Existing terminal programs are untouched; integrations from older sessions are not resumed. Browser data and runtime settings are preserved.").font(.caption)
                    Spacer(); Button("Dismiss") { retirementDismissed = true }
                }.padding(10).background(Color.orange.opacity(0.12))
            }
            if let routeNotice { Text(routeNotice).font(.caption).padding(8) }
            if let model = scopedModel { HcWorkspaceView(model: model, machine: machineStore.activeMachine, machineStore: machineStore) }
            else { unavailable }
        }
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
        let split = (tab?.layout?.panes.count ?? 0) > 1
        let available = !launchSheet && !switcher && !settings && !installation && !origins && model?.operationReview == nil
        return HcWindowActions(canLaunch: available && model?.canEdit == true, canClose: available && model?.canEdit == true && tab != nil,
            canSwitch: available && model?.state == .connected, canSettings: available, closeTitle: split ? "Close Pane View" : "Close Tab View",
            launch: {
                guard let current = scopedModel, current.canEdit, !launchSheet, !switcher, !settings, !installation, !origins else { return }
                launchSheet = true
            }, close: {
                guard let current = scopedModel, current.canEdit, !origins, let selected = current.selectedTab else { return }
                let selectedPane = current.focus.paneByTab[selected.id], isSplit = (selected.layout?.panes.count ?? 0) > 1
                Task {
                    guard scopedModel === current, current.canEdit, current.selectedTab?.id == selected.id else { return }
                    do { if isSplit, let selectedPane { try await current.closePane(selectedPane) } else { try await current.closeTab(selected.id) } }
                    catch { operationError = "Close unconfirmed. Review the current layout and saved operation; no program was terminated." }
                }
            }, switcher: {
                guard scopedModel?.state == .connected, scopedModel?.operationReview == nil,
                      !launchSheet, !switcher, !settings, !installation, !origins else { return }
                switcher = true
            }, settings: {
                guard scopedModel?.operationReview == nil, !launchSheet, !switcher, !settings, !installation, !origins else { return }
                settings = true
            })
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
