import SwiftUI

/// Product root: machine management stays in MachineStore; every live board
/// connection is hc. No browser runtime or legacy HerdrClient is constructed.
struct HcRootView: View {
    let machineStore: MachineStore
    @State private var connection: HcMachineConnection
    private let localTransport: (any CoreByteTransport)?
    init(machineStore: MachineStore, connection: HcMachineConnection? = nil, localTransport: (any CoreByteTransport)? = nil) {
        self.machineStore = machineStore; self.localTransport = localTransport
        _connection = State(initialValue: connection ?? HcMachineConnection())
    }
    @State private var settings = false
    @State private var installation = false
    @AppStorage("hc.browserRetirementNoticeDismissed") private var retirementDismissed = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Machine", selection: Binding(get: { machineStore.activeMachineID }, set: { machineStore.activeMachineID = $0 })) {
                    ForEach(machineStore.allMachines) { machine in Text(machine.displayName).tag(Optional(machine.id)) }
                }.frame(maxWidth: 280)
                Spacer()
                if let coreID = connection.model?.coreID { Text("hc · " + String(coreID.prefix(12))).font(.caption).foregroundStyle(.secondary) }
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
            }.padding(10)
            Divider()
            if !retirementDismissed && UserDefaults.standard.bool(forKey: ShepherdBrowserFeature.preferenceKey) {
                HStack(alignment: .top) {
                    Text("In-app Browser and injected agent integrations are unavailable in this hc release. Existing terminal programs are untouched; integrations from older sessions are not resumed. Browser data and runtime settings are preserved.").font(.caption)
                    Spacer()
                    Button("Dismiss") { retirementDismissed = true }
                }.padding(10).background(Color.orange.opacity(0.12))
            }
            if let model = connection.model {
                HcWorkspaceView(model: model, machine: machineStore.activeMachine, machineStore: machineStore)
            } else {
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
                        HStack {
                            Button("Installation / compatibility help") { installation = true }
                            if let machine = machineStore.activeMachine {
                                Button("Retry") { Task { await connection.open(machine: machine, store: machineStore) } }
                            }
                        }
                    }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .focusedSceneValue(\.isShowingSettings, $settings)
        .sheet(isPresented: $settings) { MachinesSettingsView(machineStore: machineStore) }
        .sheet(isPresented: $installation) { HcInstallationView(machine: machineStore.activeMachine) }
        .task(id: machineStore.activeMachine?.connectionIdentity) {
            guard let machine = machineStore.activeMachine else { await connection.close(); return }
            await connection.open(machine: machine, store: machineStore, localTransport: localTransport)
        }
        .onDisappear { Task { await connection.close() } }
    }
}

private struct HcInstallationView: View {
    let machine: Machine?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("hc installation and compatibility").font(.title2)
            Text(machine?.isLocal == true ? "Install for this Mac's account." : "Run the official installer on the selected SSH host, as the same account you connect with. iPhone and iPad do not install a local core.")
            Text("curl -fsSL https://releases.herdr.dev/core/install.sh | sh")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Link("Review the official installer", destination: URL(string: "https://releases.herdr.dev/core/install.sh")!)
            Text("Shepherd checks API generation and required methods when connecting. For an older core, update hc; for a newer API generation, update Shepherd. A successful handshake does not qualify every renderer feature.")
            Text("Installation does not authorize restarting a running core. Existing programs, package-manager installations and user configuration are not replaced by this screen.")
            Text("Known limitation: official hc 0.1.17 has retained OSC8/blank-background rendering failures. The hc release gate remains incomplete until a supported artifact passes those checks.")
                .foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 590)
    }
}
