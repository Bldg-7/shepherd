import SwiftUI

/// App root: sidebar is the active Machine's panes and the agents in them,
/// or its tabs; detail is the selected pane's terminal, or every terminal of
/// the selected tab laid out as herdr has them. Machine management lives in
/// Settings, a sheet over this window opened from the gear over the sidebar
/// (on macOS also from the app menu and with ⌘,).
struct ContentView: View {
    let machineStore: MachineStore

    /// A selected pane or tab together with the machine it was selected on.
    /// The two are stored as one value because a pane or tab id means
    /// nothing on its own — ids like "w1:p1" exist on every machine — and the
    /// terminal attaches to whatever pane it is given, taking it over.
    /// Everything below reads the selection through `selection(on:)`, which
    /// answers "nothing selected" for any machine other than the one stamped
    /// here, so the detail column can never pair one machine with another
    /// machine's pane, not even for the moment it takes the sidebar to catch
    /// up with a machine switch.
    private struct MachineSelection {
        let connection: Machine.ConnectionIdentity
        let item: BoardItem
    }

    /// What makes one terminal view a different one from another.
    /// `AgentTerminalView` builds its session once, when the view is created,
    /// so a view that outlived a change of pane or machine would stay attached
    /// to the old pane while showing the new one's title. Tying the view's
    /// identity to this value gives every (machine, pane or tab) its own view,
    /// and tears the previous one down along with its sessions.
    private nonisolated struct TerminalIdentity: Hashable {
        let connection: Machine.ConnectionIdentity
        /// `BoardItem.id`: the pane or tab, qualified by its herdr machine.
        let itemID: String
    }

    @State private var selection: MachineSelection?
    /// The board's tab setting (see `AgentBoardView.showsTabsKey`).
    @AppStorage(AgentBoardView.showsTabsKey) private var showsTabs = false
    /// Whether the detail column is on screen. In compact width the split
    /// view collapses into a stack, and the detail column is only on screen
    /// while it is pushed. A selection is made before that push, though, and
    /// once the column has been popped a view placed into it at that moment
    /// is told it appeared and then — the column not being shown yet — that
    /// it disappeared again, with no second appearance when the push does
    /// happen. A terminal can't take that: it attaches when it appears and
    /// ends its session for good when it disappears. So the terminal is only
    /// created while the column is really there, which gives it exactly one
    /// appearance and one disappearance per visit.
    @State private var isDetailColumnVisible = false
    @State private var isShowingSettings = false
    /// How the new tab launcher came up, or nil while it isn't up.
    @State private var launcherStart: LauncherStart?
    /// What the new tab launcher offers, as the board last reported it.
    @State private var launchTargets: [LaunchTarget] = []
    /// See `AgentBoardView.justCreatedID`.
    @State private var justCreatedID: String?
    /// Goes up to have the board fetch everything again at once.
    @State private var boardRefreshRequests = 0
    /// Goes up to have the board close the selection (see
    /// `AgentBoardView.closeRequests`).
    @State private var closeRequests = 0
    @State private var filePreview: FilePreviewRequest?
    @State private var webLinkFailure: TerminalWebLinkError?
    @State private var isShowingPaneSwitcher = false
    @State private var paneDestinations: [PaneDestination] = []
    @State private var switcherConnection: Machine.ConnectionIdentity?
    @State private var pendingPaneDestination: PaneDestination?
    @State private var terminalPaneFocus: TerminalPaneFocus?
    /// The name being typed into the window's title, in place of the title,
    /// if one is (see `TitleRenameField`). A row's Rename item starts it on
    /// the board; it is ended here.
    @State private var titleRename: TitleRenameSession?
    /// The last name typed into the title, which the title shows until
    /// herdr reports it (see `TitleRenameCommit`). The board sends it.
    @State private var renameCommit: TitleRenameCommit?
    #if os(macOS)
    @State private var passwordManagerWindowID = UUID()
    /// Whether the window shows the browser column beside the terminal.
    @SceneStorage("ContentView.showsBrowser") private var showsBrowser = false
    @State private var showsFilePreview = false
    @State private var expandsFilePreview = false
    /// For each tab shown in this window (by `TerminalIdentity`), the pane in
    /// it the browser column follows: the one last given the keyboard.
    @State private var activatedPanes: [TerminalIdentity: String] = [:]
    /// Whether the window is key, which it has to be for the selection to
    /// count as looked at (see `viewedPanesNow`).
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    #endif

    private func workspace(on machine: Machine?) -> some View {
        WorkspaceNavigationSplitView {
            Group {
                if let machine {
                    // One board per machine: its pane list, connection and
                    // error belong to that machine and must not carry over
                    // to the next one.
                    AgentBoardView(
                        machine: machine,
                        machineStore: machineStore,
                        selection: selection(on: machine),
                        justCreatedID: $justCreatedID,
                        launchTargets: $launchTargets,
                        refreshRequests: boardRefreshRequests,
                        closeRequests: closeRequests,
                        renaming: Binding(get: { titleRename }, set: { beginTitleRename($0, on: machine) }),
                        renameCommit: $renameCommit,
                        onNavigationDestinations: { destinations in
                            guard machineStore.isCurrentConnection(machine),
                                  machineStore.activeMachine?.connectionIdentity == machine.connectionIdentity else { return }
                            paneDestinations = destinations
                        }
                    )
                        .id(machine.connectionIdentity)
                } else {
                    noActiveMachinePlaceholder
                }
            }
            // Left to itself the sidebar comes up too narrow for a board
            // row, let alone for the failure banner and its Retry button.
            // Capped as well: with no maximum, its divider can be dragged
            // across the whole window, and a row has nothing to fill that
            // width with but the gap between its title and its status.
            .navigationSplitViewColumnWidth(min: WorkspaceSidebarMetrics.minimum, ideal: WorkspaceSidebarMetrics.preferred, max: WorkspaceSidebarMetrics.maximum)
            // Attached to the sidebar column's content, not to the split
            // view: on iOS a toolbar only renders in the navigation bar of the
            // column whose content declares it, and on macOS this puts the
            // button over the sidebar, next to the machine it configures. On
            // the Group, so that it is there with or without an active
            // machine — with none, this button is how the first machine gets
            // added.
            .toolbar {
                ToolbarItem {
                    settingsButton
                        // ⌘, works too, but nothing in the window says so.
                        .help("Settings (⌘,)")
                }
                ToolbarItem {
                    newTabButton
                        .help("New Tab (⌘N)")
                }
                ToolbarItem { paneSwitcherButton }
            }
        } detail: {
            // The browser column sits beside the terminal, outside of the
            // terminal's identity: the terminal view is made anew for each
            // pane or tab, the browser column only switches which pane's
            // browser it shows (plan item A1).
            WorkspaceDetailSplitView(
                showsPanel: (showsFilePreview && filePreview != nil) || (!showsFilePreview && ShepherdBrowserFeature.shared.isEnabled && showsBrowser),
                panelMinimum: showsFilePreview ? 320 : 360,
                panelIdeal: showsFilePreview ? 560 : 640,
                panelCoversTerminal: showsFilePreview && expandsFilePreview
            ) {
                terminalColumn(on: machine)
                    .accessibilityHidden(showsFilePreview && expandsFilePreview)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(WorkspaceSidebarDetailLayout())
            } panel: {
                if showsFilePreview, let filePreview {
                    previewPanel(filePreview)
                        .frame(minWidth: 320, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(WorkspaceSidebarDetailLayout())
                } else if ShepherdBrowserFeature.shared.isEnabled && showsBrowser {
                    BrowserColumn(target: browserTarget(on: machine))
                        .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(WorkspaceSidebarDetailLayout())
                }
            }
            // Native hosting isolates sidebar insets; project the selected
            // terminal title here so it still reaches the window's toolbar.
            // (The terminal views set it too, and theirs is the one taken:
            // see `AgentTerminalView.title`.)
            .navigationTitle(detailNavigationTitle(on: machine))
            // While a name is typed into the title, the field stands in its
            // place.
            .toolbar(removing: titleRenameShown(on: machine) == nil ? nil : .title)
            .toolbar {
                if let session = titleRenameShown(on: machine) {
                    ToolbarItem(placement: .navigation) {
                        TitleRenameField(
                            session: session,
                            canSubmit: { TitleRename.canSubmit($0, for: session.item) },
                            onEnd: endTitleRename
                        )
                        .id(session.id)
                        .frame(minWidth: 160, idealWidth: 280, maxWidth: 420)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                if ShepherdBrowserFeature.shared.isEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if !showsBrowser { showsFilePreview = false; expandsFilePreview = false }
                        showsBrowser.toggle()
                    } label: {
                        Label(showsBrowser ? "Hide Browser" : "Show Browser", systemImage: "globe")
                    }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .help(showsBrowser ? "Hide Browser (⌥⌘B)" : "Show Browser (⌥⌘B)")
                }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if !showsFilePreview { showsBrowser = false }
                        showsFilePreview.toggle()
                        if !showsFilePreview { expandsFilePreview = false }
                    } label: {
                        Label(showsFilePreview ? "Hide Preview" : "Show Preview", systemImage: "doc.text")
                    }
                    .disabled(filePreview == nil)
                    .help("File Preview")
                }
            }
        }
    }

    private func workspaceWithLifecycle(on machine: Machine?) -> some View {
        workspace(on: machine)
        .onChange(of: machine?.connectionIdentity) { _, connection in
            // A reused machine UUID is not the same endpoint or credential.
            // Never attach an old pane ID to the newly edited connection.
            if selection?.connection != connection { selection = nil }
            launchTargets = []
            paneDestinations = []
            pendingPaneDestination = nil
            terminalPaneFocus = nil
            isShowingPaneSwitcher = false
            justCreatedID = nil
            launcherStart = nil
            filePreview = nil
            // A name typed for the other machine's board isn't sent, and the
            // keyboard is left alone: a pane ID means nothing on its own.
            if let titleRename {
                _ = titleRename.end()
                self.titleRename = nil
            }
            renameCommit = nil
            #if os(macOS)
            showsFilePreview = false
            activatedPanes = [:]
            #endif
        }
        .onChange(of: filePreview.map(previewBelongsToSelection) ?? true) { _, valid in
            if !valid {
                filePreview = nil
                #if os(macOS)
                showsFilePreview = false
                #endif
            }
        }
        .onChange(of: selection?.item.id) { _, id in
            // The title isn't the renamed item's any more: as if the
            // keyboard had gone elsewhere — which a click on another row
            // has already done.
            if let titleRename, titleRename.item.id != id {
                endTitleRename(titleRename, .left)
            }
            filePreview = nil
            #if os(macOS)
            showsFilePreview = false
            #endif
        }
        #if os(macOS)
        .onChange(of: showsFilePreview) { _, visible in
            if !visible { expandsFilePreview = false }
        }
        #endif
        .environment(\.terminalPaneFocus, terminalPaneFocus)
        .onChange(of: isShowingPaneSwitcher) { _, visible in
            if visible {
                switcherConnection = machine?.connectionIdentity
                pendingPaneDestination = nil
                launcherStart = nil
            }
        }
        .sheet(isPresented: $isShowingPaneSwitcher, onDismiss: navigateToPendingPane) {
            PaneSwitcher(destinations: paneDestinations, onSelect: { destination in
                pendingPaneDestination = destination
                isShowingPaneSwitcher = false
            }, onClose: { pendingPaneDestination = nil; isShowingPaneSwitcher = false })
        }
        .onChange(of: showsTabs) {
            // The board now lists the other kind of row, and what was
            // selected is no longer on it.
            selection = nil
        }
    }

    var body: some View {
        let machine = machineStore.activeMachine
        workspaceWithLifecycle(on: machine)
        // Over the whole window, sidebar and detail alike, as Spotlight is
        // over the screen.
        .overlay {
            if let launcherStart, let machine {
                NewTabLauncher(
                    targets: launchTargets,
                    preset: launcherPreset(launcherStart, on: machine),
                    allowsBrowserAgents: allowsBrowserAgents(on: machine),
                    create: { request in try await openTab(request, on: machine) },
                    onClose: { self.launcherStart = nil }
                )
            }
        }
        .alert("Could Not Open Link", isPresented: Binding<Bool>(
            get: { webLinkFailure != nil }, set: { if !$0 { webLinkFailure = nil } }
        )) {
            Button("OK") { webLinkFailure = nil }
        } message: {
            Text(webLinkFailure?.localizedDescription ?? "")
        }
        .sheet(isPresented: $isShowingSettings) {
            MachinesSettingsView(machineStore: machineStore, passwordManagerWindowID: passwordManagerWindowID)
        }
        #if os(macOS)
        .onAppear {
            // App-owned startup eligibility is consumed once across all windows.
            if ShepherdBrowserFeature.shared.passwordManagers.resumeAtStartup(
                owner: passwordManagerWindowID, browserEnabled: ShepherdBrowserFeature.shared.isEnabled) {
                isShowingSettings = true
            }
            // How a click on a notification brings the window back once it
            // has been closed.
            NotificationCoordinator.shared.openWindow = openWindow
        }
        .onDisappear {
            ShepherdBrowserFeature.shared.passwordManagers.endVisit(owner: passwordManagerWindowID)
            // With the window closed, nothing is in front of the person.
            NotificationCoordinator.shared.setViewedPanes([])
        }
        .onChange(of: viewedPanesNow, initial: true) { _, panes in
            NotificationCoordinator.shared.setViewedPanes(panes)
        }
        // A clicked notification's pane, once there is a request for one,
        // and again whenever the board lists something new until it is
        // there.
        .onChange(of: NotificationCoordinator.shared.navigationRequest, initial: true) {
            navigateToNotifiedPane()
        }
        .onChange(of: paneDestinations) {
            navigateToNotifiedPane()
        }
        // A Machine that is removed, or now uses another herdr session,
        // takes its panes' browsers with it.
        .onChange(of: machineStore.allMachines, initial: true) { _, machines in
            AgentLaunchService.shared.update(machines: machines)
            #if DEBUG
            let paths = OwnedOperatorFixture.configuration.map { [$0.machine.id: $0.socket] } ?? [:]
            MachineBrowserService.shared.update(machines: machines, localSocketPaths: paths)
            #else
            MachineBrowserService.shared.update(machines: machines)
            #endif
        }
        // What the app menu's Settings… item (and ⌘,) opens Settings
        // through.
        .focusedSceneValue(\.isShowingSettings, $isShowingSettings)
        // And the File menu's New Tab… (⌘N) and New Tab in Current
        // Workspace… (⌘T), the launcher.
        .focusedSceneValue(\.launcherStart, machine == nil || isShowingPaneSwitcher || isShowingSettings ? nil : $launcherStart)
        .focusedSceneValue(\.isShowingPaneSwitcher, machine == nil || isShowingSettings || launcherStart != nil ? nil : $isShowingPaneSwitcher)
        // And its Close Tab or Close Pane (⌘W), the board's close.
        .focusedSceneValue(\.closeCommand, CloseCommand(target: closeCommandTarget(on: machine), requests: $closeRequests))
        #endif
    }

    #if os(macOS)
    private func detailNavigationTitle(on machine: Machine?) -> String {
        guard let machine, let item = selection(on: machine).wrappedValue else { return "" }
        return renameCommit?.title(for: item) ?? item.title
    }

    /// The rename to show in the window's title on `machine`: one for what
    /// is selected there, if there is one.
    private func titleRenameShown(on machine: Machine?) -> TitleRenameSession? {
        guard let machine, let titleRename,
              selection(on: machine).wrappedValue?.id == titleRename.item.id else { return nil }
        return titleRename
    }

    /// Takes a rename a row's Rename item has started on the board. The
    /// board selects the item first; a rename of anything that didn't get
    /// selected is let go of at once. One already being typed ends first,
    /// as if the keyboard had gone elsewhere. No terminal is to take the
    /// keyboard as it comes up while the field is to have it: a stale
    /// request for one is dropped here, and a tab is told so (see
    /// `TabTerminalView.takesKeyboardWhenShown`).
    private func beginTitleRename(_ session: TitleRenameSession?, on machine: Machine) {
        if let titleRename, titleRename !== session {
            endTitleRename(titleRename, .left)
        }
        guard let session else { return }
        guard selection(on: machine).wrappedValue?.id == session.item.id else {
            _ = session.end()
            return
        }
        terminalPaneFocus = nil
        titleRename = session
    }

    /// Ends a rename typed into the window's title. Of the ways one can
    /// end, the first counts; the rest are let go of. Return, and the
    /// keyboard going elsewhere, send the name if there is one to send
    /// (see `TitleRename.commit`) — the latter only while the item is still
    /// listed: one closed while its name was being typed has nothing to
    /// rename. Return and Escape give the keyboard back to what had it
    /// before, or else to the item's terminal; where it went by itself, it
    /// stays.
    private func endTitleRename(_ session: TitleRenameSession, _ ending: TitleRenameEnding) {
        guard session.end() else { return }
        if titleRename === session {
            titleRename = nil
        }
        if ending != .cancel, let commit = TitleRename.commit(session.text, for: session.item),
           ending == .submit || paneDestinations.contains(where: { $0.item.id == session.item.id }) {
            renameCommit = commit
        }
        if ending != .left, !session.giveKeyboardBack() {
            terminalPaneFocus = keyboardPane(in: session.item).map { TerminalPaneFocus(paneID: $0) }
        }
    }

    /// The pane in `item` that is to have the keyboard: the pane itself, or
    /// in the selected tab the pane last given it — until one has been, the
    /// one herdr has focused in it — as for the browser column.
    private func keyboardPane(in item: BoardItem) -> String? {
        switch item {
        case .pane(let pane):
            return pane.id
        case .tab(let renamed):
            guard let selected = selection, case .tab(let tab) = selected.item, tab.id == renamed.id else { return nil }
            let identity = TerminalIdentity(connection: selected.connection, itemID: tab.id)
            let paneID = activatedPanes[identity] ?? tab.focusedPaneID
            return (tab.panes.first { $0.paneID == paneID } ?? tab.panes.first)?.id
        }
    }

    private func closeCommandTarget(on machine: Machine?) -> CloseCommandTarget {
        CloseCommandTarget(
            selection: machine.flatMap { selection(on: $0).wrappedValue },
            showsTabs: showsTabs && AgentBoardView.offersTabs,
            coversTerminal: launcherStart != nil || isShowingSettings || isShowingPaneSwitcher
                || (showsFilePreview && expandsFilePreview) || webLinkFailure != nil
        )
    }
    #endif

    /// The selected pane's terminal, or every terminal of the selected tab.
    /// The ZStack is the column's one constant view: its appearance and
    /// disappearance are the column's own, whatever is inside.
    private func terminalColumn(on machine: Machine?) -> some View {
        ZStack {
            if let machine, let item = selection(on: machine).wrappedValue {
                if isDetailColumnVisible {
                    let identity = TerminalIdentity(connection: machine.connectionIdentity, itemID: item.id)
                    let typedTitle = renameCommit?.title(for: item)
                    Group {
                        switch item {
                        case .pane(let agent):
                            AgentTerminalView(machine: machine, agent: agent, machineStore: machineStore, onOpenFile: openFile, onOpenWeb: openWeb,
                                title: typedTitle)
                        case .tab(let tab):
                            TabTerminalView(machine: machine, tab: tab, machineStore: machineStore,
                                onPaneActivated: { paneID in activatedPanes[identity] = paneID }, onOpenFile: openFile, onOpenWeb: openWeb,
                                takesKeyboardWhenShown: titleRename == nil, title: typedTitle)
                        }
                    }
                    .id(identity)
                } else {
                    Color.clear
                }
            } else {
                noSelectionPlaceholder
            }
        }
        .onAppear { isDetailColumnVisible = true }
        .onDisappear { isDetailColumnVisible = false }
    }

    private func previewBelongsToSelection(_ request: FilePreviewRequest) -> Bool {
        guard machineStore.isCurrentConnection(request.machine),
              let selected = selection, selected.connection == request.machine.connectionIdentity else { return false }
        let panes: [AgentSummary]
        switch selected.item {
        case .pane(let pane): panes = [pane]
        case .tab(let tab): panes = tab.panes
        }
        return panes.contains { $0.paneID == request.paneID && $0.terminalID == request.terminalID }
    }

    private func openFile(_ request: FilePreviewRequest) {
        guard previewBelongsToSelection(request) else { return }
        filePreview = request
        #if os(macOS)
        // Presentation only: don't disable the feature, discard a browser,
        // revoke agent authority, or delete profiles when switching columns.
        showsBrowser = false
        showsFilePreview = true
        #endif
    }

    private func openWeb(_ request: TerminalWebLinkRequest) {
        guard machineStore.isCurrentConnection(request.machine), let selected = selection,
              selected.connection == request.machine.connectionIdentity else { return }
        let panes: [AgentSummary]
        switch selected.item {
        case .pane(let pane): panes = [pane]
        case .tab(let tab): panes = tab.panes
        }
        guard let pane = request.pane(in: panes, on: request.machine) else { return }
        do {
            guard let url = try TerminalWebLink.urlToOpen(request.rawURL, contextMatches: true,
                browserEnabled: ShepherdBrowserFeature.shared.isEnabled, engineAvailable: BrowserEngine.isAvailable) else { return }
            BrowserStore.shared.openBrowser(for: BrowserKey(machine: request.machine, pane: pane), terminalID: pane.terminalID, url: url)
            if case .tab = selected.item {
                let identity = TerminalIdentity(connection: selected.connection, itemID: selected.item.id)
                activatedPanes[identity] = pane.paneID
            }
            // Only switch presentation. Existing profiles/tabs and agent grants
            // stay intact; opening a human URL does not register an agent.
            showsFilePreview = false
            expandsFilePreview = false
            showsBrowser = true
        } catch let failure as TerminalWebLinkError { webLinkFailure = failure }
        catch { webLinkFailure = .invalidURL }
    }

    private func previewPanel(_ request: FilePreviewRequest) -> some View {
        FilePreviewPanel(request: request, machineStore: machineStore, onClose: {
            showsFilePreview = false
        }, onFileLink: openFile)
        #if os(macOS)
        .previewExpansion(isExpanded: expandsFilePreview, onToggle: { expandsFilePreview.toggle() })
        #endif
    }

    /// Resolve again after native sheet dismissal, never route a stale item
    /// from another endpoint, nested herdr, or reused terminal ID.
    private func navigateToPendingPane() {
        defer { pendingPaneDestination = nil }
        guard let requested = pendingPaneDestination, let machine = machineStore.activeMachine,
              let current = PaneDestination.resolve(requested, in: paneDestinations,
                contextMatches: switcherConnection == machine.connectionIdentity && machineStore.isCurrentConnection(machine)) else { return }
        #if os(macOS)
        expandsFilePreview = false
        #endif
        justCreatedID = nil
        selection = MachineSelection(connection: machine.connectionIdentity, item: current.item)
        terminalPaneFocus = TerminalPaneFocus(paneID: current.pane.id)
    }

    #if os(macOS)
    /// The panes in front of the person: the selected pane, or every pane of
    /// the selected tab, while the window is key — as for marking an agent
    /// seen (see `SeenMarking`). No notification is given about these.
    private var viewedPanesNow: Set<NotificationPaneKey> {
        guard controlActiveState == .key, let machine = machineStore.activeMachine,
              let item = selection(on: machine).wrappedValue else { return [] }
        let panes: [AgentSummary]
        switch item {
        case .pane(let pane): panes = [pane]
        case .tab(let tab): panes = tab.panes
        }
        return Set(panes.map { NotificationPaneKey($0, on: machine.connectionIdentity) })
    }

    /// Goes to the pane of the notification last clicked: makes its machine
    /// the active one if it isn't, and selects the pane once the board for
    /// it lists the pane — the tab it is in, while the board shows tabs —
    /// as the pane switcher would. Given up on when the machine is gone, or
    /// when the active machine changes again after it was switched to.
    private func navigateToNotifiedPane() {
        let notifications = NotificationCoordinator.shared
        guard var request = notifications.navigationRequest else { return }
        guard let target = machineStore.allMachines.first(where: { $0.id == request.route.machineID }) else {
            notifications.navigationRequest = nil
            return
        }
        guard machineStore.activeMachineID == target.id else {
            if request.switchedMachine {
                notifications.navigationRequest = nil
            } else {
                request.switchedMachine = true
                notifications.navigationRequest = request
                machineStore.activeMachineID = target.id
            }
            return
        }
        guard let destination = paneDestinations.first(where: {
            $0.pane.id == request.route.boardPaneID && $0.pane.terminalID == request.route.terminalID
        }), destination.isAvailable else { return }
        notifications.navigationRequest = nil
        isShowingPaneSwitcher = false
        launcherStart = nil
        expandsFilePreview = false
        justCreatedID = nil
        selection = MachineSelection(connection: target.connectionIdentity, item: destination.item)
        terminalPaneFocus = TerminalPaneFocus(paneID: destination.pane.id)
    }

    /// The pane whose browser the browser column shows: the selected pane,
    /// or in a selected tab the pane last given the keyboard — until one
    /// has been, the pane herdr has focused in it (A2).
    private func browserTarget(on machine: Machine?) -> BrowserColumn.Target? {
        guard let machine, let item = selection(on: machine).wrappedValue else { return nil }
        let pane: AgentSummary?
        switch item {
        case .pane(let agent):
            pane = agent
        case .tab(let tab):
            let identity = TerminalIdentity(connection: machine.connectionIdentity, itemID: item.id)
            let paneID = activatedPanes[identity] ?? tab.focusedPaneID
            pane = tab.panes.first { $0.paneID == paneID } ?? tab.panes.first
        }
        return pane.map { BrowserColumn.Target(key: BrowserKey(machine: machine, pane: $0), terminalID: $0.terminalID) }
    }
    #endif

    private func allowsBrowserAgents(on machine: Machine) -> Bool {
        ShepherdBrowserFeature.shared.isEnabled && machine.isLocal && BrowserEngine.isAvailable
    }

    private var paneSwitcherButton: some View {
        Button { isShowingPaneSwitcher = true } label: {
            Label("Go to Agent or Pane…", systemImage: "magnifyingglass")
        }
        .disabled(machineStore.activeMachine == nil || isShowingSettings || launcherStart != nil)
        .help("Go to Agent or Pane… (⌘P)")
    }

    private var newTabButton: some View {
        Button {
            launcherStart = launcherStart == nil ? .blank : nil
        } label: {
            Label("New Tab", systemImage: "plus")
        }
        .disabled(machineStore.activeMachine == nil)
    }

    /// What the launcher comes up with already picked: nothing, or — for
    /// New Tab in Current Workspace… — the herdr and the workspace of the
    /// selected pane or tab. The launcher takes this as it comes up, and
    /// doesn't follow the selection after that.
    private func launcherPreset(_ start: LauncherStart, on machine: Machine) -> LaunchPreset? {
        switch start {
        case .blank: nil
        case .currentWorkspace: LaunchPreset.current(for: selection(on: machine).wrappedValue, in: launchTargets)
        }
    }

    /// Opens the tab the launcher asked for, over a connection of its own,
    /// and selects it at once — before the board has listed it, which it is
    /// asked to do straight away (see `AgentBoardView.justCreatedID`).
    private func openTab(_ request: LaunchRequest, on machine: Machine) async throws {
        func requireCurrentConnection() throws {
            try Task.checkCancellation()
            guard machineStore.isCurrentConnection(machine) else { throw MachineStore.EditError.settingsChanged }
        }
        try requireCurrentConnection()
        let client = HerdrClient(transport: try machineStore.makeHerdrTransport(for: machine))
        var retained: HerdrClient.CreatedTab?
        func select(_ created: HerdrClient.CreatedTab) {
            retained = created
            guard machineStore.isCurrentConnection(machine),
                  machineStore.activeMachine?.connectionIdentity == machine.connectionIdentity else { return }
            let item: BoardItem = showsTabs && AgentBoardView.offersTabs ? .tab(created.tab) : .pane(created.pane)
            justCreatedID = item.id
            selection = MachineSelection(connection: machine.connectionIdentity, item: item)
            boardRefreshRequests += 1
        }
        func create(_ environment: [String: String]) async throws -> HerdrClient.CreatedTab {
            try requireCurrentConnection()
            switch request.workspace {
            case .existing(let workspace):
                return try await client.createTab(inWorkspace: workspace.workspaceID, label: request.tabName, on: request.herdrMachine, environment: environment)
            case .new(let name):
                return try await client.createWorkspace(label: name, on: request.herdrMachine, environment: environment)
            }
        }
        do {
            try await client.connect()
            try requireCurrentConnection()
            let created: HerdrClient.CreatedTab
            if let kind = request.program.agentKind {
                guard request.herdrMachine == nil else { throw AgentRuntimeError.remoteUnavailable }
                created = try await AgentLaunchService.shared.launch(kind: kind, on: machine, client: client, create: create, select: select)
            } else {
                created = try await create([:])
                select(created)
            }
            try requireCurrentConnection()
            if case .new = request.workspace, let tabName = request.tabName {
                try await client.renameTab(created.tab.tabID, to: tabName, on: request.herdrMachine)
            }
            await client.disconnect()
        } catch {
            await client.disconnect()
            boardRefreshRequests += 1
            if retained != nil, machineStore.isCurrentConnection(machine),
               machineStore.activeMachine?.connectionIdentity == machine.connectionIdentity {
                throw CreatedPaneLaunchError(reason: connectionFailureDescription(error))
            }
            throw error
        }
    }

    @ViewBuilder
    private var noSelectionPlaceholder: some View {
        Group {
            if showsTabs && AgentBoardView.offersTabs {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "terminal",
                    description: Text("Select a tab from the sidebar.")
                )
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "terminal",
                    description: Text("Select an agent or a pane from the sidebar.")
                )
            }
        }
        #if os(macOS)
        // The window's title is the detail column's, and a column that sets
        // none leaves the last one standing — the pane or tab that was
        // selected before, long after it was let go of. With nothing
        // selected, the window goes back to the title it has before anything
        // is: the app's name.
        .navigationTitle(Self.appName)
        #endif
    }

    #if os(macOS)
    private static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? ProcessInfo.processInfo.processName
    #endif

    private var settingsButton: some View {
        Button {
            isShowingSettings = true
        } label: {
            Label("Settings", systemImage: "gear")
        }
    }

    /// The selection as the board for `machine` sees it: nil unless it was
    /// made on that machine. Writes are stamped with the same machine, and a
    /// board can only clear a selection that is its own — a board that is
    /// being replaced can't reach into its successor's.
    private func selection(on machine: Machine) -> Binding<BoardItem?> {
        let connection = machine.connectionIdentity
        return Binding(
            get: {
                guard machineStore.isCurrentConnection(machine),
                      let selection, selection.connection == connection else { return nil }
                return selection.item
            },
            set: { item in
                guard machineStore.isCurrentConnection(machine),
                      machineStore.activeMachine?.connectionIdentity == connection else { return }
                if let item {
                    selection = MachineSelection(connection: connection, item: item)
                } else if selection?.connection == connection {
                    selection = nil
                }
            }
        )
    }

    private var noActiveMachinePlaceholder: some View {
        ContentUnavailableView {
            Label("No Active Machine", systemImage: "server.rack")
        } description: {
            Text("Add a machine in Settings.")
        } actions: {
            Button("Open Settings") {
                isShowingSettings = true
            }
        }
    }
}

#Preview {
    ContentView(machineStore: MachineStore())
}
