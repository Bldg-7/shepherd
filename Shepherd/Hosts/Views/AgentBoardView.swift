import SwiftUI
#if canImport(Citadel)
import Citadel
#endif

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
}

/// The sidebar content of `ContentView`'s `NavigationSplitView` — the panes,
/// or the tabs, of whichever Machine is currently active, with `selection`
/// driving the detail column.
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
    /// Goes up each time the board is to fetch everything again at once.
    let refreshRequests: Int

    @State private var agents: [AgentSummary] = []
    /// The host's tabs, or nil while its herdr hasn't reported any — before
    /// the first snapshot, or for good from a herdr too old to.
    @State private var tabs: [TabSummary]?
    /// The host's workspaces, which its rows are listed under, or nil as for
    /// `tabs`.
    @State private var workspaces: [WorkspaceSummary]?
    /// Whether `agents` is a list herdr reported rather than the empty one
    /// this view starts out with. An empty list says nothing by itself: it
    /// is what a machine with no agents looks like, and also what a board
    /// that hasn't heard from its machine yet looks like.
    @State private var hasLoadedAgents = false
    @State private var loadError: String?
    /// Whether the board will try again by itself after `loadError`, or has
    /// stopped until the person asks (see `isPermanentFailure`). The two
    /// look alike otherwise, and only one of them needs the person to do
    /// something.
    @State private var isRetrying = false
    /// How many times the person has asked for another connection attempt.
    /// It is part of the board task's identity, so asking restarts the task
    /// — whether it was waiting to reconnect or had stopped trying.
    @State private var retryCount = 0
    /// How many times the board has been asked to fetch everything again
    /// straight away, after a change made from its own context menus. Part
    /// of the board task's identity, like `retryCount`.
    @State private var refreshCount = 0
    /// The pane or tab whose name is being edited, and the name as typed.
    @State private var renaming: BoardItem?
    @State private var newName = ""
    /// The pane or tab waiting for the person to confirm it is to be closed.
    @State private var closing: BoardItem?
    /// Why the last rename or close didn't go through.
    @State private var actionFailure: ActionFailure?
    /// The herdr machines saved on the host (see `HerdrMachine`), each with
    /// what was last heard from it. Empty while the host has none, and then
    /// the board is one flat list of the host's agents, as it always was;
    /// with any, it is grouped by machine, the host's own agents first.
    @State private var herdrMachineGroups: [HerdrMachineGroup] = []
    /// The groups the person has folded away, by group ID, one per line.
    /// Kept per Shepherd Machine (see `init`), so the host group of one
    /// machine and of another are folded separately, and across launches.
    @AppStorage private var collapsedGroupIDs: String
    /// Whether the board lists tabs, one row each, instead of panes. One
    /// setting for every machine; see `showsTabsKey`.
    @AppStorage(Self.showsTabsKey) private var showsTabs = false
    /// What is typed into the sidebar's search field (see `searchTerms`).
    @State private var searchText = ""
    /// The workspaces picked in the search field's workspace filter, by
    /// `workspaceFilterKey`; empty for all of them. See
    /// `activeWorkspaceFilter` for the ones that still count.
    @State private var workspaceFilter: Set<String> = []

    init(
        machine: Machine,
        machineStore: MachineStore,
        selection: Binding<BoardItem?>,
        justCreatedID: Binding<String?>,
        launchTargets: Binding<[LaunchTarget]>,
        refreshRequests: Int
    ) {
        self.machine = machine
        self.machineStore = machineStore
        self._selection = selection
        self._justCreatedID = justCreatedID
        self._launchTargets = launchTargets
        self.refreshRequests = refreshRequests
        self._collapsedGroupIDs = AppStorage(wrappedValue: "", "AgentBoardView.collapsedGroups.\(machine.id.uuidString)")
    }

    /// Where the tab setting is kept. `ContentView` reads it too: a pane
    /// selected in one mode means nothing in the other.
    static let showsTabsKey = "AgentBoardView.showsTabs"

    /// Whether this device offers the tab mode at all. Selecting a tab shows
    /// all of its panes side by side, and an iPhone's screen is too small to
    /// split; there the board only ever lists panes.
    static var offersTabs: Bool {
        true
    }

    /// One herdr machine's part of the board.
    struct HerdrMachineGroup: Identifiable, Equatable {
        let machine: HerdrMachine
        var agents: [AgentSummary] = []
        /// Its tabs and workspaces, as for the host's (see
        /// `AgentBoardView.tabs` and `workspaces`).
        var tabs: [TabSummary]?
        var workspaces: [WorkspaceSummary]?
        /// Why the last attempt to list its panes failed. The panes from
        /// before the failure stay listed under it: a machine dropping off
        /// for a moment shouldn't empty its group.
        var error: String?
        var hasLoaded = false
        var id: String { machine.id }
    }

    /// The host's own group, among the machines' (whose IDs are herdr's
    /// profile IDs, so they can't clash with this).
    private static let hostGroupID = "host"

    /// How often the panes on herdr machines are fetched again. They can't
    /// be long-polled like the host's: each request to a machine is a herdr
    /// CLI run that opens an SSH connection of its own, so they are polled,
    /// and a change on a machine shows within this long.
    private static let herdrMachineRefreshInterval: Duration = .seconds(5)

    /// What makes one run of the board's task a different run from another.
    private nonisolated struct ConnectionRun: Hashable {
        let machineID: UUID
        let retryCount: Int
        let refreshCount: Int
    }

    /// The shortest time between two refreshes of the pane list. A wait
    /// round normally lasts as long as herdr holds the long-poll open, but
    /// the refresh loop must not rely on that for its pacing: a round that
    /// comes back at once is followed straight away by the next, so a
    /// transport that answers `events.wait` without waiting would turn the
    /// loop into a busy loop of requests.
    private static let minimumRefreshInterval: Duration = .seconds(1)

    /// How long herdr is asked to hold one `events.wait` open, and so how
    /// long a round lasts while nothing happens. It is also the pace at which
    /// the board catches up with what no wait reports: a pane opening, a
    /// pane becoming `unknown`, or a change that leaves a pane's status as
    /// it was (a new title, say).
    private static let longPollTimeoutMs = 25_000

    /// The statuses a pane is watched for moving into: every one that says
    /// something about an agent. herdr 0.9.1's `events.wait` takes any of
    /// its five agent statuses in a match (see
    /// `HerdrClient.waitForPaneStatus`), so leaving `unknown` out is a
    /// choice rather than a limit. It is what herdr reports when it doesn't
    /// recognise what runs in a pane; a pane drifting into it is nothing
    /// that has to be shown at once, and not worth a further long-poll per
    /// pane.
    private static let awaitedStatuses: [AgentState] = [.idle, .working, .blocked, .done]

    /// How long a failed connection is left alone before the first new
    /// attempt. What usually breaks one — herdr not started yet, the machine
    /// asleep, the network gone — takes seconds to pass, and over SSH every
    /// attempt is a full handshake, so retrying any faster would only add
    /// load without recovering any sooner.
    private static let firstReconnectDelay: Duration = .seconds(5)

    /// Where the wait between attempts stops growing. Each attempt that
    /// fails doubles it: a machine that has been unreachable for a minute is
    /// more likely switched off than about to answer, and the board would
    /// otherwise keep knocking every few seconds for as long as it is on
    /// screen. A minute still brings the board back by itself soon after the
    /// machine returns; anyone who doesn't want to wait has the Retry button.
    private static let maximumReconnectDelay: Duration = .seconds(60)

    var body: some View {
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
        // (see `connectAndLoad`), so a failure can't be drawn in the list's
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
        .task(id: ConnectionRun(machineID: machine.id, retryCount: retryCount, refreshCount: refreshCount)) {
            await connectAndLoad()
        }
        .task(id: ConnectionRun(machineID: machine.id, retryCount: retryCount, refreshCount: refreshCount)) {
            await loadHerdrMachines()
        }
        .alert(renameTitle, isPresented: isRenaming, presenting: renaming) { item in
            TextField(renamePrompt(for: item), text: $newName)
            Button("Rename") { rename(item) }
                .disabled(!canRename(item))
            Button("Cancel", role: .cancel) {}
        } message: { item in
            if case .pane = item {
                Text("Leave it empty to call the pane by its title again.")
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
            launchTargets = targets
        }
        .onChange(of: refreshRequests) {
            refreshCount += 1
        }
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
    @ViewBuilder
    private var agentList: some View {
        let hostRows = visibleRows(panes: agents, tabs: tabs, workspaces: workspaces, herdrMachine: nil, machineLabel: machine.displayName)
        if herdrMachineGroups.isEmpty {
            List(selection: selectionID) {
                rows(hostRows)
            }
        } else {
            List(selection: selectionID) {
                if !isFiltering || hostRows.count > 0 {
                    Section {
                        if isFiltering || isExpanded(Self.hostGroupID).wrappedValue {
                            if !isFiltering {
                                hostGroupStatus
                            }
                            rows(hostRows)
                        }
                    } header: {
                        groupHeader(machine.displayName, panes: agents, rowCount: hostRows.count, groupID: Self.hostGroupID)
                    }
                }
                ForEach(herdrMachineGroups) { group in
                    let groupRows = visibleRows(panes: group.agents, tabs: group.tabs, workspaces: group.workspaces, herdrMachine: group.machine, machineLabel: group.machine.label)
                    if !isFiltering || groupRows.count > 0 {
                        Section {
                            if isFiltering || isExpanded(group.id).wrappedValue {
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
                            groupHeader(group.machine.label, panes: group.agents, rowCount: groupRows.count, groupID: group.id)
                        }
                    }
                }
            }
        }
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
        [tab.label]
            + (tab.mostUrgentState.map { [String(localized: $0.title)] } ?? [])
            + tab.panes.flatMap(searchTexts(for:))
    }

    /// The tab rows take the pane rows' place when the board shows tabs —
    /// for each herdr that can report them; one too old to keeps listing its
    /// panes.
    private var showsTabRows: Bool {
        showsTabs && Self.offersTabs
    }

    /// One herdr's rows: its tabs, in herdr's order, or its panes, by status
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
            ForEach(tabs) { tab in
                row(for: tab)
            }
        } else {
            ForEach(panes.sorted(by: Self.statusPriority)) { agent in
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
                Text(agent.title).font(.body)
                Text(subtitle(for: agent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if os(macOS)
                if ShepherdBrowserFeature.shared.isEnabled && (agent.hasAgent || agent.launchPending == true || AgentLaunchService.shared.status(for: agent, on: machine) != .shell) {
                    Text(AgentLaunchService.shared.status(for: agent, on: machine).title)
                        .font(.caption).foregroundStyle(.secondary)
                        .help(AgentLaunchService.shared.failure(for: agent, on: machine) ?? "")
                }
                #endif
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
                Button("Resume with Shepherd Browser (Experimental)") {
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
    }

    /// A tab's row: its name as herdr has it, how many panes it holds, and —
    /// with an agent among them — the status of the one that most needs the
    /// person, the way a pane's row shows its own.
    private func row(for tab: TabSummary) -> some View {
        HStack {
            statusIndicator(tab.mostUrgentState)
            VStack(alignment: .leading) {
                Text(tab.label).font(.body)
                Text("\(tab.panes.count) panes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #if os(macOS)
                if ShepherdBrowserFeature.shared.isEnabled {
                    ForEach(tab.panes.filter { $0.hasAgent || $0.launchPending == true || AgentLaunchService.shared.status(for: $0, on: machine) != .shell }) { pane in
                        Text(AgentLaunchService.shared.status(for: pane, on: machine).title)
                            .font(.caption).foregroundStyle(.secondary).help(pane.title)
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
    /// don't.
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
    private func groupHeader(_ title: String, panes: [AgentSummary], rowCount: Int, groupID: String) -> some View {
        let expanded = isExpanded(groupID)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
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
        .accessibilityValue(expanded.wrappedValue ? Text("Expanded") : Text("Collapsed"))
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

    private func isExpanded(_ groupID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroupIDs.split(separator: "\n").contains(Substring(groupID)) },
            set: { expanded in
                var collapsed = Set(collapsedGroupIDs.split(separator: "\n").map(String.init))
                if expanded {
                    collapsed.remove(groupID)
                } else {
                    collapsed.insert(groupID)
                }
                collapsedGroupIDs = collapsed.sorted().joined(separator: "\n")
            }
        )
    }

    private var retryStatus: String {
        isRetrying
            ? String(localized: "Trying again automatically.")
            : String(localized: "Not trying again until you press Retry.")
    }

    /// Starts the board's task over. A new connection attempt is all it
    /// takes in either case a failure leaves behind: the task sitting out
    /// the wait before its next attempt, or having ended because the failure
    /// was one that no further attempt of its own could get past.
    private func retry() {
        retryCount += 1
    }

    /// A rename or close that didn't go through: which of the two, and what
    /// herdr — or the connection to it — said.
    private struct ActionFailure {
        let title: String
        let message: String
    }

    private var renameTitle: Text {
        if case .tab = renaming {
            Text("Rename Tab")
        } else {
            Text("Rename Pane")
        }
    }

    /// The field starts out with the name the pane or tab already has. A
    /// pane that has none of its own starts out empty, with its title as the
    /// prompt: filled in with the title, a rename would pin today's title on
    /// it for good, where left alone it follows whatever runs in the pane.
    private func beginRenaming(_ item: BoardItem) {
        switch item {
        case .tab(let tab):
            newName = tab.label
        case .pane(let pane):
            newName = pane.label ?? ""
        }
        renaming = item
    }

    private func renamePrompt(for item: BoardItem) -> String {
        switch item {
        case .tab(let tab): tab.label
        case .pane(let pane): pane.terminalTitle ?? pane.agentName ?? pane.paneID
        }
    }

    /// A tab can't be given an empty name — herdr would show it as one. A
    /// pane can: that is how its own name is taken away again.
    private func canRename(_ item: BoardItem) -> Bool {
        if case .tab = item {
            return !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func rename(_ item: BoardItem) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(failureTitle: String(localized: "Couldn't Rename")) { client in
            switch item {
            case .tab(let tab):
                try await client.renameTab(tab.tabID, to: name, on: tab.herdrMachine)
            case .pane(let pane):
                try await client.renamePane(pane.paneID, to: name.isEmpty ? nil : name, on: pane.herdrMachine)
            }
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

    private var closeTitle: Text {
        switch closing {
        case .tab(let tab): Text("Close \u{201C}\(tab.label)\u{201D}?")
        case .pane(let pane): Text("Close \u{201C}\(pane.title)\u{201D}?")
        case nil: Text(verbatim: "")
        }
    }

    /// Sends a change to herdr over a connection of its own — the board's
    /// are busy holding long-polls open — and then has the board fetch
    /// everything again, so the change shows at once rather than at the
    /// next refresh. A change to a pane or tab on a herdr machine goes
    /// through the host, as every request to one does.
    private func perform(failureTitle: String, _ change: @escaping (HerdrClient) async throws -> Void) {
        Task {
            do {
                guard let current = machineStore.allMachines.first(where: { $0.id == machine.id }) else { return }
                let client = HerdrClient(transport: try machineStore.makeHerdrTransport(for: current))
                do {
                    try await client.connect()
                    try await change(client)
                } catch {
                    await client.disconnect()
                    throw error
                }
                await client.disconnect()
                refreshCount += 1
            } catch {
                actionFailure = ActionFailure(title: failureTitle, message: connectionFailureDescription(error))
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
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

    /// Shows a fresh round from the herdr machines, and keeps a selection on
    /// one of them in step the way `show` does for the host's: re-pointed at
    /// the new snapshot of its pane or tab, dropped once that — or the whole
    /// machine — is gone. Not while its machine can't be reached, though:
    /// that says nothing about whether the pane or tab is still there.
    private func showHerdrMachines(_ groups: [HerdrMachineGroup]) {
        if groups != herdrMachineGroups {
            herdrMachineGroups = groups
        }
        #if os(macOS)
        // As in `show`, for each machine whose panes were listed this time.
        // One that couldn't be reached says nothing about its panes.
        let browsers = BrowserStore.shared
        browsers.reconcile(machineID: machine.id, herdrMachines: Set(groups.map(\.id)))
        for group in groups where group.error == nil && group.hasLoaded {
            browsers.reconcile(machineID: machine.id, herdrMachineID: group.id, panes: group.agents)
        }
        #endif
        guard let selected = selection, let machine = selected.herdrMachine else { return }
        guard let group = groups.first(where: { $0.id == machine.id }) else {
            selection = nil
            return
        }
        guard group.error == nil else { return }
        reselect(selected, in: group.agents, tabs: group.tabs)
    }

    /// Shows a freshly fetched snapshot, and keeps the selection in step
    /// with it: the selection is a snapshot of its own, so it is re-pointed
    /// at the new snapshot of the same pane or tab (the detail column's
    /// title, and a tab's layout, come from it), and dropped once that is no
    /// longer listed — there is nothing left to attach to.
    ///
    /// A list on screen also means the connection works, so whatever error
    /// an earlier attempt left behind no longer applies.
    private func show(_ snapshot: HerdrSnapshot) {
        if loadError != nil {
            loadError = nil
        }
        if !hasLoadedAgents {
            hasLoadedAgents = true
        }
        agents = snapshot.panes
        #if os(macOS)
        // The browsers of panes that are no longer listed go with them.
        if !machine.isLocal { BrowserStore.shared.reconcile(machineID: machine.id, herdrMachineID: nil, panes: snapshot.panes) }
        #endif
        if snapshot.tabs != tabs {
            tabs = snapshot.tabs
        }
        if snapshot.workspaces != workspaces {
            workspaces = snapshot.workspaces
        }
        // A selection on a herdr machine is `showHerdrMachines`'s to keep.
        guard let selected = selection, selected.herdrMachine == nil else { return }
        reselect(selected, in: snapshot.panes, tabs: snapshot.tabs)
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

    private func loadHerdrMachines() async {
        guard !Task.isCancelled else { return }
        await Self.keepHerdrMachinesUpToDate(
            makeClient: {
                // As in `connectAndLoad`: the machine as the store has it now.
                guard let current = machineStore.allMachines.first(where: { $0.id == machine.id }) else { return nil }
                return HerdrClient(transport: try machineStore.makeHerdrTransport(for: current))
            },
            show: showHerdrMachines
        )
    }

    /// Keeps the board's herdr machine groups up to date for as long as the
    /// calling task lives: lists the machines saved on the host, then every
    /// machine's panes and tabs, every `herdrMachineRefreshInterval`. The list of
    /// machines is read again each time, so one added or removed in herdr
    /// appears or goes without anything restarting.
    ///
    /// It runs beside `keepUpToDate`, on a connection of its own, and leaves
    /// failures of that connection to it: the host can't be reached either
    /// way, `keepUpToDate` already says so, and the machines' groups keep
    /// what they last showed meanwhile. This one just backs off and starts
    /// over. A host whose herdr has no saved machines — or is too old to know
    /// about them — gives no groups, and the board stays a flat list.
    static func keepHerdrMachinesUpToDate(
        makeClient: () throws -> HerdrClient?,
        show: ([HerdrMachineGroup]) -> Void
    ) async {
        var groups: [HerdrMachineGroup] = []
        var retryDelay = firstReconnectDelay
        while !Task.isCancelled {
            let client: HerdrClient
            do {
                guard let made = try makeClient() else { return }
                client = made
            } catch {
                guard (try? await Task.sleep(for: retryDelay)) != nil else { return }
                retryDelay = min(retryDelay * 2, maximumReconnectDelay)
                continue
            }
            // Same reason for the cancellation handler as in `keepUpToDate`:
            // Citadel's awaits don't notice cancellation, closing the
            // connection does.
            let failed = await withTaskCancellationHandler {
                do {
                    try await client.connect()
                    while true {
                        try Task.checkCancellation()
                        let machines = try await client.listHerdrMachines()
                        try Task.checkCancellation()
                        groups = await fetchSnapshots(on: machines, previous: groups, client: client)
                        try Task.checkCancellation()
                        show(groups)
                        retryDelay = firstReconnectDelay
                        try await Task.sleep(for: herdrMachineRefreshInterval)
                    }
                } catch {
                    await client.disconnect()
                    return !Task.isCancelled
                }
            } onCancel: {
                Task { await client.disconnect() }
            }
            guard failed, (try? await Task.sleep(for: retryDelay)) != nil else { return }
            retryDelay = min(retryDelay * 2, maximumReconnectDelay)
        }
    }

    /// One round over the machines: all of them at once, each on its own, so
    /// one that is slow or down neither holds up nor hides the others. A
    /// machine that fails keeps the panes and tabs it last listed, under its
    /// error.
    private static func fetchSnapshots(
        on machines: [HerdrMachine],
        previous: [HerdrMachineGroup],
        client: HerdrClient
    ) async -> [HerdrMachineGroup] {
        let results = await withTaskGroup(of: (Int, HerdrSnapshot?, String?).self) { group in
            for (index, machine) in machines.enumerated() {
                group.addTask {
                    do {
                        return (index, try await client.snapshot(on: machine), nil)
                    } catch {
                        return (index, nil, connectionFailureDescription(error))
                    }
                }
            }
            var results = [(snapshot: HerdrSnapshot?, error: String?)](repeating: (nil, nil), count: machines.count)
            for await (index, snapshot, error) in group {
                results[index] = (snapshot, error)
            }
            return results
        }
        return zip(machines, results).map { machine, result in
            let last = previous.first { $0.id == machine.id }
            if let snapshot = result.snapshot {
                return HerdrMachineGroup(
                    machine: machine,
                    agents: snapshot.panes,
                    tabs: snapshot.tabs,
                    workspaces: snapshot.workspaces,
                    error: nil,
                    hasLoaded: true
                )
            }
            return HerdrMachineGroup(
                machine: machine,
                agents: last?.agents ?? [],
                tabs: last?.tabs,
                workspaces: last?.workspaces,
                error: result.error,
                hasLoaded: last?.hasLoaded ?? false
            )
        }
    }

    private func connectAndLoad() async {
        // SwiftUI can cancel this task before its body has run at all (the
        // board appearing and going away in one breath), and the body runs
        // regardless. There is no one left to show anything to by then.
        guard !Task.isCancelled else { return }
        // A previous run's failure says nothing about this one: the task is
        // restarted every time the list comes back on screen (on iPhone,
        // returning from the terminal), and the reconnect below may well
        // succeed. `agents` is deliberately kept, so that returning shows the
        // last known list instead of flashing back to "Loading panes…".
        loadError = nil
        await Self.keepUpToDate(
            makeClient: {
                // The machine as the store has it now, not as this view
                // captured it when the task began: a host key pinned by an
                // earlier connection is recorded in the store's copy only,
                // and a transport built from the captured one — nothing
                // pinned — would trust whichever key it is shown all over
                // again. A machine the store no longer has was removed, and
                // there is nothing left to connect to.
                guard let current = machineStore.allMachines.first(where: { $0.id == machine.id }) else { return nil }
                return HerdrClient(transport: try machineStore.makeHerdrTransport(for: current))
            },
            pinHostKey: { fingerprint in
                machineStore.pinHostKeyFingerprint(fingerprint, for: machine)
            },
            show: show,
            report: { error, willRetry in
                loadError = connectionFailureDescription(error)
                isRetrying = willRetry
                // With no rows there is no last known list worth keeping,
                // and "No Panes" would go on claiming something about a
                // machine that can't be reached. The next attempt starts
                // from "Loading panes…" instead.
                if agents.isEmpty && hasLoadedAgents {
                    hasLoadedAgents = false
                }
            }
        )
    }

    /// Whether a failed connection attempt is one that another attempt
    /// cannot get past: it would fail the same way every time, until the
    /// person changes something. This is the one place that decides it, and
    /// `keepUpToDate` stops reconnecting on its own when the answer is yes.
    ///
    /// The cost of getting it wrong is not symmetric. Retrying a failure
    /// that will not pass means presenting the same rejected credential to
    /// sshd over and over for as long as the board is on screen, which is
    /// what fail2ban, sshd's own per-source penalties and account lockouts
    /// exist to punish. Stopping at a failure that would have passed only
    /// costs a press of Retry. Even so the list is short and specific, and
    /// everything not on it — a refused or lost connection, a timeout, herdr
    /// not running, a Keychain that can't be read right now — is retried:
    /// - the stored key is not one this app can use (`OpenSSHKeyError`);
    /// - the server's host key is not the one pinned for this machine
    ///   (`HostKeyValidationError`): either it was reinstalled or someone is
    ///   in the middle, and neither changes by asking again;
    /// - the server turned the credential down, or doesn't offer the kind of
    ///   authentication this machine is set up for (Citadel's
    ///   `SSHClientError`, except for its one case that isn't about
    ///   authentication).
    ///
    /// All of these come from the SSH transport, so a build without Citadel
    /// has no such failure.
    nonisolated static func isPermanentFailure(_ error: any Error) -> Bool {
        #if canImport(Citadel)
        switch error {
        case is OpenSSHKeyError, is HostKeyValidationError:
            return true
        case SSHClientError.allAuthenticationOptionsFailed,
             SSHClientError.unsupportedPasswordAuthentication,
             SSHClientError.unsupportedPrivateKeyAuthentication,
             SSHClientError.unsupportedHostBasedAuthentication:
            return true
        default:
            return false
        }
        #else
        return false
        #endif
    }

    /// Keeps a board up to date for as long as the calling task lives:
    /// connects, shows the pane list, refreshes it whenever something may
    /// have changed — and after a failure starts over with a new connection
    /// instead of giving up. The board is the split view's permanent
    /// sidebar: on macOS and iPad it never leaves the screen, so nothing
    /// would restart a task that had ended, and a single failure (the app
    /// opened before herdr, the Mac waking from sleep, a network blip) would
    /// stay on screen until the app was relaunched.
    ///
    /// How soon it starts over depends on how long that has been failing:
    /// `firstReconnectDelay` after a connection that had kept working
    /// through a whole round of waits, twice as long after every attempt that
    /// didn't, up to `maximumReconnectDelay`. Listing the agents alone isn't
    /// enough to count as working: a connection that lists them and then
    /// fails in the waits that follow fails the same way on every attempt,
    /// and would otherwise be retried at the shortest delay for good. The
    /// one exception is a failure that
    /// `isPermanentFailure` says no further attempt can get past. That ends
    /// the loop with the failure reported, and it is up to the caller to
    /// start it again once the person asks for another try.
    ///
    /// Everything this does to the board goes through the closures, which
    /// keeps the whole lifecycle runnable without a view. None of them is
    /// called once the task has been cancelled.
    /// - `makeClient` returns the client for one connection attempt, or nil
    ///   when there is nothing to connect to any more, which ends the loop.
    ///   Each attempt gets a client and transport of its own: what a
    ///   transport was created with (the pinned host key above all) is fixed
    ///   for its lifetime, and may be out of date by the next attempt. It
    ///   throws when the client can't be put together, which counts as a
    ///   failed attempt like any other.
    /// - `pinHostKey` receives the fingerprint of a host key that a
    ///   connection has just trusted for the first time.
    /// - `show` receives every snapshot fetched, `report` every failure
    ///   that ends an attempt, together with whether another attempt will
    ///   follow by itself.
    static func keepUpToDate(
        makeClient: () throws -> HerdrClient?,
        pinHostKey: (String) -> Void,
        show: (HerdrSnapshot) -> Void,
        report: (any Error, _ willRetry: Bool) -> Void
    ) async {
        var reconnectDelay = firstReconnectDelay
        while !Task.isCancelled {
            // What ended this attempt. Nil means it was not a failure but the
            // task being cancelled.
            let failure: (any Error)?
            do {
                guard let client = try makeClient() else { return }
                // SwiftUI cancels the board's `.task` when the view disappears, but Swift's
                // cooperative cancellation doesn't reach into Citadel's NIO-backed
                // awaits (EventLoopFuture.get() and the AsyncStream read loop in
                // SSHHerdrTransport.send() don't check Task.isCancelled) — so without
                // this, leaving the screen would leave the SSH connection and every
                // in-flight long-poll channel open for up to their full timeout
                // (confirmed live: repeated visits pile up connections until herdr.sock
                // starts refusing new ones). withTaskCancellationHandler's onCancel
                // fires immediately on cancellation, so close the connection there —
                // Citadel's SSHClient.close() cascades to every multiplexed channel.
                //
                // That same disconnect makes whatever this task is awaiting fail (or,
                // for awaits that can't be interrupted, return late), and by then the
                // view's state belongs to whichever task replaced this one. So every
                // await below is followed by a cancellation check before any state is
                // touched, and a failure that arrives after cancellation is dropped
                // rather than reported — it was caused by leaving, not by the machine.
                failure = await withTaskCancellationHandler {
                    var reported: (any Error)?
                    do {
                        try await client.connect()
                        try Task.checkCancellation()
                        if let newFingerprint = await client.newlyPinnedHostKeyFingerprint() {
                            try Task.checkCancellation()
                            pinHostKey(newFingerprint)
                        }
                        var snapshot = try await client.snapshot()
                        try Task.checkCancellation()
                        show(snapshot)
                        // herdr has no "subscribe to everything" — events.wait long-polls
                        // for one specific pane to reach one specific status (it holds the
                        // request server-side until that happens or it times out,
                        // confirmed live). So: long-poll every known pane concurrently,
                        // and as soon as ANY one of those waits ends (or we've waited long
                        // enough that it's worth checking for new/closed panes anyway),
                        // refresh the full list and restart. This reacts near-instantly to
                        // real changes without hammering the server with fixed-interval
                        // polling.
                        while true {
                            let roundStart = ContinuousClock.now
                            try await waitForAnyPaneChange(client: client, panes: snapshot.panes)
                            let remaining = minimumRefreshInterval - (ContinuousClock.now - roundStart)
                            if remaining > .zero {
                                try await Task.sleep(for: remaining)
                            }
                            try Task.checkCancellation()
                            snapshot = try await client.snapshot()
                            try Task.checkCancellation()
                            show(snapshot)
                            // A whole round of waits came and went on this
                            // connection, so whatever goes wrong from here on
                            // is a new outage, not more of the one the delay
                            // had grown for.
                            reconnectDelay = firstReconnectDelay
                        }
                    } catch {
                        if !Task.isCancelled {
                            report(error, !isPermanentFailure(error))
                            reported = error
                        }
                    }
                    // The loop above only ends by failing or by being cancelled, and
                    // either way this connection has no further use. onCancel alone
                    // doesn't cover it: when cancellation lands while connect() is
                    // still in flight there is nothing for it to close yet, and the
                    // connection that connect() then goes on to establish would stay
                    // open with no one left to close it.
                    await client.disconnect()
                    return reported
                } onCancel: {
                    Task { await client.disconnect() }
                }
            } catch {
                // There is no client, so nothing was connected and nothing
                // needs closing. Nothing has been awaited since the loop
                // last saw the task alive, either.
                report(error, !isPermanentFailure(error))
                failure = error
            }
            guard let failure, !isPermanentFailure(failure) else { return }
            // `Task.sleep` throws on cancellation, so leaving the board — or
            // asking for another attempt — while it waits to reconnect ends
            // the task there and then.
            do {
                try await Task.sleep(for: reconnectDelay)
            } catch {
                return
            }
            reconnectDelay = min(reconnectDelay * 2, maximumReconnectDelay)
        }
    }

    /// Returns when something on the board may have changed — or, failing
    /// that, when it has been long enough that the list is worth fetching
    /// again anyway. Throws when the connection fails, when herdr answers a
    /// wait with an error that isn't about the pane having gone, or when the
    /// task is cancelled.
    ///
    /// herdr's `events.wait` holds a request until one pane reaches one
    /// status, so noticing a change of status takes a concurrent wait per
    /// pane for every status it could move to (`awaitedStatuses`). Whichever
    /// way a pane goes — into `blocked` or `done`, or back out of them when
    /// it is given something new to do — one of its waits matches, and the
    /// first wait to end, by matching or by timing out, ends the round.
    ///
    /// A status the pane already has is not waited for. herdr answers such a
    /// wait at once instead of holding it, so every round would end
    /// immediately, and the loop would refetch the list at its floor for as
    /// long as the board was open.
    ///
    /// Nor is a pane with no agent in it: it has no status to change. An
    /// agent starting in one shows up the way a pane opening does, when the
    /// round ends.
    static func waitForAnyPaneChange(client: HerdrClient, panes: [AgentSummary]) async throws {
        let agents = panes.filter(\.hasAgent)
        guard !agents.isEmpty else {
            try await Task.sleep(for: .seconds(5))
            return
        }
        // Never empty: there are more statuses to wait for than the one a
        // pane can have, so every pane brings at least one wait.
        let waits = agents.flatMap { agent in
            awaitedStatuses
                .filter { $0 != agent.state }
                .map { (paneID: agent.paneID, status: $0) }
        }
        let timeoutMs = longPollTimeoutMs
        try await withThrowingTaskGroup(of: Void.self) { group in
            for wait in waits {
                group.addTask {
                    do {
                        _ = try await client.waitForPaneStatus(paneID: wait.paneID, status: wait.status, timeoutMs: timeoutMs)
                    } catch let error as HerdrErrorPayload where error.code == "pane_not_found" {
                        // The pane closed while being waited on, or between
                        // the list and the wait. That is exactly the kind of
                        // change the list has to be fetched again for, so it
                        // ends the round like a match would.
                        //
                        // No other error herdr answers a wait with is taken
                        // for a change. One that herdr gives every time (a
                        // version that turns the match down, say) comes
                        // back at once, and treated as a change it would
                        // have the loop refetching the list at its floor
                        // with nothing on screen to say anything is wrong.
                        // Thrown, it ends the connection and is shown.
                    }
                }
            }
            _ = try await group.next()
            group.cancelAll()
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

    /// Agents by how much they need the person, then the panes with no
    /// agent in them, which never do. Within each rank the order is the one
    /// herdr listed them in (Swift's sort is stable), so rows don't trade
    /// places from one refresh to the next.
    private nonisolated static func statusPriority(_ lhs: AgentSummary, _ rhs: AgentSummary) -> Bool {
        func rank(_ pane: AgentSummary) -> Int {
            pane.hasAgent ? pane.state.urgency : AgentState.unknown.urgency + 1
        }
        return rank(lhs) < rank(rhs)
    }
}
