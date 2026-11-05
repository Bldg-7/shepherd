import SwiftUI

nonisolated struct HcWorkspacePreviewVisible: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Existing workspace shell and board presentation, supplied by hc state.
/// No legacy transport/session identities are constructed by these views.
struct HcWorkspaceView: View {
    let model: HcWorkspaceModel?
    let machine: Machine?
    let machineStore: MachineStore
    let closeRequests: Int
    let onSettings: () -> Void
    let onLaunch: () -> Void
    let onSwitcher: () -> Void
    let onOrigins: () -> Void
    let onTracking: () -> Void
    let onReconnect: () -> Void
    let onRenameVisibility: (Bool) -> Void
    let unavailable: AnyView
    @AppStorage(AgentBoardView.showsTabsKey) private var showsTabs = false
    @State private var previewVisible = false
    @State private var presentations = HcPanePresentationStore()
    @State private var titleRename: HcTitleRenameSession?
    @State private var renameError: String?
    var body: some View {
        WorkspaceNavigationSplitView(detailMinimumWidth: previewVisible ? 641 : 320) {
            Group {
                if let model { HcAgentBoard(model: model, closeRequests: closeRequests, onTracking: onTracking, onRename: { _ = beginRename($0) }) }
                else { ContentUnavailableView("No Panes", systemImage: "terminal") }
            }
            .navigationTitle(machine?.displayName ?? "Shepherd")
            .toolbar {
                ToolbarItem {
                    Button(action: onSettings) { Label("Settings", systemImage: "gear") }
                        .help("Settings (⌘,)")
                        .contextMenu {
                            Button("Reconnect", action: onReconnect)
                            Button("Core origins…", action: onOrigins).accessibilityIdentifier("hc.origins.open")
                            Button("Operation tracking…", action: onTracking).accessibilityIdentifier("hc.tracking.open")
                        }
                }
                ToolbarItem {
                    Button(action: onLaunch) { Label("New Tab", systemImage: "plus") }
                        .disabled(model?.canEdit != true).help("New Tab (⌘N)")
                        .accessibilityIdentifier("hc.launch.open")
                }
                ToolbarItem {
                    Button(action: onSwitcher) { Label("Go to Agent or Pane…", systemImage: "magnifyingglass") }
                        .disabled(model?.state != .connected).help("Go to Agent or Pane… (⌘P)")
                }
            }
        } detail: {
            Group {
                if let model {
                    if model.state == .connecting || model.state == .idle { ProgressView("Connecting…") }
                    else if model.state != .connected { unavailable }
                    else if let tab = model.selectedTab, let layout = tab.layout {
                        if !showsTabs, let pane = layout.panes.first(where: { $0.id == model.focus.paneByTab[tab.id] }) ?? layout.panes.first {
                            HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore, presentations: presentations).id(pane.id)
                        } else if let zoom = model.focus.zoomByTab[tab.id], let pane = layout.panes.first(where: { $0.id == zoom }) {
                            HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore, presentations: presentations).id(pane.id)
                        } else { layoutView(layout, model: model) }
                    } else { ContentUnavailableView("No Pane Selected", systemImage: "terminal") }
                } else { unavailable }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .modifier(WorkspaceSidebarDetailLayout())
            .navigationTitle(detailTitle)
            .background {
                ZStack {
                    TitleDoubleClick(rename: { beginRename(currentSelection) })
                    TitleRenameToolbarRoom(active: titleRename != nil)
                }
            }
            .toolbar(removing: titleRename == nil ? nil : .title)
            .toolbar {
                if let session = titleRename {
                    ToolbarItem(id: TitleRenameToolbar.itemID, placement: .navigation) {
                        TitleRenameField(session: session, canSubmit: { !session.isTab || !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, onEnd: endRename)
                            .id(session.id)
                            .frame(minWidth: TitleRenameToolbar.minimumWidth, idealWidth: TitleRenameToolbar.idealWidth, maxWidth: TitleRenameToolbar.idealWidth)
                    }.sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .navigation)
                }
            }
        }
        .onPreferenceChange(HcWorkspacePreviewVisible.self) { previewVisible = $0 }
        .onChange(of: titleRename?.id) { onRenameVisibility(titleRename != nil) }
        .onChange(of: model?.workspace?.epoch) { titleRename = nil; presentations.retain(epoch: model?.workspace?.epoch, panes: model?.document?.panes ?? []) }
        .onChange(of: model?.document) { presentations.retain(epoch: model?.workspace?.epoch, panes: model?.document?.panes ?? []) }
        .alert("Rename unconfirmed", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") { renameError = nil }
        } message: { Text(renameError ?? "") }
    }
    private var currentSelection: HcBoardSelection? {
        guard let model, let tab = model.selectedTab else { return nil }
        return showsTabs ? .tab(tab.id) : model.focus.paneByTab[tab.id].map(HcBoardSelection.pane)
    }
    private func beginRename(_ target: HcBoardSelection?) -> Bool {
        guard titleRename == nil, let target, let model, model.canEdit,
              let snapshot = model.workspace?.snapshot, let document = snapshot.document else { return false }
        let text: String, prompt: String
        switch target {
        case .tab(let id):
            guard let tab = document.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else { return false }
            text = tab.name; prompt = tab.name
        case .pane(let id):
            guard let pane = document.panes.first(where: { $0.id == id }) else { return false }
            text = pane.title ?? ""; prompt = detailTitle
        }
        do {
            switch target {
            case .tab(let id): try model.select(tab: id)
            case .pane(let id): try model.select(pane: id)
            }
        } catch { return false }
        titleRename = HcTitleRenameSession(target: target, text: text, prompt: prompt,
            epoch: model.workspace!.epoch, version: snapshot.version)
        return true
    }
    private func endRename(_ session: HcTitleRenameSession, _ ending: TitleRenameEnding) {
        guard titleRename === session, session.end() else { return }
        _ = session.giveKeyboardBack()
        titleRename = nil
        if case .cancel = ending { return }
        let name = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isTab || !name.isEmpty, name != session.startText, let model else { return }
        Task {
            do {
                guard model.workspace?.epoch == session.epoch, model.workspace?.snapshot?.version == session.version,
                      model.canEdit else { throw HcWorkspaceModel.Failure.stale }
                switch session.target {
                case .tab(let id): try await model.renameTab(id, name: name)
                case .pane(let id): try await model.renamePane(id, name: name)
                }
            } catch { renameError = "The layout changed or the rename was not confirmed. Review it before trying again; nothing was automatically resent." }
        }
    }
    private var detailTitle: String {
        guard let model, let tab = model.selectedTab else { return "Shepherd" }
        if !showsTabs, let pane = tab.layout?.panes.first(where: { $0.id == model.focus.paneByTab[tab.id] }) {
            if let title = pane.title { return title }
            if let record = model.terminals.first(where: { $0.address == pane.terminal?.terminalID }), !record.title.isEmpty { return record.title }
            return tab.name
        }
        return tab.name
    }
    private func layoutView(_ layout: CoreWorkspaceDocument.Layout, model: HcWorkspaceModel) -> AnyView {
        switch layout {
        case .leaf(let pane):
            return AnyView(HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore, presentations: presentations).id(pane.id))
        case .split(let axis, let ratio, let first, let second):
            return AnyView(GeometryReader { proxy in
                if axis == .horizontal {
                    HStack(spacing: 1) {
                        layoutView(first, model: model).frame(width: max(0, (proxy.size.width - 1) * ratio))
                        layoutView(second, model: model)
                    }
                } else {
                    VStack(spacing: 1) {
                        layoutView(first, model: model).frame(height: max(0, (proxy.size.height - 1) * ratio))
                        layoutView(second, model: model)
                    }
                }
            })
        }
    }
}

private enum HcBoardSelection: Hashable { case pane(UUID), tab(UUID) }
@MainActor private final class HcTitleRenameSession: TitleRenameEditing {
    let id = UUID()
    let target: HcBoardSelection
    let startText: String
    let prompt: String
    let epoch: UUID
    let version: UInt64
    var text: String
    weak var keyboardBefore: AnyObject?
    private(set) var isEnded = false
    var isTab: Bool { if case .tab = target { true } else { false } }
    init(target: HcBoardSelection, text: String, prompt: String, epoch: UUID, version: UInt64) {
        self.target = target; self.startText = text; self.text = text
        self.prompt = prompt; self.epoch = epoch; self.version = version
    }
    func end() -> Bool { guard !isEnded else { return false }; isEnded = true; return true }
}
private struct HcAgentBoard: View {
    let model: HcWorkspaceModel
    let closeRequests: Int
    let onTracking: () -> Void
    let onRename: (HcBoardSelection) -> Void
    @AppStorage(AgentBoardView.showsTabsKey) private var showsTabs = false
    @State private var search = ""
    @State private var workspaces = Set<UUID>()
    @State private var closing: HcBoardSelection?
    @State private var error: String?
    private var activeWorkspaces: Set<UUID> { workspaces.intersection(Set((model.document?.workspaces ?? []).map(\.id))) }
    private var selection: Binding<HcBoardSelection?> {
        Binding(get: {
            guard let tab = model.selectedTab else { return nil }
            if showsTabs { return .tab(tab.id) }
            return model.focus.paneByTab[tab.id].map(HcBoardSelection.pane)
        }, set: { item in
            do {
                switch item {
                case .pane(let id): try model.select(pane: id)
                case .tab(let id): try model.select(tab: id)
                case nil: break
                }
            } catch { self.error = "Selection could not be saved." }
        })
    }
    var body: some View {
        List(selection: selection) {
            ForEach(model.document?.workspaces ?? [], id: \.id) { workspace in
                if activeWorkspaces.isEmpty || activeWorkspaces.contains(workspace.id) {
                    let tabs = workspace.tabs.filter { tab in
                        search.isEmpty || [workspace.name,tab.name] .contains { $0.localizedStandardContains(search) }
                            || (tab.layout?.panes ?? []).contains { matches($0, tab: tab) }
                    }
                    if !tabs.isEmpty {
                        WorkspaceBoardSectionLabel(title: workspace.name)
                        ForEach(tabs, id: \.id) { tab in
                            if showsTabs {
                                WorkspaceBoardRow(title: tab.name, state: tabState(tab)) { EmptyView() } caption: { EmptyView() }
                                    .tag(HcBoardSelection.tab(tab.id))
                                    .accessibilityIdentifier("hc-workspace.tab.\(tab.id)")
                                    .onBoardRowActivation { selection.wrappedValue = .tab(tab.id) }
                                    .boardSelectionEmphasized(selection.wrappedValue == .tab(tab.id))
                                    .contextMenu { tabActions(tab) }
                            } else {
                                ForEach((tab.layout?.panes ?? []).filter { search.isEmpty || workspace.name.localizedStandardContains(search) || matches($0, tab: tab) }, id: \.id) { pane in
                                    WorkspaceBoardRow(title: paneTitle(pane, tab: tab), state: state(pane)) { EmptyView() } caption: {
                                        let cwd = record(pane)?.cwd ?? ""
                                        AgentPaneCaption(cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent, agentName: nil)
                                    }
                                    .tag(HcBoardSelection.pane(pane.id))
                                    .accessibilityIdentifier("hc-workspace.pane.\(pane.id)")
                                    .onBoardRowActivation { selection.wrappedValue = .pane(pane.id) }
                                    .boardSelectionEmphasized(selection.wrappedValue == .pane(pane.id))
                                    .contextMenu {
                                        Button("Rename Pane…") { onRename(.pane(pane.id)) }
                                        Divider()
                                        Button("Close Pane", role: .destructive) { closing = .pane(pane.id) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .id(showsTabs)
        .safeAreaBar(edge: .top, spacing: 0) {
            WorkspaceBoardSearchBar(text: $search) { filterMenu }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { WorkspaceBoardTabModeBar(showsTabs: $showsTabs) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.recoveryRecords.contains(where: { !$0.complete }) {
                HStack { Text("An operation needs review.").font(.caption); Spacer(); Button("Review", action: onTracking) }.padding(10)
            }
        }
        .onChange(of: closeRequests) { if model.canEdit { closing = selection.wrappedValue } }
        .confirmationDialog(showsTabs ? "Close Tab?" : "Close Pane?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            if let closing {
                Button("Close view", role: .destructive) { close(closing) }.accessibilityIdentifier("hc.close.confirm")
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The view closes; its programs keep running.") }
        .alert("Workspace operation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private var filterMenu: some View {
        Menu {
            Button("All Workspaces") { workspaces = [] }.disabled(activeWorkspaces.isEmpty)
            Divider()
            ForEach(model.document?.workspaces ?? [], id: \.id) { workspace in
                Toggle(workspace.name, isOn: Binding(get: { workspaces.contains(workspace.id) }, set: {
                    if $0 { workspaces.insert(workspace.id) } else { workspaces.remove(workspace.id) }
                }))
            }
        } label: {
            Image(systemName: activeWorkspaces.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(activeWorkspaces.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Filter by Workspace").accessibilityLabel(Text("Filter by Workspace"))
    }
    private func record(_ pane: CoreWorkspaceDocument.Pane) -> HcTerminalRecord? {
        guard pane.terminal?.coreID == model.coreID else { return nil }
        return model.terminals.first { $0.address == pane.terminal?.terminalID }
    }
    private func paneTitle(_ pane: CoreWorkspaceDocument.Pane, tab: CoreWorkspaceDocument.Tab) -> String {
        if let title = pane.title { return title }
        if let record = record(pane), !record.title.isEmpty { return record.title }
        return tab.name
    }
    private func state(_ pane: CoreWorkspaceDocument.Pane) -> AgentState? {
        guard let record = record(pane), record.reported else { return nil }
        switch record.status?.state {
        case "needs_input": return .blocked
        case "working", "running", "active": return .working
        case "idle": return .idle
        case "done": return .done
        default: return nil
        }
    }
    private func tabState(_ tab: CoreWorkspaceDocument.Tab) -> AgentState? {
        let states = (tab.layout?.panes ?? []).compactMap(state)
        return [AgentState.blocked,.working,.idle,.done].first { states.contains($0) }
    }
    private func matches(_ pane: CoreWorkspaceDocument.Pane, tab: CoreWorkspaceDocument.Tab) -> Bool {
        let record = record(pane)
        return [pane.title ?? tab.name,record?.cwd ?? "",record?.name ?? "",tab.name].contains { $0.localizedStandardContains(search) }
    }
    @ViewBuilder private func tabActions(_ tab: CoreWorkspaceDocument.Tab) -> some View {
        Button("Rename Tab…") { onRename(.tab(tab.id)) }
        Divider()
        Button("Close Tab", role: .destructive) { closing = .tab(tab.id) }
    }
    private func close(_ target: HcBoardSelection) {
        perform {
            switch target {
            case .pane(let id):
                if let tab = model.document?.workspaces.flatMap(\.tabs).first(where: { $0.layout?.panes.contains(where: { $0.id == id }) == true }),
                   tab.layout?.panes.count == 1 { try await model.closeTab(tab.id) }
                else { try await model.closePane(id) }
            case .tab(let id): try await model.closeTab(id)
            }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { self.error = "Operation unconfirmed. Review the saved outcome before retrying; nothing is automatically resent." } }
    }
}
