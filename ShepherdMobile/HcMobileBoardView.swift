import SwiftUI
import ShepherdKit

struct HcMobileBoardView: View {
    let machine: Machine
    let machineStore: MachineStore
    let cache: HcMobileCache
    @State private var connection = HcMachineConnection()
    @State private var cached: HcMobileCache.Snapshot?
    @Environment(\.scenePhase) private var scenePhase

    private var liveModel: HcWorkspaceModel? {
        guard let model = connection.model, model.state == .connected else { return nil }
        return model
    }
    private var coreID: String? { liveModel?.coreID ?? cached?.coreID }
    private var records: [HcMobileCache.Record] {
        if let model = liveModel {
            return model.terminals.map { .init(address: $0.address, title: $0.name ?? $0.title, state: $0.state, status: $0.reported ? $0.status?.state : nil) }
        }
        return cached?.terminals ?? []
    }
    private var document: CoreWorkspaceDocument? {
        if let model = liveModel { return model.document } // Confirmed missing is not a reason to resurrect cached layout.
        return cached?.document
    }
    var body: some View {
        List {
            if liveModel == nil {
                Section {
                    if connection.phase == .connecting { ProgressView("Connecting to hc…") }
                    if let message = connection.message { Text(message).font(.footnote) }
                    if case .approveHostKey(let pin) = connection.phase {
                        Text(pin).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        Button("Approve verified host key") { Task { await connection.approve(machine: machine, store: machineStore) } }
                    }
                    Button("Retry") { Task { await connection.open(machine: machine, store: machineStore) } }
                    if let cached { Text("Saved display from \(cached.date.formatted()). Actions verify a live connection and terminal before sending.").font(.caption).foregroundStyle(.secondary) }
                    Text("Install or update hc on this SSH host, not on iPhone or iPad. The app never installs a local core on this device.").font(.caption)
                }
            }
            ForEach(document?.workspaces ?? [], id: \.id) { workspace in
                Section(workspace.name) {
                    ForEach(workspace.tabs, id: \.id) { tab in
                        ForEach(tab.layout?.panes ?? [], id: \.id) { pane in
                            if let reference = pane.terminal, reference.coreID == coreID {
                                row(address: reference.terminalID, title: pane.title ?? tab.name)
                            } else { Text(tab.name + " · remote or unbound pane").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("Core terminals") {
                ForEach(records) { record in row(address: record.address, title: record.title.isEmpty ? record.address : record.title) }
            }
        }
        .navigationTitle(machine.displayName)
        .refreshable { await connection.open(machine: machine, store: machineStore) }
        .task(id: scenePhase) {
            if scenePhase == .active {
                if cached == nil { cached = cache.load(machine: machine, store: machineStore) }
                await connection.open(machine: machine, store: machineStore)
                remember()
            } else { remember(); await connection.close() }
        }
        .onChange(of: connection.model?.terminals) { remember() }
        .onChange(of: connection.model?.document) { remember() }
    }
    @ViewBuilder private func row(address: String, title: String) -> some View {
        if let coreID {
            NavigationLink {
                HcMobileTerminalView(machine: machine, machineStore: machineStore, coreID: coreID, terminalID: address, title: title)
            } label: {
                VStack(alignment: .leading) {
                    Text(title)
                    if let record = records.first(where: { $0.address == address }) {
                        Text([record.state, record.status ?? String(localized: "Status unreported")].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else { Text(title).foregroundStyle(.secondary) }
    }
    private func remember() {
        if let model = connection.model, let saved = cache.save(model: model, machine: machine, store: machineStore) { cached = saved }
    }
}


struct HcMobileTerminalView: View {
    let title: String
    @State private var model: HcConversationModel
    @State private var keyboardAvoidance = KeyboardAvoidanceState()
    @Environment(\.scenePhase) private var scenePhase
    init(machine: Machine, machineStore: MachineStore, coreID: String, terminalID: String, title: String) {
        self.title = title
        _model = State(initialValue: HcConversationModel(machine: machine, store: machineStore, origin: coreID, terminalID: terminalID))
    }
    var body: some View {
        KeyboardAvoidingBottomBarContainer(state: keyboardAvoidance) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = model.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Text(model.output ?? String(localized: "Reading hc terminal…")).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding()
            }.refreshable { try? await model.refresh() }
        } bottomBar: {
            VStack(spacing: 8) {
                Text(model.record?.status?.state ?? String(localized: "Status unreported")).font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["enter", "esc", "up", "down", "tab", "ctrl+c", "y", "n"], id: \.self) { key in
                            Button(key) { Task { await model.send(keys: [key]) } }
                        }
                    }
                }
                HStack {
                    TextField("Text", text: $model.draft, axis: .vertical).lineLimit(1...6)
                    Button("Type only") { Task { await model.send(textOnly: true) } }
                    Button("Send + Enter") { Task { await model.send() } }
                }
            }.padding().disabled(!model.connected || model.busy || model.record?.state != "live")
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            if scenePhase == .active { await model.run() }
            else { await model.pause() }
        }
    }
}
