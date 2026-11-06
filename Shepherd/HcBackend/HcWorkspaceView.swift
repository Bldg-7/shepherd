import SwiftUI

/// Existing workspace shell and board presentation, supplied by hc state.
/// No legacy transport/session identities are constructed by these views.
struct HcWorkspaceView: View {
    let model: HcWorkspaceModel?
    let machine: Machine?
    let machineStore: MachineStore
    let isCurrentModel: @MainActor (HcWorkspaceModel) -> Bool
    let closeRequests: Int
    let onSettings: () -> Void
    let onLaunch: () -> Void
    let onSwitcher: () -> Void
    let onOrigins: () -> Void
    let onTracking: () -> Void
    let onReconnect: () -> Void
    let onRenameVisibility: (Bool) -> Void
    let presentation: HcWorkspacePresentation
    let unavailable: AnyView
    @AppStorage(AgentBoardView.showsTabsKey) private var showsTabs = false
    @State private var presentations = HcPanePresentationStore()
    @State private var titleRename: HcTitleRenameSession?
    @State private var renameError: String?
    private var currentConnection: Bool {
        guard let machine, let model, isCurrentModel(model) else { return false }
        return machineStore.activeMachineID == machine.id && machineStore.isCurrentConnection(machine)
    }
    var body: some View {
        WorkspaceNavigationSplitView(detailMinimumWidth: activePreview?.preview == nil ? 320 : 641) {
            Group {
                if let model { HcAgentBoard(model: model, presentation: presentation, closeRequests: closeRequests, onTracking: onTracking, onRetry: onReconnect,
                        itemProvider: { item in
                            switch item {
                            case .pane(let id): return HcWorkspaceItemDrag.provider(kind:.pane,id:id,model:model,machine:machine,store:machineStore,isCurrentModel:isCurrentModel)
                            case .tab(let id): return HcWorkspaceItemDrag.provider(kind:.tab,id:id,model:model,machine:machine,store:machineStore,isCurrentModel:isCurrentModel)
                            }
                        }, scopeIsCurrent: { currentConnection }, onRename: { _ = beginRename($0) }, onActivate: activateSelection) }
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
            let shown = activePreview
            WorkspaceDetailSplitView(showsPanel: shown?.preview != nil, panelMinimum: 320, panelIdeal: 560,
                                     panelCoversTerminal: shown?.expanded == true, allowsKeyboardRestore: { !presentation.keyboardSuppressed && !presentation.textFieldOwnsKeyboard }) {
            Group {
                if let model {
                    if model.state == .connecting || model.state == .idle { ProgressView("Connecting…") }
                    else if model.state != .connected { unavailable }
                    else if presentation.hasSelection, let tab = model.selectedTab, let layout = tab.layout {
                        if !showsTabs, let pane = layout.panes.first(where: { $0.id == model.focus.paneByTab[tab.id] }) ?? layout.panes.first {
                            HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore, presentations: presentations, keyboardIntent: presentation, isCurrentScope: { currentConnection }).id(pane.id)
                        } else if let zoom = model.focus.zoomByTab[tab.id], let pane = layout.panes.first(where: { $0.id == zoom }) {
                            HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore, presentations: presentations, keyboardIntent: presentation, isCurrentScope: { currentConnection }).id(pane.id)
                        } else { layoutView(layout, model: model) }
                    } else { ContentUnavailableView("No Pane Selected", systemImage: "terminal") }
                } else { unavailable }
            }
            .accessibilityHidden(shown?.expanded == true)
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .modifier(WorkspaceSidebarDetailLayout())
            } panel: {
                if let shown, let request = shown.preview {
                    FilePreviewPanel(request: request, model: shown.previewModel, machineStore: machineStore,
                        onClose: { shown.preview = nil; shown.expanded = false }, onFileLink: { shown.preview = $0 })
                        .previewExpansion(isExpanded: shown.expanded, onToggle: { shown.expanded.toggle() })
                        .frame(minWidth: 320, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(WorkspaceSidebarDetailLayout())
                }
            }
            .navigationTitle(detailTitle)
            .background {
                ZStack {
                    TitleDoubleClick(rename: { beginRename(currentSelection) })
                    TitleRenameToolbarRoom(active: titleRename != nil)
                    HcTextInputOwnership(presentation:presentation)
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
        .onChange(of: activePreview?.expanded, initial: true) { presentation.previewCoversTerminal = activePreview?.expanded == true }
        .onChange(of: titleRename?.id) { onRenameVisibility(titleRename != nil) }
        .onChange(of: model?.workspace?.epoch, initial: true) {
            titleRename = nil
            presentation.scopeChanged(model?.workspace?.epoch, focus: selectionStamp)
            presentations.retain(epoch: model?.workspace?.epoch, panes: model?.document?.panes ?? [])
        }
        .onChange(of: selectionStamp) {
            presentations.collapsePreviews(epoch: model?.workspace?.epoch)
            presentation.followFocus(selectionStamp)
        }
        .onChange(of: showsTabs) {
            if let titleRename { endRename(titleRename, .left) }
            presentation.clearSelection(focus: selectionStamp)
        }
        .environment(\.hcPaneKeyboardRequest, presentation.keyboardRequest)
        .onChange(of: model?.document) { presentations.retain(epoch: model?.workspace?.epoch, panes: model?.document?.panes ?? []) }
        .alert("Rename unconfirmed", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") { renameError = nil }.accessibilityIdentifier("hc.rename.unconfirmed.ok")
        } message: { Text(renameError ?? "") }
    }
    private var activePreview: HcPanePresentation? {
        guard presentation.hasSelection, let model, let tab = model.selectedTab,
              let pane = tab.layout?.panes.first(where: { $0.id == model.focus.paneByTab[tab.id] }) ?? tab.layout?.panes.first,
              pane.terminal?.coreID == model.coreID else { return nil }
        return presentations.entry(epoch: model.workspace?.epoch, pane: pane)
    }
    private var selectionStamp: HcSelectionStamp? {
        guard let model, let tab = model.selectedTab else { return nil }
        return .init(tab: tab.id, pane: model.focus.paneByTab[tab.id])
    }
    private func activateSelection() {
        guard let model, model.state == .connected, let stamp = selectionStamp else { return }
        if let pane = stamp.pane { presentations.revealTerminal(epoch: model.workspace?.epoch, pane: pane) }
        presentation.select(stamp, requestKeyboard: true)
    }
    private var currentSelection: HcBoardSelection? {
        guard presentation.hasSelection, let model, let tab = model.selectedTab else { return nil }
        return showsTabs ? .tab(tab.id) : model.focus.paneByTab[tab.id].map(HcBoardSelection.pane)
    }
    private func beginRename(_ target: HcBoardSelection?) -> Bool {
        guard currentConnection, titleRename == nil, let target, let model, model.canEdit,
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
                guard currentConnection, model.workspace?.epoch == session.epoch, model.workspace?.snapshot?.version == session.version,
                      model.canEdit else { throw HcWorkspaceModel.Failure.stale }
                switch session.target {
                case .tab(let id): try await model.renameTab(id, name: name)
                case .pane(let id): try await model.renamePane(id, name: name)
                }
            } catch { renameError = "The layout changed or the rename was not confirmed. Review it before trying again; nothing was automatically resent." }
        }
    }
    private var detailTitle: String {
        guard presentation.hasSelection, let model, let tab = model.selectedTab else { return "Shepherd" }
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
            return AnyView(HcTerminalPane(model: model, pane: pane, machine: machine, machineStore: machineStore, presentations: presentations, keyboardIntent: presentation, isCurrentScope: { currentConnection }).id(pane.id))
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
private struct HcCloseRequest {
    let target: HcBoardSelection
    let stamp: HcWorkspaceMutationStamp
    var title: String { if case .tab = target { return "Close Tab?" }; return "Close Pane?" }
}
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
    let presentation: HcWorkspacePresentation
    let closeRequests: Int
    let onTracking: () -> Void
    let onRetry: () -> Void
    let itemProvider: (HcBoardSelection) -> NSItemProvider?
    let scopeIsCurrent: @MainActor () -> Bool
    let onRename: (HcBoardSelection) -> Void
    let onActivate: () -> Void
    @AppStorage(AgentBoardView.showsTabsKey) private var showsTabs = false
    @State private var search = ""
    @State private var workspaces = Set<UUID>()
    @State private var closing: HcCloseRequest?
    @State private var error: String?
    private var activeWorkspaces: Set<UUID> { workspaces.intersection(Set((model.document?.workspaces ?? []).map(\.id))) }
    private var selection: Binding<HcBoardSelection?> {
        Binding(get: {
            guard scopeIsCurrent(), presentation.hasSelection, let tab = model.selectedTab else { return nil }
            if showsTabs { return .tab(tab.id) }
            return model.focus.paneByTab[tab.id].map(HcBoardSelection.pane)
        }, set: { item in
            guard scopeIsCurrent(), model.state == .connected, item != selection.wrappedValue else { return }
            do {
                switch item {
                case .pane(let id): try model.select(pane: id)
                case .tab(let id): try model.select(tab: id)
                case nil: return
                }
                if let tab = model.selectedTab { presentation.select(.init(tab: tab.id, pane: model.focus.paneByTab[tab.id]), requestKeyboard: false) }
            } catch { self.error = "Selection could not be saved." }
        })
    }
    var body: some View {
        List(selection: selection) {
            ForEach(model.document?.workspaces ?? [], id: \.id) { workspace in
                if activeWorkspaces.isEmpty || activeWorkspaces.contains(workspace.id) {
                    let tabs = visibleTabs(workspace)
                    if !tabs.isEmpty {
                        WorkspaceBoardSectionLabel(title: workspace.name)
                        ForEach(tabs, id: \.id) { tab in
                            if showsTabs {
                                WorkspaceBoardRow(title: tab.name, state: tabState(tab)) { EmptyView() } caption: { EmptyView() }
                                    .itemProvider { itemProvider(.tab(tab.id)) }
                                    .tag(HcBoardSelection.tab(tab.id))
                                    .accessibilityIdentifier("hc-workspace.tab.\(tab.id)")
                                    .onBoardRowActivation { selection.wrappedValue = .tab(tab.id); onActivate() }
                                    .boardSelectionEmphasized(selection.wrappedValue == .tab(tab.id))
                                    .contextMenu { tabActions(tab) }
                            } else {
                                ForEach(visiblePanes(tab, workspace: workspace.name), id: \.id) { pane in
                                    WorkspaceBoardRow(title: paneTitle(pane, tab: tab), state: state(pane)) { EmptyView() } caption: {
                                        let cwd = record(pane)?.cwd ?? ""
                                        AgentPaneCaption(cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent, agentName: nil)
                                    }
                                    .itemProvider { itemProvider(.pane(pane.id)) }
                                    .tag(HcBoardSelection.pane(pane.id))
                                    .accessibilityIdentifier("hc-workspace.pane.\(pane.id)")
                                    .onBoardRowActivation { selection.wrappedValue = .pane(pane.id); onActivate() }
                                    .boardSelectionEmphasized(selection.wrappedValue == .pane(pane.id))
                                    .contextMenu {
                                        Button("Rename Pane…") { onRename(.pane(pane.id)) }
                                        Button("New shell to right") { split(pane, axis: .horizontal) }
                                        Button("New shell below") { split(pane, axis: .vertical) }
                                        Button(model.focus.zoomByTab[tab.id] == pane.id ? "Unzoom Pane" : "Zoom Pane") {
                                            guard scopeIsCurrent(), model.state == .connected else { return }
                                            do { try model.zoom(pane: model.focus.zoomByTab[tab.id] == pane.id ? nil : pane.id) }
                                            catch { self.error = "Selection could not be saved." }
                                        }
                                        Divider()
                                        Button("Close Pane", role: .destructive) { prepareClose(.pane(pane.id)) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .id(showsTabs)
        .overlay {
            if totalRows == 0 {
                if model.state == .idle || model.state == .connecting { ProgressView("Loading panes…") }
                else if model.state == .failed {
                    ContentUnavailableView {
                        Label("Connection Failed", systemImage: "exclamationmark.triangle")
                    } description: { Text("Check the connection and retry. Existing programs are untouched.") }
                    actions: { Button("Retry", action: onRetry) }
                } else {
                    ContentUnavailableView("No Panes", systemImage: "terminal", description: Text("The panes open on this machine appear here."))
                        .accessibilityIdentifier("workspace.board.empty")
                }
            } else if visibleRowCount == 0 {
                ContentUnavailableView.search(text: search).accessibilityIdentifier("workspace.board.no-matches")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.state == .failed && totalRows > 0 {
                HStack {
                    Text("Connection Failed").font(.caption).accessibilityIdentifier("workspace.board.connection-failure")
                    Spacer()
                    Button("Retry", action: onRetry).accessibilityIdentifier("workspace.board.retry")
                }.padding(10)
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            WorkspaceBoardSearchBar(text: $search) { filterMenu }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { WorkspaceBoardTabModeBar(showsTabs: $showsTabs) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.recoveryRecords.contains(where: { !$0.complete }) {
                HStack { Text("An operation needs review.").font(.caption); Spacer(); Button("Review", action: onTracking) }.padding(10)
            }
        }
        .onChange(of: closeRequests) { if let target = selection.wrappedValue { prepareClose(target) } }
        .onChange(of: model.workspace?.epoch) { closing = nil }
        .onChange(of: model.state) { if model.state != .connected { closing = nil } }
        .confirmationDialog(closing?.title ?? (showsTabs ? "Close Tab?" : "Close Pane?"), isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            if let closing {
                Button("Close view", role: .destructive) { close(closing) }.accessibilityIdentifier("hc.close.confirm")
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The view closes; its programs keep running.") }
        .alert("Workspace operation", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }.accessibilityIdentifier("hc.workspace.error.ok")
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
    private var totalRows: Int {
        (model.document?.workspaces ?? []).reduce(0) { sum, workspace in
            sum + (showsTabs ? workspace.tabs.count : workspace.tabs.reduce(0) { $0 + ($1.layout?.panes.count ?? 0) })
        }
    }
    private var visibleRowCount: Int {
        (model.document?.workspaces ?? []).filter { activeWorkspaces.isEmpty || activeWorkspaces.contains($0.id) }.reduce(0) { sum, workspace in
            let tabs = visibleTabs(workspace)
            return sum + (showsTabs ? tabs.count : tabs.reduce(0) { $0 + visiblePanes($1, workspace: workspace.name).count })
        }
    }
    private func visibleTabs(_ workspace: CoreWorkspaceDocument.Workspace) -> [CoreWorkspaceDocument.Tab] {
        workspace.tabs.filter { tab in
            let panes = visiblePanes(tab,workspace:workspace.name)
            return showsTabs ? (HcBoardSearch.matches(search,fields:[workspace.name,tab.name]) || !panes.isEmpty) : !panes.isEmpty
        }
    }
    private func visiblePanes(_ tab: CoreWorkspaceDocument.Tab, workspace: String) -> [CoreWorkspaceDocument.Pane] {
        (tab.layout?.panes ?? []).filter { pane in
            let terminal = record(pane)
            return HcBoardSearch.matches(search,fields:[workspace,tab.name,paneTitle(pane,tab:tab),terminal?.cwd ?? "",terminal?.name ?? ""])
        }
    }
    @ViewBuilder private func tabActions(_ tab: CoreWorkspaceDocument.Tab) -> some View {
        Button("Rename Tab…") { onRename(.tab(tab.id)) }
        Divider()
        Button("Close Tab", role: .destructive) { prepareClose(.tab(tab.id)) }
    }
    private func split(_ pane: CoreWorkspaceDocument.Pane, axis: CoreWorkspaceDocument.Axis) {
        guard let stamp = mutationStamp(), model.document?.pane(pane.id)?.terminal == pane.terminal else { return }
        let cwd = record(pane)?.cwd
        perform {
            guard matches(stamp) else { throw HcWorkspaceModel.Failure.stale }
            try await model.launchSplit(paneID: pane.id, axis: axis, argv: [], cwd: cwd)
        }
    }
    private func mutationStamp() -> HcWorkspaceMutationStamp? {
        guard scopeIsCurrent(), model.canEdit, let core = model.coreID,
              let epoch = model.workspace?.epoch, let version = model.workspace?.snapshot?.version else { return nil }
        return .init(epoch:epoch,coreID:core,version:version)
    }
    private func matches(_ stamp: HcWorkspaceMutationStamp) -> Bool {
        scopeIsCurrent() && model.canEdit && stamp.matches(epoch:model.workspace?.epoch,coreID:model.coreID,version:model.workspace?.snapshot?.version)
    }
    private func prepareClose(_ target: HcBoardSelection) {
        guard let stamp = mutationStamp() else { return }
        closing = .init(target:target,stamp:stamp)
    }
    private func close(_ request: HcCloseRequest) {
        let target = request.target, intent = presentation.selectionIntent
        let wasSelected = selection.wrappedValue == target
        perform {
            guard matches(request.stamp) else { throw HcWorkspaceModel.Failure.stale }
            switch target {
            case .pane(let id):
                if let tab = model.document?.workspaces.flatMap(\.tabs).first(where: { $0.layout?.panes.contains(where: { $0.id == id }) == true }),
                   tab.layout?.panes.count == 1 { try await model.closeTab(tab.id) }
                else { try await model.closePane(id) }
            case .tab(let id): try await model.closeTab(id)
            }
            let focus = model.selectedTab.map { HcSelectionStamp(tab: $0.id, pane: model.focus.paneByTab[$0.id]) }
            guard scopeIsCurrent(), model.workspace?.epoch == request.stamp.epoch else { return }
            if wasSelected { presentation.clearSelection(ifUnchanged:intent,focus:focus) }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do {
            guard scopeIsCurrent() else { throw HcWorkspaceModel.Failure.stale }
            try await action()
        } catch { self.error = "Operation unconfirmed. Review the saved outcome before retrying; nothing is automatically resent." } }
    }
}
