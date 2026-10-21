import SwiftUI

/// What can be selected on the board: a pane, or — while the board shows
/// tabs — a whole tab.
enum BoardItem: Equatable {
    case pane(AgentSummary)
    case tab(TabSummary)

    /// The item's row ID in the board's list. A pane's and a tab's can't
    /// be the same: herdr writes their IDs "w1:p1" and "w1:t1".
    var id: String {
        switch self {
        case .pane(let pane): pane.id
        case .tab(let tab): tab.id
        }
    }

    /// The herdr machine the item is on, or nil for the host's own herdr.
    var herdrMachine: HerdrMachine? {
        switch self {
        case .pane(let pane): pane.herdrMachine
        case .tab(let tab): tab.herdrMachine
        }
    }

    /// The workspace the item is in. Nil only from a herdr that doesn't say.
    var workspaceID: String? {
        switch self {
        case .pane(let pane): pane.workspaceID
        case .tab(let tab): tab.workspaceID
        }
    }

    /// What the item is called on screen: in its row, and in the window's
    /// title while it is selected.
    var title: String {
        switch self {
        case .pane(let pane): pane.title
        case .tab(let tab): tab.title
        }
    }
}

/// What the File menu's Close item — ⌘W — closes. Never the window: the
/// selected tab while the board shows tabs, or the selected pane, after the
/// confirmation the sidebar's Close Tab and Close Pane ask for.
struct CloseCommandTarget: Equatable {
    /// Whether the item reads Close Tab rather than Close Pane. It goes by
    /// the selection — a herdr too old to report tabs lists panes in the tab
    /// mode too — and by the mode while nothing is selected.
    let closesTab: Bool
    /// The tab or pane to close, or nil — the item disabled — with nothing
    /// selected, or while something covers the terminal: the new tab
    /// launcher, Settings, the pane switcher, a preview expanded over it, an
    /// alert. The board's own dialogs it leaves to the board (see
    /// `AgentBoardView.closeRequests`).
    let item: BoardItem?

    init(selection: BoardItem?, showsTabs: Bool, coversTerminal: Bool) {
        switch selection {
        case .tab: closesTab = true
        case .pane: closesTab = false
        case nil: closesTab = showsTabs
        }
        item = coversTerminal ? nil : selection
    }
}

/// The sidebar content of `ContentView`'s `NavigationSplitView` — the panes,
/// or the tabs, of whichever Machine is currently active, with `selection`
/// driving the detail column. What it lists comes from the machine's
/// `MachineMonitor`, which it keeps running while it is on screen; the
/// notifications share it.
struct AgentBoardView: View {
    let machine: Machine
    let machineStore: MachineStore
    @Binding var selection: BoardItem?
    /// The ID of a pane or tab that was selected the moment it was made, by
    /// the new tab launcher, and that the board may not have listed yet. A
    /// snapshot without it is taken to be older than it, and leaves the
    /// selection alone instead of dropping it; the first one with it clears
    /// this.
    @Binding var justCreatedID: String?
    /// What the new tab launcher offers, kept up to date with what the board
    /// knows of its herdrs (see `launchTargetsNow`).
    @Binding var launchTargets: [LaunchTarget]
    /// Goes up each time the board is to read everything again at once.
    let refreshRequests: Int
    /// Goes up each time the File menu's Close Tab or Close Pane (⌘W) is
    /// chosen, to close the selection as its row's context menu would — but
    /// not while a name is being typed into the window's title, nor over a
    /// confirmation or a failure the board still shows.
    let closeRequests: Int
    /// Goes up each time the File menu's Remove herdr Machine… is chosen,
    /// to ask about removing the herdr machine the selection is on, as its
    /// group header's menu would.
    let removeHerdrMachineRequests: Int
    /// Brings up the panel that adds a herdr machine to the host, or checks
    /// a failing one again — from a group header's menu.
    var onHerdrMachineSetup: (HerdrMachineSetup.Mode) -> Void
    var onNavigationDestinations: ([PaneDestination]) -> Void

    /// The rename being typed into the window's title, if there is one.
    /// A row's Rename item starts it here; `ContentView` shows it in the
    /// title, and ends it.
    @Binding var renaming: TitleRenameSession?
    /// The last name typed into the title, from when it is ready to be sent
    /// until herdr reports it (see `TitleRenameCommit`). `ContentView` puts
    /// it here; the board sends it, and lets it go.
    @Binding var renameCommit: TitleRenameCommit?
    /// The pane or tab waiting for the person to confirm it is to be closed.
    @State private var closing: BoardItem?
    /// The herdr machine waiting for the person to confirm it is to be
    /// removed from the host's herdr.
    @State private var removing: HerdrMachine?
    /// Why the last rename or close didn't go through.
    @State private var actionFailure: ActionFailure?
    /// The groups the person has folded away, by group ID, one per line.
    /// Kept per Shepherd Machine (see `init`), so the host group of one
    /// machine and of another are folded separately, and across launches.
    @AppStorage private var collapsedGroupIDs: String
    /// The order the person has put the groups in by dragging their headers,
    /// by group ID, one per line (see `BoardGroupOrder`). Kept per Shepherd
    /// Machine, as the folded groups are.
    @AppStorage private var groupOrderIDs: String
    /// The group header being dragged to another place, while one is.
    @State private var groupDrag = BoardGroupDrag()
    /// Whether the board lists tabs, one row each, instead of panes. One
    /// setting for every machine; see `showsTabsKey`.
    @AppStorage(Self.showsTabsKey) private var showsTabs = false
    /// What is typed into the sidebar's search field (see `searchTerms`).
    @State private var searchText = ""
    /// The workspaces picked in the search field's workspace filter, by
    /// `workspaceFilterKey`; empty for all of them. See
    /// `activeWorkspaceFilter` for the ones that still count.
    @State private var workspaceFilter: Set<String> = []
    /// The window's state, which has to be key for the agent selected in it
    /// to count as seen (see `seenRequestNow`).
    @Environment(\.controlActiveState) private var controlActiveState

    init(
        machine: Machine,
        machineStore: MachineStore,
        selection: Binding<BoardItem?>,
        justCreatedID: Binding<String?>,
        launchTargets: Binding<[LaunchTarget]>,
        refreshRequests: Int,
        closeRequests: Int,
        removeHerdrMachineRequests: Int = 0,
        onHerdrMachineSetup: @escaping (HerdrMachineSetup.Mode) -> Void = { _ in },
        renaming: Binding<TitleRenameSession?>,
        renameCommit: Binding<TitleRenameCommit?>,
        onNavigationDestinations: @escaping ([PaneDestination]) -> Void = { _ in }
    ) {
        self.machine = machine
        self.machineStore = machineStore
        self._selection = selection
        self._justCreatedID = justCreatedID
        self._launchTargets = launchTargets
        self.refreshRequests = refreshRequests
        self.closeRequests = closeRequests
        self.removeHerdrMachineRequests = removeHerdrMachineRequests
        self.onHerdrMachineSetup = onHerdrMachineSetup
        self._renaming = renaming
        self._renameCommit = renameCommit
        self.onNavigationDestinations = onNavigationDestinations
        self._collapsedGroupIDs = AppStorage(wrappedValue: "", "AgentBoardView.collapsedGroups.\(machine.id.uuidString)")
        self._groupOrderIDs = AppStorage(wrappedValue: "", "AgentBoardView.groupOrder.\(machine.id.uuidString)")
    }

    /// The machine's monitor, which keeps what the board lists up to date
    /// (see `MachineMonitors`).
    private var monitor: MachineMonitor {
        MachineMonitors.shared.monitor(for: machine, in: machineStore)
    }

    /// The host's panes, and the agents in them.
    private var agents: [AgentSummary] { monitor.panes }
    /// The host's tabs, or nil while its herdr hasn't reported any — before
    /// the first snapshot, or for good from a herdr too old to.
    private var tabs: [TabSummary]? { monitor.tabs }
    /// The host's workspaces, which its rows are listed under, or nil as for
    /// `tabs`.
    private var workspaces: [WorkspaceSummary]? { monitor.workspaces }
    /// Whether `agents` is a list herdr reported rather than the empty one
    /// a monitor starts out with (see `MachineMonitor.hasLoaded`).
    private var hasLoadedAgents: Bool { monitor.hasLoaded }
    private var loadError: String? { monitor.loadError }
    /// Whether the board will try again by itself after `loadError`, or has
    /// stopped until the person asks (see `MachineMonitor.isPermanentFailure`).
    /// The two look alike otherwise, and only one of them needs the person
    /// to do something.
    private var isRetrying: Bool { monitor.isRetrying }
    /// The herdr machines saved on the host (see `HerdrMachine`), each with
    /// what was last heard from it. Empty while the host has none, and then
    /// the board is one flat list of the host's agents, as it always was;
    /// with any, it is grouped by machine, the host's own agents first.
    private var herdrMachineGroups: [MachineMonitor.HerdrMachineGroup] { monitor.herdrMachineGroups }

    /// Where the tab setting is kept. `ContentView` reads it too: a pane
    /// selected in one mode means nothing in the other.
    static let showsTabsKey = "AgentBoardView.showsTabs"

    /// Whether this device offers the tab mode at all. Selecting a tab shows
    /// all of its panes side by side, and an iPhone's screen is too small to
    /// split; there the board only ever lists panes.
    static var offersTabs: Bool {
        true
    }

    /// The host's own group, among the machines' (whose IDs are herdr's
    /// profile IDs, so they can't clash with this).
    private static let hostGroupID = "host"

    /// How long a selection has to stay on a finished agent before herdr is
    /// told it has been seen (see `markSeen`). The rows the arrow keys pass
    /// over on the way to another don't count, and herdr's own view, which
    /// follows each request, moves once instead of with every one of them.
    private static let seenDelay: Duration = .milliseconds(500)

    var body: some View {
        board
            // Kept apart from the rest of `board`, which is as long a chain
            // of modifiers as the compiler takes in reasonable time.
            .confirmationDialog(removeTitle, isPresented: isRemoving, titleVisibility: .visible, presenting: removing) { herdrMachine in
                Button("Remove", role: .destructive) { remove(herdrMachine) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(removeMessage)
            }
            .onChange(of: removeHerdrMachineRequests) {
                guard renaming == nil, closing == nil, removing == nil, actionFailure == nil,
                      let id = selection?.herdrMachine?.id,
                      let group = herdrMachineGroups.first(where: { $0.id == id }) else { return }
                removing = group.machine
            }
            // A header being dragged as the board goes leaves no group
            // folded for it.
            .onDisappear { groupDrag.finish() }
    }

    private var board: some View {
        agentList
        // A list of its own for each mode. Switching between tab rows and
        // pane rows replaces every row at once, and left to diff one set
        // into the other, the list has AppKit recompute its row heights
        // from inside its own update — which AppKit reports as a reentrant
        // table view operation, a warning it says will become an assert.
        // Nothing carries over between the two anyway: the selection is
        // cleared when the mode changes (see `ContentView`).
        .id(showsTabRows)
        .navigationTitle(machine.displayName)
        // The last known list stays on screen while the connection is down
        // (see `MachineMonitor`), so a failure can't be drawn in the list's
        // own place: over rows it would print across them. With rows to
        // show it goes above them instead, and takes the list's place only
        // when the list has none.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let loadError, !agents.isEmpty {
                failureBanner(loadError)
            }
        }
        // Above everything else in the sidebar, the failure banner included.
        // A bar rather than a plain inset, so that the list gets the
        // system's scroll edge effect where it runs under the glass.
        .safeAreaBar(edge: .top, spacing: 0) {
            searchBar
        }
        // Below the list rather than in it, so that it stays put however
        // far the list is scrolled.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if Self.offersTabs {
                tabModeBar
            }
        }
        .overlay {
            // Grouped, the host's group says this in its own place instead
            // (see `hostGroupStatus`) and the machines' groups stay usable.
            if herdrMachineGroups.isEmpty && agents.isEmpty {
                if let loadError {
                    ContentUnavailableView {
                        Label("Connection Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError + "\n\n" + retryStatus)
                    } actions: {
                        Button("Retry", action: retry)
                    }
                } else if hasLoadedAgents {
                    ContentUnavailableView(
                        "No Panes",
                        systemImage: "terminal",
                        description: Text("The panes open in herdr on this machine, and the agents in them, appear here.")
                    )
                } else {
                    ProgressView("Loading panes…")
                }
            } else if isSearching && !hasVisibleRows {
                ContentUnavailableView.search(text: searchText)
            }
        }
        // The machine's monitor runs for as long as the board is on screen
        // — and, while the notifications watch the machine, longer. The
        // board looks after its machine through every retry and refresh,
        // which go to the monitor rather than restarting this.
        .task(id: machine.connectionIdentity) {
            await MachineMonitors.shared.holdForBoard(machine, in: machineStore)
        }
        // Every snapshot the monitor reads, and every round over the herdr
        // machines, brings the selection up to date with it — and the
        // browsers, with the panes that are left.
        .onChange(of: monitor.snapshotCount, initial: true) {
            showSnapshot()
        }
        .onChange(of: monitor.herdrMachineRoundCount, initial: true) {
            showHerdrMachines()
        }
        // Started over only when the request changes — the selection moving
        // to another tab, its agent finishing or being seen, the window
        // becoming key or ceasing to be. A refresh that leaves it as it was
        // leaves the task alone, so a request is sent once, and one that
        // changes before it is sent is never sent.
        .task(id: seenRequestNow) { [request = seenRequestNow] in
            await markSeen(request)
        }
        // A name typed into the window's title goes to herdr from here, where
        // the close and its failures go from too.
        .onChange(of: renameCommit?.id) {
            if let commit = renameCommit, commit.readsSinceSent == nil {
                rename(commit)
            }
        }
        .confirmationDialog(closeTitle, isPresented: isClosing, titleVisibility: .visible, presenting: closing) { item in
            switch item {
            case .tab:
                Button("Close Tab", role: .destructive) { close(item) }
            case .pane:
                Button("Close Pane", role: .destructive) { close(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            switch item {
            case .tab:
                Text("Every pane in the tab is closed, and whatever runs in them — agents included — is ended.")
            case .pane:
                Text("Whatever runs in the pane — an agent included — is ended.")
            }
        }
        .alert(actionFailure?.title ?? "", isPresented: isShowingActionFailure, presenting: actionFailure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .onChange(of: launchTargetsNow, initial: true) { _, targets in
            guard machineStore.isCurrentConnection(machine),
                  machineStore.activeMachine?.connectionIdentity == machine.connectionIdentity else { return }
            launchTargets = targets
        }
        .onChange(of: navigationDestinationsNow, initial: true) { _, destinations in
            guard machineStore.isCurrentConnection(machine),
                  machineStore.activeMachine?.connectionIdentity == machine.connectionIdentity else { return }
            onNavigationDestinations(destinations)
        }
        .onChange(of: refreshRequests) {
            monitor.refreshNow()
        }
        .onChange(of: closeRequests) {
            guard renaming == nil, closing == nil, actionFailure == nil else { return }
            closing = selection
        }
    }

    private var navigationDestinationsNow: [PaneDestination] {
        func destinations(_ panes: [AgentSummary], _ tabs: [TabSummary]?, _ workspaces: [WorkspaceSummary]?, label: String, available: Bool) -> [PaneDestination] {
            panes.map { pane in
                let tab = showsTabRows ? tabs?.first(where: { $0.panes.contains(where: { $0.id == pane.id && $0.terminalID == pane.terminalID }) }) : nil
                let workspace = workspaces?.first { $0.workspaceID == pane.workspaceID }?.label
                return PaneDestination(pane: pane, item: tab.map(BoardItem.tab) ?? .pane(pane),
                    location: ([label] + [workspace, tab?.title].compactMap { $0 }).joined(separator: " · "), isAvailable: available)
            }
        }
        return destinations(agents, tabs, workspaces, label: machine.displayName, available: hasLoadedAgents && loadError == nil)
            + herdrMachineGroups.flatMap { destinations($0.agents, $0.tabs, $0.workspaces, label: $0.machine.label, available: $0.hasLoaded && $0.error == nil) }
    }

    /// The failure, in the little room there is above a list that is still
    /// being shown. The message is not cut short: for the failures that stop
    /// the board from reconnecting (a rejected credential, a host key that
    /// changed) it is all the person has to go on, and there is nowhere else
    /// to read the rest of it.
    private func failureBanner(_ message: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Failed")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(retryStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
        }
        // Sideways only. A background reaches into every safe area unless
        // told otherwise, and upwards that is the navigation bar: the
        // material would lie over the machine's name.
        .background(.bar, ignoresSafeAreaEdges: .horizontal)
    }

    /// While the list is narrowed down — by the search, the workspace
    /// filter or both — a group shows only the rows that are left, unfolded
    /// whether or not the person folded it (without changing that), and a
    /// group with none to show is left out altogether, notes included.
    /// While a group's header is being dragged, every group shows its header
    /// alone (see `BoardGroupFolding`).
    @ViewBuilder
    private var agentList: some View {
        if herdrMachineGroups.isEmpty {
            List(selection: selectionID) {
                rows(visibleRows(of: .host))
            }
        } else {
            let listed = boardGroups
                .map { ListedGroup(group: $0, rows: visibleRows(of: $0)) }
                .filter { !isFiltering || $0.rows.count > 0 }
            let shownGroupIDs = listed.map(\.id)
            List(selection: selectionID) {
                ForEach(listed) { item in
                    switch item.group {
                    case .host:
                        hostSection(item.rows, among: shownGroupIDs)
                    case .herdrMachine(let group):
                        herdrMachineSection(group, rows: item.rows, among: shownGroupIDs)
                    }
                }
            }
            .boardGroupInsertionLine(groupDrag)
        }
    }

    private func hostSection(_ hostRows: HerdrRows, among shownGroupIDs: [String]) -> some View {
        Section {
            if listsRows(of: Self.hostGroupID) {
                if !isFiltering {
                    hostGroupStatus
                }
                rows(hostRows)
            }
        } header: {
            groupHeader(machine.displayName, panes: agents, rowCount: hostRows.count, groupID: Self.hostGroupID, among: shownGroupIDs)
                .contextMenu {
                    Button("Add herdr Machine…") { onHerdrMachineSetup(.add) }
                        .disabled(!monitor.canManageHerdrMachines)
                }
        }
    }

    private func herdrMachineSection(_ group: MachineMonitor.HerdrMachineGroup, rows groupRows: HerdrRows, among shownGroupIDs: [String]) -> some View {
        Section {
            if listsRows(of: group.id) {
                if !isFiltering {
                    if let error = group.error {
                        groupNote(error, systemImage: "exclamationmark.triangle")
                    } else if !group.hasLoaded {
                        groupNote(String(localized: "Loading panes…"), systemImage: "hourglass")
                    } else if group.agents.isEmpty {
                        groupNote(String(localized: "No Panes"), systemImage: "terminal")
                    }
                }
                rows(groupRows)
            }
        } header: {
            groupHeader(group.machine.label, panes: group.agents, rowCount: groupRows.count, groupID: group.id, among: shownGroupIDs)
                .contextMenu {
                    // Checking it again is for a machine herdr can't reach
                    // now.
                    if group.error != nil {
                        Button("Reconnect…") { onHerdrMachineSetup(.reconnect(group.machine)) }
                            .disabled(!monitor.canManageHerdrMachines)
                    }
                    Button("Remove \u{201C}\(group.machine.label)\u{201D}…") { removing = group.machine }
                        .disabled(!monitor.canManageHerdrMachines)
                }
        }
    }

    /// One group of the board: the host's own herdr's, or a herdr machine's.
    private enum BoardGroup: Identifiable {
        case host
        case herdrMachine(MachineMonitor.HerdrMachineGroup)

        var id: String {
            switch self {
            case .host: AgentBoardView.hostGroupID
            case .herdrMachine(let group): group.id
            }
        }
    }

    /// A group as the list shows it, with the rows the search and the
    /// workspace filter leave it.
    private struct ListedGroup: Identifiable {
        let group: BoardGroup
        let rows: HerdrRows
        var id: String { group.id }
    }

    /// The board's groups — the host's own first, then the herdr machines
    /// as herdr lists them — in the order the person has dragged them into.
    private var boardGroups: [BoardGroup] {
        BoardGroupOrder.ordered(
            [.host] + herdrMachineGroups.map(BoardGroup.herdrMachine),
            by: \.id,
            saved: BoardGroupOrder.ids(groupOrderIDs)
        )
    }

    private func visibleRows(of group: BoardGroup) -> HerdrRows {
        switch group {
        case .host:
            visibleRows(panes: agents, tabs: tabs, workspaces: workspaces, herdrMachine: nil, machineLabel: machine.displayName)
        case .herdrMachine(let group):
            visibleRows(panes: group.agents, tabs: group.tabs, workspaces: group.workspaces, herdrMachine: group.machine, machineLabel: group.machine.label)
        }
    }

    /// Moves the group whose header was let go into `gap` among the groups
    /// shown, and keeps the order — of the groups there are now, so that
    /// one gone since is left out of it.
    private func moveGroup(_ groupID: String, toGap gap: Int, among shownGroupIDs: [String]) {
        guard let order = BoardGroupOrder.moving(groupID, toGap: gap, among: shownGroupIDs, in: boardGroups.map(\.id)) else { return }
        groupOrderIDs = BoardGroupOrder.stored(order)
    }

    /// One herdr's part of the board — the host's or a herdr machine's —
    /// as the search and the workspace filter leave it.
    private struct HerdrRows {
        let panes: [AgentSummary]
        let tabs: [TabSummary]?
        let workspaces: [WorkspaceSummary]?
        /// Whether its rows are tabs rather than panes.
        let listsTabs: Bool

        /// How many rows it lists.
        var count: Int {
            listsTabs ? (tabs?.count ?? 0) : panes.count
        }
    }

    /// The words typed into the search field. A row is listed while there
    /// are any only if each of them is in one of its texts (see
    /// `searchTexts(for:)`), so that more words narrow the list down.
    private var searchTerms: [String] {
        searchText.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var isSearching: Bool {
        !searchTerms.isEmpty
    }

    /// Whether the list is narrowed down at all.
    private var isFiltering: Bool {
        isSearching || !activeWorkspaceFilter.isEmpty
    }

    /// Whether the search and the workspace filter leave any row on the
    /// board at all.
    private var hasVisibleRows: Bool {
        visibleRows(panes: agents, tabs: tabs, workspaces: workspaces, herdrMachine: nil, machineLabel: machine.displayName).count > 0
            || herdrMachineGroups.contains { group in
                visibleRows(panes: group.agents, tabs: group.tabs, workspaces: group.workspaces, herdrMachine: group.machine, machineLabel: group.machine.label).count > 0
            }
    }

    /// One herdr's rows, narrowed down to those in the workspaces the filter
    /// picks and that the search matches. Besides what a row shows, the
    /// search matches the names of its workspace and of its machine, so that
    /// one of those typed in lists everything in it.
    private func visibleRows(
        panes: [AgentSummary],
        tabs: [TabSummary]?,
        workspaces: [WorkspaceSummary]?,
        herdrMachine: HerdrMachine?,
        machineLabel: String
    ) -> HerdrRows {
        let listsTabs = showsTabRows && tabs != nil
        guard isFiltering else {
            return HerdrRows(panes: panes, tabs: tabs, workspaces: workspaces, listsTabs: listsTabs)
        }
        let pickedWorkspaces = activeWorkspaceFilter
        func isPicked(_ workspaceID: String?) -> Bool {
            guard !pickedWorkspaces.isEmpty else { return true }
            guard let workspaceID else { return false }
            return pickedWorkspaces.contains(workspaceFilterKey(workspaceID, on: herdrMachine))
        }
        let workspaceLabels = Dictionary(
            (workspaces ?? []).map { ($0.workspaceID, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        func containers(_ workspaceID: String?) -> [String] {
            [machineLabel] + [workspaceID.flatMap { workspaceLabels[$0] }].compactMap { $0 }
        }
        return HerdrRows(
            panes: panes.filter { pane in
                isPicked(pane.workspaceID) && matchesSearch(searchTexts(for: pane) + containers(pane.workspaceID))
            },
            tabs: tabs?.filter { tab in
                isPicked(tab.workspaceID) && matchesSearch(searchTexts(for: tab) + containers(tab.workspaceID))
            },
            workspaces: workspaces,
            listsTabs: listsTabs
        )
    }

    /// A workspace's key in `workspaceFilter`: its ID, qualified by the
    /// herdr machine it is on, since every herdr numbers its own.
    private func workspaceFilterKey(_ workspaceID: String, on herdrMachine: HerdrMachine?) -> String {
        herdrMachine.map { "\($0.id)/\(workspaceID)" } ?? workspaceID
    }

    /// The picked workspaces that are still there. One that has been closed
    /// since it was picked no longer counts — and isn't in the menu to be
    /// unpicked — so with only such left, nothing is filtered by workspace,
    /// rather than everything.
    private var activeWorkspaceFilter: Set<String> {
        guard !workspaceFilter.isEmpty else { return [] }
        var present: Set<String> = []
        for workspace in workspaces ?? [] {
            present.insert(workspaceFilterKey(workspace.workspaceID, on: nil))
        }
        for group in herdrMachineGroups {
            for workspace in group.workspaces ?? [] {
                present.insert(workspaceFilterKey(workspace.workspaceID, on: group.machine))
            }
        }
        return workspaceFilter.intersection(present)
    }

    private func matchesSearch(_ texts: [String]) -> Bool {
        searchTerms.allSatisfy { term in
            texts.contains { $0.localizedStandardContains(term) }
        }
    }

    /// What a pane's row shows: its title, the line under it, and its
    /// agent's status as it reads on screen — so that a status typed in, in
    /// the app's language, lists the panes in that state.
    private func searchTexts(for pane: AgentSummary) -> [String] {
        [pane.title, subtitle(for: pane)] + (pane.hasAgent ? [String(localized: pane.state.title)] : [])
    }

    /// What a tab's row shows, and what the rows of the panes in it would.
    private func searchTexts(for tab: TabSummary) -> [String] {
        [tab.title]
            + (tab.mostUrgentState.map { [String(localized: $0.title)] } ?? [])
            + tab.panes.flatMap(searchTexts(for:))
    }

    /// The tab rows take the pane rows' place when the board shows tabs —
    /// for each herdr that can report them; one too old to keeps listing its
    /// panes.
    private var showsTabRows: Bool {
        showsTabs && Self.offersTabs
    }

    /// One herdr's rows: its tabs or its panes, by status (see `BoardOrder`)
    /// — listed workspace by workspace, under each one's name, when herdr
    /// reports its workspaces.
    @ViewBuilder
    private func rows(_ herdrRows: HerdrRows) -> some View {
        let panes = herdrRows.panes
        let tabs = herdrRows.tabs
        if let workspaces = herdrRows.workspaces {
            ForEach(workspaces) { workspace in
                let workspacePanes = panes.filter { $0.workspaceID == workspace.workspaceID }
                let workspaceTabs = tabs?.filter { $0.workspaceID == workspace.workspaceID }
                // A workspace with nothing to list lists nothing, not even
                // its name: one the search leaves no row in, or — for the
                // moment a refresh is half through — one with no panes yet.
                let isEmpty = herdrRows.listsTabs ? (workspaceTabs ?? []).isEmpty : workspacePanes.isEmpty
                if !isEmpty {
                    workspaceLabel(workspace.label)
                    rowsOfOneWorkspace(panes: workspacePanes, tabs: workspaceTabs)
                }
            }
            // A pane from a workspace that isn't listed — opened between the
            // two lists being read — goes at the end, rather than nowhere.
            let listed = Set(workspaces.map(\.workspaceID))
            rowsOfOneWorkspace(
                panes: panes.filter { !listed.contains($0.workspaceID ?? "") },
                tabs: tabs?.filter { !listed.contains($0.workspaceID ?? "") }
            )
        } else {
            rowsOfOneWorkspace(panes: panes, tabs: tabs)
        }
    }

    @ViewBuilder
    private func rowsOfOneWorkspace(panes: [AgentSummary], tabs: [TabSummary]?) -> some View {
        if showsTabRows, let tabs {
            ForEach(BoardOrder.tabs(tabs)) { tab in
                row(for: tab)
            }
        } else {
            ForEach(BoardOrder.panes(panes)) { agent in
                row(for: agent)
            }
        }
    }

    /// The name of the workspace the rows under it are in. Only a label:
    /// it can't be selected, and has no fold of its own — the group it is
    /// in folds with it.
    private func workspaceLabel(_ label: String) -> some View {
        Text(verbatim: label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 4)
            .selectionDisabled()
            .accessibilityAddTraits(.isHeader)
    }

    /// The search field over the list — with the workspace filter at its
    /// end — on a capsule of Liquid Glass that the list scrolls under.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $searchText)
                .textFieldStyle(.plain)
                #if os(macOS)
                .onExitCommand { searchText = "" }
                #endif
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Clear"))
            }
            workspaceFilterMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Picks the workspaces the list is narrowed down to, any number of
    /// them, each machine's under its name. Filled in while it narrows the
    /// list, so that it is clear rows are being left out.
    private var workspaceFilterMenu: some View {
        let isActive = !activeWorkspaceFilter.isEmpty
        return Menu {
            Button("All Workspaces") {
                workspaceFilter = []
            }
            .disabled(!isActive)
            Divider()
            if herdrMachineGroups.isEmpty {
                workspaceToggles(workspaces ?? [], on: nil)
            } else {
                Section(machine.displayName) {
                    workspaceToggles(workspaces ?? [], on: nil)
                }
                ForEach(herdrMachineGroups) { group in
                    Section(group.machine.label) {
                        workspaceToggles(group.workspaces ?? [], on: group.machine)
                    }
                }
            }
        } label: {
            Image(systemName: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by Workspace")
        .accessibilityLabel(Text("Filter by Workspace"))
    }

    private func workspaceToggles(_ workspaces: [WorkspaceSummary], on herdrMachine: HerdrMachine?) -> some View {
        ForEach(workspaces) { workspace in
            let key = workspaceFilterKey(workspace.workspaceID, on: herdrMachine)
            Toggle(isOn: Binding(
                get: { workspaceFilter.contains(key) },
                set: { picked in
                    if picked {
                        workspaceFilter.insert(key)
                    } else {
                        workspaceFilter.remove(key)
                    }
                }
            )) {
                Text(verbatim: workspace.label)
            }
        }
    }

    /// The setting for the board's mode, kept clear of the list.
    private var tabModeBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Group by Tab")
                Spacer()
                Toggle("Group by Tab", isOn: $showsTabs)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // Not upwards, where it would lie over the list's last row.
        .background(.bar, ignoresSafeAreaEdges: [.horizontal, .bottom])
        .help("Show each tab as one row, and all of its panes at once when it is selected.")
    }

    /// A pane's row. One with an agent shows the agent's status, as a dot
    /// and in words; one without has no status to show — herdr reports
    /// `unknown` for every such pane — so it is marked as a plain terminal
    /// instead, and says where it is rather than which agent runs in it.
    private func row(for agent: AgentSummary) -> some View {
        HStack {
            statusIndicator(agent.hasAgent ? agent.state : nil)
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(agent.title).font(.body)
                    #if os(macOS)
                    if ShepherdBrowserFeature.shared.isEnabled {
                        let browserStatus = AgentLaunchService.shared.status(for: agent, on: machine)
                        if agent.hasAgent || agent.launchPending == true || browserStatus != .shell {
                            AgentBrowserStatusBadge(status: browserStatus,
                                failure: AgentLaunchService.shared.failure(for: agent, on: machine))
                        }
                    }
                    #endif
                }
                AgentPaneCaption(subtitle(for: agent), agentName: agent.agentName)
            }
            Spacer()
            if agent.hasAgent {
                Text(agent.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .padding(.trailing, Self.rowTrailingPadding)
        #endif
        .contextMenu {
            Button("Rename Pane…") { beginRenaming(.pane(agent)) }
            #if os(macOS)
            if ShepherdBrowserFeature.shared.isEnabled && agent.hasAgent {
                Button("Resume with In-app Browser") {
                    Task {
                        do {
                            let client = HerdrClient(transport: try machineStore.makeHerdrTransport(for: machine))
                            do { try await client.connect(); try await AgentLaunchService.shared.resume(agent, on: machine, client: client); await client.disconnect() }
                            catch { await client.disconnect(); throw error }
                        } catch { actionFailure = ActionFailure(title: String(localized: "Could not resume agent"), message: connectionFailureDescription(error)) }
                    }
                }
                .disabled(!AgentLaunchService.shared.canResume(agent, on: machine))
            }
            #endif
            Divider()
            Button("Close Pane", role: .destructive) { closing = .pane(agent) }
        }
        // Dropped on a terminal, the pane's ID is pasted there.
        .herdrItemDrag(HerdrItemDrag.Item(pane: agent, on: machine.connectionIdentity))
    }

    /// A tab's row: name and actionable browser statuses only, without pane
    /// counts or repeated unknown browser captions. Agent urgency stays intact.
    private func row(for tab: TabSummary) -> some View {
        HStack {
            statusIndicator(tab.mostUrgentState)
            VStack(alignment: .leading) {
                Text(tab.title).font(.body)
                #if os(macOS)
                if ShepherdBrowserFeature.shared.isEnabled {
                    ForEach(tab.panes) { pane in
                        let browserStatus = AgentLaunchService.shared.status(for: pane, on: machine)
                        if let title = AgentBrowserStatusDisplay.tabTitle(for: browserStatus) {
                            Text(title).font(.caption).foregroundStyle(.secondary).help(pane.title)
                        }
                    }
                }
                #endif
            }
            Spacer()
            if let state = tab.mostUrgentState {
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .padding(.trailing, Self.rowTrailingPadding)
        #endif
        .contextMenu {
            Button("Rename Tab…") { beginRenaming(.tab(tab)) }
            Divider()
            Button("Close Tab", role: .destructive) { closing = .tab(tab) }
        }
        // Dropped on a terminal, the tab's ID is pasted there.
        .herdrItemDrag(HerdrItemDrag.Item(tab: tab, on: machine.connectionIdentity))
    }

    /// A status dot, or — with no agent's status to show — the mark of a
    /// plain terminal.
    private func statusIndicator(_ state: AgentState?) -> some View {
        Group {
            if let state {
                Circle()
                    .fill(Self.color(for: state))
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // As wide as the dot either way, so that every row's title starts
        // at the same place.
        .frame(width: 10)
    }

    /// Which agent runs in the pane, or — for a pane with none — the folder
    /// it is in, which tells two shells apart where their titles often
    /// don't. The row shows Claude's and Pi's marks in place of their names
    /// (`AgentPaneCaption`); a search goes by the words all the same.
    private func subtitle(for agent: AgentSummary) -> String {
        if agent.hasAgent {
            return agent.agentName ?? agent.source ?? agent.paneID
        }
        return agent.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? agent.paneID
    }

    #if os(macOS)
    /// Room between a row's status and the sidebar's right edge, on top of
    /// what the list leaves there itself. That alone puts the status about
    /// as close to the edge as the dot is to the left one, and the right
    /// edge — the rounded rim of the sidebar, and where the scroller appears
    /// — needs more room than that to not look crowded.
    private static let rowTrailingPadding: CGFloat = 6

    /// Room between a group header's count and the sidebar's right edge.
    /// The list insets its rows' content from that edge (the selection
    /// highlight's margin and padding, 14 points together), but not a
    /// section header's, which reaches all the way to it: this makes up the
    /// difference, so the count lines up with the statuses below it.
    private static let headerTrailingPadding: CGFloat = 14 + rowTrailingPadding
    #endif

    /// A group's name and how many rows it has — and, because a folded
    /// group hides its rows, a dot when an agent in one of them is waiting
    /// on the person, which is the one thing nobody wants folded out of
    /// sight.
    ///
    /// The whole header folds and unfolds the group, with its chevron always
    /// showing. The list's own collapsible sections only offer a chevron
    /// that appears while the pointer is over the header, on macOS, and only
    /// in the sidebar list style on iOS — easy to miss, and different on
    /// each platform.
    /// `rowCount` is how many rows the group lists; `panes` are all of its
    /// panes, the ones the search leaves out included — a blocked agent is
    /// marked whatever is listed.
    ///
    /// Dragged, the header takes its group to another place among the groups
    /// `shownGroupIDs` (see `BoardGroupDrag`).
    private func groupHeader(_ title: String, panes: [AgentSummary], rowCount: Int, groupID: String, among shownGroupIDs: [String]) -> some View {
        let expanded = BoardGroupFolding.looksExpanded(isCollapsed: isCollapsed(groupID), isFoldedForDrag: groupDrag.foldsRows(of: groupID))
        return Button {
            guard let collapsed = BoardGroupFolding.toggling(groupID, in: collapsedGroupIDs, isFoldingForDrag: groupDrag.isFolding) else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                collapsedGroupIDs = collapsed
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title)
                if panes.contains(where: { $0.state == .blocked }) {
                    Circle()
                        .fill(Self.color(for: .blocked))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(Text(AgentState.blocked.title))
                }
                Spacer()
                Text(rowCount, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            #if os(macOS)
            .padding(.trailing, Self.headerTrailingPadding)
            #endif
            // On the label, not the Button: a plain-style button hit-tests
            // its label's content, which would leave the Spacer's stretch of
            // the header dead to clicks.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
        .boardGroupDrag(groupID, drag: groupDrag, among: shownGroupIDs) { gap in
            moveGroup(groupID, toGap: gap, among: shownGroupIDs)
        }
    }

    /// A line in a group that isn't an agent: its loading state, an empty
    /// result, or why it couldn't be reached. Not selectable — it carries no
    /// tag the list's selection could take.
    private func groupNote(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The host's own loading, empty and failure states, for when it is one
    /// group among others and the full-size placeholder (see `body`) would
    /// cover them all. A failure with rows still showing is the banner's.
    @ViewBuilder
    private var hostGroupStatus: some View {
        if agents.isEmpty {
            if let loadError {
                groupNote(loadError, systemImage: "exclamationmark.triangle")
            } else if hasLoadedAgents {
                groupNote(String(localized: "No Panes"), systemImage: "terminal")
            } else {
                groupNote(String(localized: "Loading panes…"), systemImage: "hourglass")
            }
        }
    }

    /// Whether the person has folded the group away.
    private func isCollapsed(_ groupID: String) -> Bool {
        BoardGroupFolding.isCollapsed(groupID, in: collapsedGroupIDs)
    }

    /// Whether the group lists its rows now (see `BoardGroupFolding`).
    private func listsRows(of groupID: String) -> Bool {
        BoardGroupFolding.listsRows(isCollapsed: isCollapsed(groupID), isFiltering: isFiltering, isFoldedForDrag: groupDrag.foldsRows(of: groupID))
    }

    private var retryStatus: String {
        isRetrying
            ? String(localized: "Trying again automatically.")
            : String(localized: "Not trying again until you press Retry.")
    }

    /// Has the monitor start over with a new connection. That is all it
    /// takes in either case a failure leaves behind: the monitor sitting out
    /// the wait before its next attempt, or having stopped because the
    /// failure was one that no further attempt of its own could get past.
    private func retry() {
        monitor.retry()
    }

    /// A rename or close that didn't go through: which of the two, and what
    /// herdr — or the connection to it — said.
    private struct ActionFailure {
        let title: String
        let message: String
    }

    /// Has the name of `item` typed into the window's title. The title is
    /// the selected item's, so `item` is selected first if it isn't — as a
    /// click on its row would select it.
    private func beginRenaming(_ item: BoardItem) {
        if selection?.id != item.id {
            justCreatedID = nil
            selection = item
        }
        renaming = TitleRenameSession(item: item)
    }

    /// Sends a name typed into the window's title, which shows it from now
    /// until herdr reports it (see `settleRenameCommit`) — or, if it doesn't
    /// go through, goes back to the name herdr has.
    private func rename(_ commit: TitleRenameCommit) {
        perform(failureTitle: String(localized: "Couldn't Rename"), succeeded: {
            if renameCommit?.id == commit.id { renameCommit?.readsSinceSent = 0 }
            nameAgentSession(after: commit)
        }, failed: {
            if renameCommit?.id == commit.id { renameCommit = nil }
        }) { client in
            switch commit.item {
            case .tab(let tab):
                try await client.renameTab(tab.tabID, to: commit.name, on: tab.herdrMachine)
            case .pane(let pane):
                try await client.renamePane(pane.paneID, to: commit.name.isEmpty ? nil : commit.name, on: pane.herdrMachine)
            }
        }
    }

    /// Passes a pane's new name on, once, to the session of the agent in it
    /// (`AgentSessionNaming`): to Claude Code or Codex as its `/rename`, when
    /// a snapshot shows it ready for it, and to a Pi this app launched through
    /// its extension. Nothing for a tab, a name taken away, or a pane with no
    /// agent in it.
    private func nameAgentSession(after commit: TitleRenameCommit) {
        guard let rename = AgentSessionNaming.rename(after: commit, machineID: machine.id) else { return }
        guard rename.kind == .pi else {
            AgentSessionNamer.shared.add(rename)
            return
        }
        #if os(macOS)
        if case .pane(let pane) = commit.item {
            AgentLaunchService.shared.namePiSession(rename.name, pane: pane, on: machine)
        }
        #endif
    }

    /// A connection of its own for `AgentSessionNamer`, made the way
    /// `perform` makes one.
    private static func namingConnection(_ machineStore: MachineStore, _ machine: Machine) throws -> HerdrClient {
        guard machineStore.isCurrentConnection(machine) else { throw MachineStore.EditError.settingsChanged }
        return HerdrClient(transport: try machineStore.makeHerdrTransport(for: try machineStore.currentMachine(matching: machine)))
    }

    /// Counts a read of the herdr `renameCommit`'s item is on — the host's
    /// own, or the herdr machine with the ID given — and lets the commit go
    /// once that read ends it (see `TitleRenameCommit.afterRead(of:)`).
    private func settleRenameCommit(onHerdrMachine herdrMachineID: String?, panes: [AgentSummary], tabs: [TabSummary]?) {
        guard let commit = renameCommit, commit.item.herdrMachine?.id == herdrMachineID else { return }
        let current: BoardItem? = switch commit.item {
        case .pane(let pane): panes.first { $0.id == pane.id }.map(BoardItem.pane)
        case .tab(let tab): tabs?.first { $0.id == tab.id }.map(BoardItem.tab)
        }
        let next = commit.afterRead(of: current)
        if next != commit {
            renameCommit = next
        }
    }

    private func close(_ item: BoardItem) {
        perform(failureTitle: String(localized: "Couldn't Close")) { client in
            switch item {
            case .tab(let tab):
                try await client.closeTab(tab.tabID, on: tab.herdrMachine)
            case .pane(let pane):
                try await client.closePane(pane.paneID, on: pane.herdrMachine)
            }
        }
    }

    /// Removes a herdr machine from the host's herdr, which forgets it and
    /// stops connecting to it; nothing on the machine is touched. The board
    /// reads its herdr machines again straight away, and the machine's
    /// group goes.
    private func remove(_ herdrMachine: HerdrMachine) {
        perform(failureTitle: String(localized: "Couldn't Remove")) { client in
            try await HerdrMachineRemoval.remove(herdrMachine, using: HerdrClientStepRunner(client: client))
        }
    }

    private var removeTitle: Text {
        Text("Remove \u{201C}\(removing?.label ?? "")\u{201D} from herdr on \(machine.displayName)?")
    }

    /// What removing a herdr machine does, and what it leaves alone.
    private var removeMessage: String {
        var lines = [String(localized: "herdr forgets the machine and stops connecting to it. Its sessions keep running there, and the agents in them.")]
        #if os(macOS)
        if ShepherdBrowserFeature.shared.isEnabled {
            lines.append(String(localized: "The In-app Browsers of its panes close, and their profiles are deleted."))
        }
        #endif
        lines.append(String(localized: "Its host key stays in known_hosts."))
        return lines.joined(separator: " ")
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private var closeTitle: Text {
        switch closing {
        case .tab(let tab): Text("Close \u{201C}\(tab.title)\u{201D}?")
        case .pane(let pane): Text("Close \u{201C}\(pane.title)\u{201D}?")
        case nil: Text(verbatim: "")
        }
    }

    /// Sends a change to herdr over a connection of its own, and then has
    /// the monitor read everything again, so the change shows at once even
    /// where herdr reports no event for it (a pane renamed, a change on a
    /// herdr machine). A change to a pane or tab on a herdr machine goes
    /// through the host, as every request to one does. `succeeded` is told
    /// before that read is asked for, `failed` before the failure is shown.
    private func perform(
        failureTitle: String,
        succeeded: @escaping () -> Void = {},
        failed: @escaping () -> Void = {},
        _ change: @escaping (HerdrClient) async throws -> Void
    ) {
        Task {
            do {
                let current = try machineStore.currentMachine(matching: machine)
                let client = HerdrClient(transport: try machineStore.makeHerdrTransport(for: current))
                do {
                    try await client.connect()
                    guard machineStore.isCurrentConnection(machine) else { throw MachineStore.EditError.settingsChanged }
                    try await change(client)
                } catch {
                    await client.disconnect()
                    throw error
                }
                await client.disconnect()
                succeeded()
                monitor.refreshNow()
            } catch {
                failed()
                actionFailure = ActionFailure(title: failureTitle, message: connectionFailureDescription(error))
            }
        }
    }

    /// The tab herdr is to be told has been seen, given what is selected
    /// and whether the window is key — nil for none (see `SeenMarking`).
    /// The selection is kept in step with every refresh (see `reselect`), so
    /// this changes when the selected agent finishes, as well as when the
    /// selection does.
    private var seenRequestNow: SeenRequest? {
        let windowIsKey = controlActiveState == .key
        switch selection {
        case .pane(let pane): return SeenMarking.request(forPane: pane, windowIsKey: windowIsKey)
        case .tab(let tab): return SeenMarking.request(forTab: tab, windowIsKey: windowIsKey)
        case nil: return nil
        }
    }

    /// Tells herdr the tab in `request` has been seen, once it has stayed
    /// the request for `seenDelay`, over a connection of its own like
    /// `perform`'s changes. Unlike those, a failure is dropped without a
    /// word: the row stays Done, as it did before there was this. Nor does
    /// the board ask for everything to be read again after it: herdr reports
    /// the agent going idle, and the snapshot the monitor reads for that
    /// shows it.
    private func markSeen(_ request: SeenRequest?) async {
        guard let request, (try? await Task.sleep(for: Self.seenDelay)) != nil,
              machineStore.isCurrentConnection(machine),
              let current = try? machineStore.currentMachine(matching: machine),
              let transport = try? machineStore.makeHerdrTransport(for: current) else { return }
        let client = HerdrClient(transport: transport)
        // As in `MachineMonitor`: closing the connection is what ends an
        // await the cancellation doesn't reach, and a connection still being
        // made when the task is cancelled is closed once it is made.
        await withTaskCancellationHandler {
            do {
                try await client.connect()
                try Task.checkCancellation()
                if machineStore.isCurrentConnection(machine) {
                    try await client.focusTab(request.tabID, on: request.herdrMachine)
                }
            } catch {}
            await client.disconnect()
        } onCancel: {
            Task { await client.disconnect() }
        }
    }

    private var isClosing: Binding<Bool> {
        Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })
    }

    private var isShowingActionFailure: Binding<Bool> {
        Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })
    }

    /// The list selects by row ID — `AgentSummary.id` or `TabSummary.id`,
    /// qualified by the herdr machine — rather than by value: a row's state,
    /// title and revision change on every refresh, and a selection keyed on
    /// the whole value would stop matching its row (and lose its highlight)
    /// the moment any of them did. Rows are identified by that same id, so
    /// no explicit tag is needed.
    private var selectionID: Binding<String?> {
        Binding(
            get: { selection?.id },
            set: { id in
                justCreatedID = nil
                selection = id.flatMap { id in
                    let tabs = (tabs ?? []) + herdrMachineGroups.flatMap { $0.tabs ?? [] }
                    if let tab = tabs.first(where: { $0.id == id }) {
                        return .tab(tab)
                    }
                    let panes = agents + herdrMachineGroups.flatMap(\.agents)
                    return panes.first { $0.id == id }.map(BoardItem.pane)
                }
            }
        )
    }

    /// Takes in a fresh round from the herdr machines, and keeps a selection
    /// on one of them in step the way `showSnapshot` does for the host's:
    /// re-pointed at the new snapshot of its pane or tab, dropped once that
    /// — or the whole machine — is gone. Not while its machine can't be
    /// reached, though: that says nothing about whether the pane or tab is
    /// still there.
    private func showHerdrMachines() {
        guard monitor.herdrMachineRoundCount > 0, machineStore.isCurrentConnection(machine) else { return }
        let groups = herdrMachineGroups
        #if os(macOS)
        // As in `showSnapshot`, for each machine whose panes were listed
        // this time.
        // One that couldn't be reached says nothing about its panes.
        let browsers = BrowserStore.shared
        browsers.reconcile(machineID: machine.id, herdrMachines: Set(groups.map(\.id)))
        for group in groups where group.error == nil && group.hasLoaded {
            browsers.reconcile(machineID: machine.id, herdrMachineID: group.id, panes: group.agents)
        }
        #endif
        // A name typed into the window's title for a pane or tab on one of
        // them, by what this round read of its machine, if it read it.
        if let id = renameCommit?.item.herdrMachine?.id {
            if let group = groups.first(where: { $0.id == id }) {
                if group.error == nil && group.hasLoaded {
                    settleRenameCommit(onHerdrMachine: id, panes: group.agents, tabs: group.tabs)
                }
            } else {
                settleRenameCommit(onHerdrMachine: id, panes: [], tabs: [])
            }
        }
        // Names waiting for the sessions of agents on them, as for the host's.
        let namer = AgentSessionNamer.shared
        namer.keep(herdrMachineIDs: Set(groups.map(\.id)), machineID: machine.id)
        for group in groups where group.error == nil && group.hasLoaded {
            namer.observe(group.agents, machineID: machine.id, herdrMachineID: group.id) { [machineStore, machine] in
                try Self.namingConnection(machineStore, machine)
            }
        }
        guard let selected = selection, let machine = selected.herdrMachine else { return }
        guard let group = groups.first(where: { $0.id == machine.id }) else {
            selection = nil
            return
        }
        guard group.error == nil else { return }
        reselect(selected, in: group.agents, tabs: group.tabs)
    }

    /// Takes in the snapshot the monitor has just read, and keeps the
    /// selection in step with it: the selection is a snapshot of its own, so
    /// it is re-pointed at the new snapshot of the same pane or tab (the
    /// detail column's title, and a tab's layout, come from it), and dropped
    /// once that is no longer listed — there is nothing left to attach to.
    private func showSnapshot() {
        guard monitor.snapshotCount > 0, monitor.hasLoaded, machineStore.isCurrentConnection(machine) else { return }
        #if os(macOS)
        // The browsers of panes that are no longer listed go with them.
        if !machine.isLocal { BrowserStore.shared.reconcile(machineID: machine.id, herdrMachineID: nil, panes: agents) }
        #endif
        settleRenameCommit(onHerdrMachine: nil, panes: agents, tabs: tabs)
        AgentSessionNamer.shared.observe(agents, machineID: machine.id, herdrMachineID: nil) { [machineStore, machine] in
            try Self.namingConnection(machineStore, machine)
        }
        // A selection on a herdr machine is `showHerdrMachines`'s to keep.
        guard let selected = selection, selected.herdrMachine == nil else { return }
        reselect(selected, in: agents, tabs: tabs)
    }

    /// Points `selection` at the newest snapshot of the pane or tab it
    /// holds, among one herdr's panes and tabs.
    ///
    /// The selection is only written when that changes it. Every write
    /// re-evaluates `ContentView` and rebuilds the terminal view's value,
    /// whether or not the new selection differs from the old, and most
    /// refreshes bring nothing new about what is selected.
    private func reselect(_ selected: BoardItem, in panes: [AgentSummary], tabs: [TabSummary]?) {
        let current: BoardItem?
        switch selected {
        case .pane(let pane):
            current = panes.first { $0.id == pane.id }.map(BoardItem.pane)
        case .tab(let tab):
            current = tabs?.first { $0.id == tab.id }.map(BoardItem.tab)
        }
        if current == nil, selected.id == justCreatedID {
            return
        }
        if current != nil, selected.id == justCreatedID {
            justCreatedID = nil
        }
        if current != selected {
            selection = current
        }
    }

    /// The board's herdrs as the new tab launcher offers them: the host's
    /// own first, then its herdr machines, each with its workspaces — or the
    /// reason a tab can't be opened there right now.
    private var launchTargetsNow: [LaunchTarget] {
        let hostReason: String? = if let loadError {
            loadError
        } else if !hasLoadedAgents {
            String(localized: "Loading…")
        } else if workspaces == nil {
            String(localized: "This machine's herdr is too old to list its workspaces.")
        } else {
            nil
        }
        var targets = [LaunchTarget(
            herdrMachine: nil,
            label: machine.displayName,
            workspaces: Self.launchWorkspaces(workspaces, tabs: tabs),
            unavailableReason: hostReason
        )]
        for group in herdrMachineGroups {
            let reason: String? = if let error = group.error {
                error
            } else if !group.hasLoaded {
                String(localized: "Loading…")
            } else if group.workspaces == nil {
                String(localized: "This machine's herdr is too old to list its workspaces.")
            } else {
                nil
            }
            targets.append(LaunchTarget(
                herdrMachine: group.machine,
                label: group.machine.label,
                workspaces: Self.launchWorkspaces(group.workspaces, tabs: group.tabs),
                unavailableReason: reason
            ))
        }
        return targets
    }

    private static func launchWorkspaces(_ workspaces: [WorkspaceSummary]?, tabs: [TabSummary]?) -> [LaunchWorkspace] {
        (workspaces ?? []).map { workspace in
            LaunchWorkspace(
                workspace: workspace,
                tabCount: (tabs ?? []).filter { $0.workspaceID == workspace.workspaceID }.count
            )
        }
    }

    private nonisolated static func color(for state: AgentState) -> Color {
        switch state {
        case .idle: .gray
        case .working: .blue
        case .blocked: .orange
        case .done: .green
        case .unknown: .secondary
        }
    }
}
