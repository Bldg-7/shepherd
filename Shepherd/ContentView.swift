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
        let machineID: UUID
        let item: BoardItem
    }

    /// What makes one terminal view a different one from another.
    /// `AgentTerminalView` builds its session once, when the view is created,
    /// so a view that outlived a change of pane or machine would stay attached
    /// to the old pane while showing the new one's title. Tying the view's
    /// identity to this value gives every (machine, pane or tab) its own view,
    /// and tears the previous one down along with its sessions.
    private nonisolated struct TerminalIdentity: Hashable {
        let machineID: UUID
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
    @State private var isShowingLauncher = false
    /// What the new tab launcher offers, as the board last reported it.
    @State private var launchTargets: [LaunchTarget] = []
    /// See `AgentBoardView.justCreatedID`.
    @State private var justCreatedID: String?
    /// Goes up to have the board fetch everything again at once.
    @State private var boardRefreshRequests = 0
    #if os(macOS)
    @State private var passwordManagerWindowID = UUID()
    /// Whether the window shows the browser column beside the terminal.
    @SceneStorage("ContentView.showsBrowser") private var showsBrowser = false
    /// For each tab shown in this window (by `TerminalIdentity`), the pane in
    /// it the browser column follows: the one last given the keyboard.
    @State private var activatedPanes: [TerminalIdentity: String] = [:]
    #endif

    var body: some View {
        let machine = machineStore.activeMachine
        NavigationSplitView {
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
                        refreshRequests: boardRefreshRequests
                    )
                        .id(machine.id)
                } else {
                    noActiveMachinePlaceholder
                }
            }
            // Left to itself the sidebar comes up too narrow for a board
            // row, let alone for the failure banner and its Retry button.
            // Capped as well: with no maximum, its divider can be dragged
            // across the whole window, and a row has nothing to fill that
            // width with but the gap between its title and its status.
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
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
                        .help("New Tab (⌘T)")
                }
            }
        } detail: {
            // The browser column sits beside the terminal, outside of the
            // terminal's identity: the terminal view is made anew for each
            // pane or tab, the browser column only switches which pane's
            // browser it shows (plan item A1).
            HSplitView {
                terminalColumn(on: machine)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if ShepherdBrowserFeature.shared.isEnabled && showsBrowser {
                    BrowserColumn(target: browserTarget(on: machine))
                        .frame(minWidth: 360, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                if ShepherdBrowserFeature.shared.isEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsBrowser.toggle()
                    } label: {
                        Label(showsBrowser ? "Hide Browser" : "Show Browser", systemImage: "globe")
                    }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .help(showsBrowser ? "Hide Browser (⌥⌘B)" : "Show Browser (⌥⌘B)")
                }
                }
            }
        }
        .onChange(of: machine?.id) { _, activeMachineID in
            // A selection made on another machine already reads as nothing
            // selected; forget it as well, so that switching back to that
            // machine later starts with nothing selected instead of
            // re-attaching to a pane nobody picked this time around.
            if selection?.machineID != activeMachineID {
                selection = nil
            }
        }
        .onChange(of: showsTabs) {
            // The board now lists the other kind of row, and what was
            // selected is no longer on it.
            selection = nil
        }
        // Over the whole window, sidebar and detail alike, as Spotlight is
        // over the screen.
        .overlay {
            if isShowingLauncher, let machine {
                NewTabLauncher(
                    targets: launchTargets,
                    allowsBrowserAgents: allowsBrowserAgents(on: machine),
                    create: { request in try await openTab(request, on: machine) },
                    onClose: { isShowingLauncher = false }
                )
            }
        }
        .onChange(of: machine?.id) {
            isShowingLauncher = false
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
        }
        .onDisappear {
            ShepherdBrowserFeature.shared.passwordManagers.endVisit(owner: passwordManagerWindowID)
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
        // through: the window it acts on is whichever one is in front.
        .focusedSceneValue(\.isShowingSettings, $isShowingSettings)
        // And the File menu's New Tab… (⌘T), the launcher.
        .focusedSceneValue(\.isShowingLauncher, machine == nil ? nil : $isShowingLauncher)
        #endif
    }

    /// The selected pane's terminal, or every terminal of the selected tab.
    /// The ZStack is the column's one constant view: its appearance and
    /// disappearance are the column's own, whatever is inside.
    private func terminalColumn(on machine: Machine?) -> some View {
        ZStack {
            if let machine, let item = selection(on: machine).wrappedValue {
                if isDetailColumnVisible {
                    let identity = TerminalIdentity(machineID: machine.id, itemID: item.id)
                    Group {
                        switch item {
                        case .pane(let agent):
                            AgentTerminalView(machine: machine, agent: agent, machineStore: machineStore)
                        case .tab(let tab):
                            TabTerminalView(machine: machine, tab: tab, machineStore: machineStore) { paneID in
                                activatedPanes[identity] = paneID
                            }
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

    #if os(macOS)
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
            let identity = TerminalIdentity(machineID: machine.id, itemID: item.id)
            let paneID = activatedPanes[identity] ?? tab.focusedPaneID
            pane = tab.panes.first { $0.paneID == paneID } ?? tab.panes.first
        }
        return pane.map { BrowserColumn.Target(key: BrowserKey(machine: machine, pane: $0), terminalID: $0.terminalID) }
    }
    #endif

    private func allowsBrowserAgents(on machine: Machine) -> Bool {
        ShepherdBrowserFeature.shared.isEnabled && machine.isLocal && BrowserEngine.isAvailable
    }

    private var newTabButton: some View {
        Button {
            isShowingLauncher.toggle()
        } label: {
            Label("New Tab", systemImage: "plus")
        }
        .disabled(machineStore.activeMachine == nil)
    }

    /// Opens the tab the launcher asked for, over a connection of its own,
    /// and selects it at once — before the board has listed it, which it is
    /// asked to do straight away (see `AgentBoardView.justCreatedID`).
    private func openTab(_ request: LaunchRequest, on machine: Machine) async throws {
        let client = HerdrClient(transport: try machineStore.makeHerdrTransport(for: machine))
        var retained: HerdrClient.CreatedTab?
        func select(_ created: HerdrClient.CreatedTab) {
            retained = created
            let item: BoardItem = showsTabs && AgentBoardView.offersTabs ? .tab(created.tab) : .pane(created.pane)
            justCreatedID = item.id
            selection = MachineSelection(machineID: machine.id, item: item)
            boardRefreshRequests += 1
        }
        func create(_ environment: [String: String]) async throws -> HerdrClient.CreatedTab {
            switch request.workspace {
            case .existing(let workspace):
                return try await client.createTab(inWorkspace: workspace.workspaceID, label: request.tabName, on: request.herdrMachine, environment: environment)
            case .new(let name):
                return try await client.createWorkspace(label: name, on: request.herdrMachine, environment: environment)
            }
        }
        do {
            try await client.connect()
            let created: HerdrClient.CreatedTab
            if let kind = request.program.agentKind {
                guard request.herdrMachine == nil else { throw AgentRuntimeError.remoteUnavailable }
                created = try await AgentLaunchService.shared.launch(kind: kind, on: machine, client: client, create: create, select: select)
            } else {
                created = try await create([:])
                select(created)
            }
            if case .new = request.workspace, let tabName = request.tabName {
                try await client.renameTab(created.tab.tabID, to: tabName, on: request.herdrMachine)
            }
            await client.disconnect()
        } catch {
            await client.disconnect()
            boardRefreshRequests += 1
            if retained != nil { throw CreatedPaneLaunchError(reason: connectionFailureDescription(error)) }
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
        let machineID = machine.id
        return Binding(
            get: {
                guard let selection, selection.machineID == machineID else { return nil }
                return selection.item
            },
            set: { item in
                if let item {
                    selection = MachineSelection(machineID: machineID, item: item)
                } else if selection?.machineID == machineID {
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
