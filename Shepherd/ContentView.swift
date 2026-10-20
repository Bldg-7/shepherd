import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    /// The file preview of each pane or tab, kept while another one is
    /// selected (see `FilePreviewPaneStates`).
    @State private var filePreviews = FilePreviewPaneStates()
    @State private var webLinkFailure: TerminalWebLinkError?
    /// Where links open, as set in Settings (see `LinkDestinationPolicy`).
    @AppStorage(LinkDestinationPolicy.preferenceKey) private var linkDestination: LinkDestinationPolicy.Preference = .ask
    /// A clicked link the person is being asked where to open, while the
    /// prompt for it is up.
    @State private var linkChoice: LinkChoice?
    /// A word on a link that went to the default browser because Shepherd
    /// Browser couldn't show it, while it is shown.
    @State private var linkNotice: LinkNotice?
    /// The terminal column's frame in the window, so that the prompt for a
    /// link can be put where the link was clicked.
    @State private var terminalColumnFrame = CGRect.zero
    @State private var isShowingPaneSwitcher = false
    @State private var paneDestinations: [PaneDestination] = []
    @State private var switcherConnection: Machine.ConnectionIdentity?
    @State private var pendingPaneDestination: PaneDestination?
    @State private var terminalPaneFocus: TerminalPaneFocus?
    /// The name being typed into the window's title, in place of the title,
    /// if one is (see `TitleRenameField`). A row's Rename item starts it on
    /// the board, a double-click on the title here; it is ended here.
    @State private var titleRename: TitleRenameSession?
    /// The last name typed into the title, which the title shows until
    /// herdr reports it (see `TitleRenameCommit`). The board sends it.
    @State private var renameCommit: TitleRenameCommit?
    #if os(macOS)
    @State private var passwordManagerWindowID = UUID()
    /// Whether the window shows the browser column beside the terminal: in
    /// every pane but one whose file preview is shown, which takes the
    /// column's place.
    @SceneStorage("ContentView.showsBrowser") private var showsBrowser = false
    /// The pane or tab whose file preview is expanded over the terminal. Only
    /// the selected one's can be: a preview selected again comes back at the
    /// side.
    @State private var expandedPreview: TerminalIdentity?
    /// For each tab shown in this window (by `TerminalIdentity`), the pane in
    /// it the browser column follows: the one last given the keyboard.
    @State private var activatedPanes: [TerminalIdentity: String] = [:]
    /// Whether the window is key, which it has to be for the selection to
    /// count as looked at (see `viewedPanesNow`).
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    #endif

    private func workspace(on machine: Machine?) -> some View {
        // The selected pane's or tab's file preview, kept or shown, and
        // whether the browser column is in its place.
        let keptPreview = keptPreview(on: machine)
        let shownPreview = keptPreview?.entry.isShown == true ? keptPreview : nil
        let browserShown = shownPreview == nil && ShepherdBrowserFeature.shared.isEnabled && showsBrowser
        let coversTerminal = previewCoversTerminal(on: machine)
        return WorkspaceNavigationSplitView {
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
                showsPanel: shownPreview != nil || browserShown,
                panelMinimum: shownPreview != nil ? 320 : 360,
                panelIdeal: shownPreview != nil ? 560 : 640,
                panelCoversTerminal: coversTerminal
            ) {
                terminalColumn(on: machine)
                    .accessibilityHidden(coversTerminal)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(WorkspaceSidebarDetailLayout())
            } panel: {
                if let shownPreview {
                    previewPanel(shownPreview.entry, for: shownPreview.item)
                        .frame(minWidth: 320, idealWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(WorkspaceSidebarDetailLayout())
                } else if browserShown {
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
            // A double-click on the title has a new name typed into it.
            .background {
                TitleDoubleClick(rename: { renameFromTitle(on: machine) })
            }
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
                    // The title took up the rest of the bar, which kept the
                    // buttons after it at its far end; the field only takes
                    // its own width, and this the rest.
                    ToolbarSpacer(.flexible, placement: .navigation)
                }
                if ShepherdBrowserFeature.shared.isEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if browserShown {
                            showsBrowser = false
                        } else {
                            // In a pane whose preview is in the browser's
                            // place, the preview makes way for it.
                            if let shownPreview { filePreviews.hide(shownPreview.item) }
                            showsBrowser = true
                        }
                    } label: {
                        Label(browserShown ? "Hide Browser" : "Show Browser", systemImage: "globe")
                    }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .help(browserShown ? "Hide Browser (⌥⌘B)" : "Show Browser (⌥⌘B)")
                }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard let keptPreview else { return }
                        if keptPreview.entry.isShown {
                            filePreviews.hide(keptPreview.item)
                        } else {
                            filePreviews.show(keptPreview.item)
                        }
                    } label: {
                        Label(shownPreview != nil ? "Hide Preview" : "Show Preview", systemImage: "doc.text")
                    }
                    .disabled(keptPreview == nil)
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
            // The file previews stay with their panes, and come back when a
            // pane is selected again on this machine. Those of a connection
            // that is gone go with it (see `machineStore.allMachines`).
            // A name typed for the other machine's board isn't sent, and the
            // keyboard is left alone: a pane ID means nothing on its own.
            if let titleRename {
                _ = titleRename.end()
                self.titleRename = nil
            }
            renameCommit = nil
            linkChoice = nil
            #if os(macOS)
            activatedPanes = [:]
            #endif
        }
        // A kept preview whose pane has left the selected tab, or whose pane
        // ID now names another terminal, has nothing left to show.
        .onChange(of: stalePreview(on: machine)) { _, item in
            if let item { filePreviews.forget(item) }
        }
        .onChange(of: selection?.item.id) { _, id in
            // The title isn't the renamed item's any more: as if the
            // keyboard had gone elsewhere — which a click on another row
            // has already done.
            if let titleRename, titleRename.item.id != id {
                endTitleRename(titleRename, .left)
            }
            // The preview stays with the pane or tab that was selected, as
            // it was, but at the side: going to another one reveals its
            // terminal, and coming back reveals this one's.
            linkChoice = nil
            #if os(macOS)
            expandedPreview = nil
            #endif
        }
        #if os(macOS)
        .onChange(of: shownPreviewItem(on: machine)) { _, item in
            if expandedPreview != item { expandedPreview = nil }
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
            #if os(macOS)
            // A sheet that is up keeps the app from quitting: AppKit beeps
            // and calls the quit off before the app delegate hears of it, and
            // that goes for the quit an update's Install and Relaunch sends as
            // much as for ⌘Q. Nothing in the switcher is lost by closing it,
            // so it closes and lets the app quit.
            .presentationPreventsAppTermination(false)
            #endif
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
                    create: { request, handOff in try await openTab(request, on: machine, handOff: handOff) },
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
                #if os(macOS)
                // Settings, too, closes for a quit rather than stopping it
                // (see the pane switcher's sheet). Its Check Now leaves it
                // open behind the update's window, so without this the
                // update's Install and Relaunch only beeps.
                .presentationPreventsAppTermination(false)
                #endif
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
            // The file previews of panes the board no longer lists go with
            // them; those on a herdr it couldn't read are kept.
            if let machine = machineStore.activeMachine {
                filePreviews.forgetPanes(on: machine.connectionIdentity,
                                         notIn: paneDestinations.filter(\.isAvailable).map(\.pane))
            }
        }
        // A Machine that is removed, or now uses another herdr session,
        // takes its panes' browsers with it, and its file previews.
        .onChange(of: machineStore.allMachines, initial: true) { _, machines in
            filePreviews.forgetConnections(notIn: Set(machines.map(\.connectionIdentity)))
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

    /// Starts a rename of what is selected on `machine`, for a double-click
    /// on the window's title (see `TitleDoubleClick`): of what ⌘W would
    /// close — nothing while something covers the terminal — and not while
    /// a name is typed into the title already. False if there is nothing to
    /// rename.
    private func renameFromTitle(on machine: Machine?) -> Bool {
        guard titleRename == nil, let machine, let item = closeCommandTarget(on: machine).item else { return false }
        beginTitleRename(TitleRenameSession(item: item), on: machine)
        return true
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
                || previewCoversTerminal(on: machine) || webLinkFailure != nil || linkChoice != nil
        )
    }

    /// The pane or tab whose file preview is shown, if the selected one's is.
    private func shownPreviewItem(on machine: Machine?) -> TerminalIdentity? {
        guard let kept = keptPreview(on: machine), kept.entry.isShown else { return nil }
        return kept.item
    }

    /// Whether the selected pane's or tab's file preview is shown expanded
    /// over the terminal.
    private func previewCoversTerminal(on machine: Machine?) -> Bool {
        guard let item = shownPreviewItem(on: machine) else { return false }
        return expandedPreview == item
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
        #if os(macOS)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { terminalColumnFrame = $0 }
        // Where to open a clicked link, over the link itself.
        .popover(item: $linkChoice, attachmentAnchor: linkChoiceAnchor, arrowEdge: .top) { choice in
            LinkDestinationPrompt(url: choice.url) { destination, remember in
                resolveLinkChoice(choice, destination: destination, remember: remember)
            }
        }
        .overlay(alignment: .bottom) {
            if let linkNotice {
                LinkOpenedNotice(text: linkNotice.text)
                    .environment(\.colorScheme, .dark)
                    .task(id: linkNotice.id) {
                        try? await Task.sleep(for: .seconds(6))
                        if self.linkNotice?.id == linkNotice.id { self.linkNotice = nil }
                    }
            }
        }
        #endif
    }

    /// A link whose browser is being asked for.
    private struct LinkChoice: Identifiable {
        let request: TerminalWebLinkRequest
        /// `request.rawURL`, validated.
        let url: String
        var id: String { request.terminalID + " " + url }
    }

    private struct LinkNotice: Equatable {
        let id = UUID()
        let text: String
    }

    #if os(macOS)
    /// The clicked link's place in the terminal column, or the column's top
    /// for a click whose place isn't known.
    private var linkChoiceAnchor: PopoverAttachmentAnchor {
        guard let point = linkChoice?.request.click.windowPoint else { return .point(.top) }
        let local = CGPoint(x: point.x - terminalColumnFrame.minX, y: point.y - terminalColumnFrame.minY)
        return .rect(.rect(CGRect(x: local.x - 1, y: local.y - 1, width: 2, height: 2)))
    }
    #endif

    private func previewBelongsToSelection(_ request: FilePreviewRequest) -> Bool {
        guard machineStore.isCurrentConnection(request.machine),
              let selected = selection, selected.connection == request.machine.connectionIdentity else { return false }
        return request.belongs(to: Self.panes(of: selected.item))
    }

    private static func panes(of item: BoardItem) -> [AgentSummary] {
        switch item {
        case .pane(let pane): [pane]
        case .tab(let tab): tab.panes
        }
    }

    /// The file preview kept for the pane or tab selected on `machine`, if
    /// it still belongs to it, shown or closed.
    private func keptPreview(on machine: Machine?) -> (item: TerminalIdentity, entry: FilePreviewPaneStates.Entry)? {
        guard let machine, let selected = selection(on: machine).wrappedValue else { return nil }
        let item = TerminalIdentity(connection: machine.connectionIdentity, itemID: selected.id)
        return filePreviews.entry(for: item, panes: Self.panes(of: selected)).map { (item, $0) }
    }

    /// The pane or tab selected on `machine`, if the preview kept for it
    /// belongs to it no longer.
    private func stalePreview(on machine: Machine?) -> TerminalIdentity? {
        guard let machine, let selected = selection(on: machine).wrappedValue else { return nil }
        let item = TerminalIdentity(connection: machine.connectionIdentity, itemID: selected.id)
        return filePreviews.isStale(item, panes: Self.panes(of: selected)) ? item : nil
    }

    private func openFile(_ request: FilePreviewRequest) {
        guard previewBelongsToSelection(request), let selected = selection else { return }
        // Only in the selected pane or tab, where it takes the browser
        // column's place; the column stays on for the other panes. Nothing
        // is done to a browser, its profiles or an agent's connection to it.
        filePreviews.open(request, for: TerminalIdentity(connection: selected.connection, itemID: selected.item.id))
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
        let url: String
        do { url = try TerminalWebLink.validatedURL(request.rawURL) }
        catch let failure as TerminalWebLinkError { webLinkFailure = failure; return }
        catch { webLinkFailure = .invalidURL; return }
        // The same validation whichever browser it goes to; only Shepherd
        // Browser has conditions of its own, and a link it can't show goes
        // to the default browser.
        let browserAvailable = ShepherdBrowserFeature.shared.isEnabled && BrowserEngine.isAvailable
        let commandHeld = request.click.commandHeld
        switch LinkDestinationPolicy.destination(preference: linkDestination, commandHeld: commandHeld, browserAvailable: browserAvailable) {
        case .ask:
            linkChoice = LinkChoice(request: request, url: url)
        case .system:
            openInDefaultBrowser(url, fellBack: LinkDestinationPolicy.fallsBackToSystem(
                preference: linkDestination, commandHeld: commandHeld, browserAvailable: browserAvailable))
        case .shepherd:
            openInShepherdBrowser(url, in: pane, on: request.machine, selected: selected)
        }
    }

    /// Opens a link the prompt was up for, as answered. The link's pane is
    /// looked up again: the board can have changed while the prompt was up.
    private func resolveLinkChoice(_ choice: LinkChoice, destination: LinkDestinationPolicy.Preference, remember: Bool) {
        linkChoice = nil
        if remember { linkDestination = destination }
        switch destination {
        case .system:
            openInDefaultBrowser(choice.url, fellBack: false)
        case .shepherd, .ask:
            guard let selected = selection, selected.connection == choice.request.machine.connectionIdentity,
                  machineStore.isCurrentConnection(choice.request.machine) else { return }
            let panes: [AgentSummary]
            switch selected.item {
            case .pane(let pane): panes = [pane]
            case .tab(let tab): panes = tab.panes
            }
            guard let pane = choice.request.pane(in: panes, on: choice.request.machine) else { return }
            openInShepherdBrowser(choice.url, in: pane, on: choice.request.machine, selected: selected)
        }
    }

    /// Opens `url`, validated, in a new tab of `pane`'s Shepherd Browser,
    /// and shows the browser column.
    private func openInShepherdBrowser(_ url: String, in pane: AgentSummary, on machine: Machine, selected: MachineSelection) {
        BrowserStore.shared.openBrowser(for: BrowserKey(machine: machine, pane: pane), terminalID: pane.terminalID, url: url)
        let identity = TerminalIdentity(connection: selected.connection, itemID: selected.item.id)
        if case .tab = selected.item {
            activatedPanes[identity] = pane.paneID
        }
        // Only switch presentation. Existing profiles/tabs and agent grants
        // stay intact; opening a human URL does not register an agent. A
        // preview in the column's place makes way for it, keeping its file.
        filePreviews.hide(identity)
        expandedPreview = nil
        showsBrowser = true
    }

    /// Opens `url`, validated, in the Mac's default browser. `fellBack` says
    /// it goes there only because Shepherd Browser can't show it, which is
    /// said in a notice over the terminal.
    private func openInDefaultBrowser(_ url: String, fellBack: Bool) {
        guard let target = URL(string: url) else { webLinkFailure = .invalidURL; return }
        NSWorkspace.shared.open(target)
        guard fellBack else { return }
        linkNotice = LinkNotice(text: ShepherdBrowserFeature.shared.isEnabled
            ? String(localized: "hrdrhrdrhrdr Browser isn't available on this Mac, so the link opened in the default browser.")
            : String(localized: "hrdrhrdrhrdr Browser is off, so the link opened in the default browser."))
    }

    /// The preview of `item`, the selected pane or tab. A view of its own for
    /// each preview: what one is scrolled to, or has the keyboard, is never
    /// carried over to another pane's file.
    private func previewPanel(_ entry: FilePreviewPaneStates.Entry, for item: TerminalIdentity) -> some View {
        FilePreviewPanel(request: entry.request, model: entry.model, machineStore: machineStore, onClose: {
            filePreviews.hide(item)
        }, onFileLink: openFile)
        #if os(macOS)
        .previewExpansion(isExpanded: expandedPreview == item, onToggle: {
            expandedPreview = expandedPreview == item ? nil : item
        })
        #endif
        .id(entry.model.id)
    }

    /// Resolve again after native sheet dismissal, never route a stale item
    /// from another endpoint, nested herdr, or reused terminal ID.
    private func navigateToPendingPane() {
        defer { pendingPaneDestination = nil }
        guard let requested = pendingPaneDestination, let machine = machineStore.activeMachine,
              let current = PaneDestination.resolve(requested, in: paneDestinations,
                contextMatches: switcherConnection == machine.connectionIdentity && machineStore.isCurrentConnection(machine)) else { return }
        #if os(macOS)
        expandedPreview = nil
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
        expandedPreview = nil
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
    ///
    /// An agent's tab is handed off (`handOff`) as soon as the agent's start
    /// command is in its pane, named already: the launcher closes then, and
    /// the launch goes on until the agent is ready, its wait and any failure
    /// showing in the sidebar. A shell's tab is not handed off; the launcher
    /// closes when this returns.
    private func openTab(_ request: LaunchRequest, on machine: Machine, handOff: @escaping @MainActor () -> Void) async throws {
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
        /// A new workspace's first tab is herdr's to name; the name asked for
        /// is given to it afterwards.
        func rename(_ created: HerdrClient.CreatedTab) async throws {
            try requireCurrentConnection()
            if case .new = request.workspace, let tabName = request.tabName {
                try await client.renameTab(created.tab.tabID, to: tabName, on: request.herdrMachine)
            }
        }
        do {
            try await client.connect()
            try requireCurrentConnection()
            if let kind = request.program.agentKind {
                guard request.herdrMachine == nil else { throw AgentRuntimeError.remoteUnavailable }
                // Named before it is handed off, so the launcher closes on the
                // tab with its name. A rename that fails keeps the launcher up
                // instead, and is what it shows once the launch has ended.
                var renameFailure: (any Error)?
                _ = try await AgentLaunchService.shared.launch(kind: kind, on: machine, client: client, create: create, select: select, started: {
                    do {
                        if let retained { try await rename(retained) }
                        handOff()
                    } catch { renameFailure = error }
                })
                try requireCurrentConnection()
                if let renameFailure { throw renameFailure }
            } else {
                let created = try await create([:])
                select(created)
                try await rename(created)
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
