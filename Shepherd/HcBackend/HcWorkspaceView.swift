import SwiftUI

/// New hc workspace composition. Intentionally has NO browser/MCP/runtime
/// dependency. A dedicated migration host supplies one verified connection;
/// there is no legacy fallback inside this view or its model.
struct HcWorkspaceView: View {
    let model: HcWorkspaceModel
    var machine: Machine? = nil
    var machineStore: MachineStore? = nil
    @State private var error: String?
    @State private var newWorkspaceName = "Workspace"
    @State private var rename = ""
    @State private var renaming = false
    @State private var review: HcWorkspaceModel.OperationReview?
    var body: some View {
        NavigationSplitView {
            List {
                Section("Workspaces") {
                    ForEach(model.document?.workspaces ?? [], id: \.id) { workspace in
                        Section(workspace.name) {
                            ForEach(workspace.tabs, id: \.id) { tab in
                                Button { do { try model.select(tab: tab.id) } catch { self.error = "Selection could not be saved." } } label: {
                                    HStack {
                                        Image(systemName: model.selectedTab?.id == tab.id ? "terminal.fill" : "terminal")
                                        Text(tab.name)
                                    }
                                }.buttonStyle(.plain)
                                .accessibilityIdentifier("hc-workspace.tab.\(tab.id)")
                                .contextMenu {
                                    Button("Rename") { try? model.select(tab: tab.id); rename = tab.name; renaming = true }
                                    Button("Close view (keep programs running)") { perform { try await model.closeTab(tab.id) } }
                                }
                            }
                            Menu("New terminal") {
                                Button("Shell") { launch(workspace.id, "Shell", []) }
                                Button("Claude Code") { launch(workspace.id, "Claude Code", ["claude"]) }
                                Button("Codex") { launch(workspace.id, "Codex", ["codex","--no-daemon"]) }
                                Button("Pi") { launch(workspace.id, "Pi", ["pi"]) }
                            }.disabled(!model.canEdit)
                        }
                    }
                }
                Section {
                    TextField("Workspace name", text: $newWorkspaceName)
                    Button("Create workspace") {
                        perform { _ = try await model.createWorkspace(name: newWorkspaceName) }
                    }.disabled(!model.canEdit)
                    .accessibilityIdentifier("hc-workspace.create-workspace")
                }
                if !model.recoveryRecords.filter({ !$0.complete }).isEmpty {
                    Section("Operations needing review") {
                        ForEach(model.recoveryRecords.filter { !$0.complete }, id: \.id) { operation in operationRow(operation) }
                    }
                }
                if model.recoveryRecords.contains(where: \.complete) {
                    DisclosureGroup("Completed operation history") {
                        ForEach(model.recoveryRecords.filter(\.complete), id: \.id) { operation in operationRow(operation) }
                    }.accessibilityIdentifier("hc.review.history")
                }
                Section("Core terminals") {
                    ForEach(model.terminals, id: \.address) { terminal in
                        VStack(alignment: .leading) {
                            Text(terminal.name ?? terminal.address)
                            Text([terminal.state, terminal.status?.state].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            if terminal.state == "live", let workspaceID = model.focus.workspaceID ?? model.document?.workspaces.first?.id {
                                Button("Show as new tab") { perform { try await model.showTerminal(terminal.address, workspaceID: workspaceID) } }
                                    .disabled(!model.canEdit)
                            }
                        }
                    }
                }
            }.navigationTitle("3rdr · hc")
        } detail: {
            Group {
                if model.state == .connecting || model.state == .idle { ProgressView("Connecting to hc…") }
                else if model.state != .connected {
                    ContentUnavailableView("hc connection unavailable", systemImage: "network.slash", description: Text("No fallback core was started. Reconnect after checking installation and host settings."))
                } else if let tab = model.selectedTab, let layout = tab.layout {
                    if let zoom = model.focus.zoomByTab[tab.id], let pane = layout.panes.first(where: { $0.id == zoom }) {
                        HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore).id(pane.id)
                    } else { layoutView(layout) }
                } else {
                    ContentUnavailableView("No terminal selected", systemImage: "terminal", description: Text("Create a workspace and open a terminal. Programs keep running when a view closes."))
                }
            }
            .navigationTitle(model.selectedTab?.name ?? "3rdr")
        }
        .frame(minWidth: 760, minHeight: 440)
        .sheet(item: $review) { HcOperationReviewSheet(model: model, review: $0) }
        .alert("Workspace operation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .alert("Rename tab", isPresented: $renaming) {
            TextField("Name", text: $rename)
            Button("Rename") { if let tab = model.selectedTab { perform { try await model.renameTab(tab.id, name: rename) } } }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if model.workspace?.failure != nil { Text("Workspace data is read-only until a fresh read succeeds.").font(.caption).padding().background(.regularMaterial) }
        }
    }
    private func operationRow(_ operation: CoreWorkspaceRecovery.Record) -> some View {
        VStack(alignment: .leading) {
            Text(operation.kind.rawValue.capitalized).font(.headline)
            Text(operation.terminal?.terminalID ?? "Program identity unconfirmed").font(.caption)
            Text("No automatic retry or termination.").font(.caption).foregroundStyle(.secondary)
            Button("Review tracking") { perform { review = try await model.prepareOperationReview(operation.id) } }
                .accessibilityIdentifier("hc.review.open.\(operation.id)")
                .disabled(model.operationBusy || model.operationReview != nil || model.state != .connected)
        }
    }
    private func launch(_ workspaceID: UUID, _ name: String, _ argv: [String]) {
        perform { try await model.launchTab(workspaceID: workspaceID, name: name, argv: argv) }
    }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await body() }
            catch { self.error = "Operation not confirmed. Refresh and review the saved operation before retrying; programs were not automatically restarted or terminated." }
        }
    }
    private func layoutView(_ layout: CoreWorkspaceDocument.Layout) -> AnyView {
        switch layout {
        case .leaf(let pane): return AnyView(HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore).id(pane.id))
        case .split(let axis, let ratio, let first, let second):
            return AnyView(GeometryReader { proxy in
                if axis == .horizontal {
                    HStack(spacing: 1) {
                        layoutView(first).frame(width: max(0, (proxy.size.width - 1) * ratio))
                        layoutView(second)
                    }
                } else {
                    VStack(spacing: 1) {
                        layoutView(first).frame(height: max(0, (proxy.size.height - 1) * ratio))
                        layoutView(second)
                    }
                }
            })
        }
    }
}
