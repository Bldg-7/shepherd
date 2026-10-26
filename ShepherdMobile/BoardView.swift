import SwiftUI
import ShepherdKit

/// One machine's panes, by workspace, the most urgent first — kept up to
/// date by the machine's monitor for as long as the view is on screen, as
/// the macOS board is. Tapping a pane shows what it last printed.
struct BoardView: View {
    let machine: Machine
    let machineStore: MachineStore
    let agentListCache: MobileAgentListCache
    @State private var cachedSnapshot: AgentListCache.Snapshot?

    private var monitor: MachineMonitor {
        MachineMonitors.shared.monitor(for: machine, in: machineStore)
    }

    var body: some View {
        BoardList(machine: machine, monitor: monitor, cachedSnapshot: cachedSnapshot)
            .navigationTitle(machine.displayName)
            .refreshable {
                _ = await monitor.refresh()
            }
            .task(id: machine.connectionIdentity) {
                // An unloaded board must hydrate its inert display cache before
                // acquiring the lease that can start a network connection. A
                // monitor already live for another owner remains live-first.
                await MobileBoardLoadCoordinator.run(
                    machine: machine,
                    cache: agentListCache,
                    publishCachedSnapshot: { cachedSnapshot = $0 },
                    startLease: { await MachineMonitors.shared.holdForBoard(machine, in: machineStore) },
                    refresh: { monitor.refreshNow() }
                )
                await agentListCache.flush(for: machine)
            }
    }
}

/// A pane to show the output of: enough of it to find it again, and to
/// title the view, without the whole summary (which changes as the agent
/// works and isn't `Hashable`).
struct PaneDestination: Hashable {
    let machine: Machine
    let paneID: String
    let terminalID: String
    let nativeSessionID: String?
    let herdrMachine: HerdrMachine?
    let title: String
    /// The agent herdr recognised in the pane when it was chosen, or nil
    /// for a plain terminal, which can be read but not prompted.
    let agentName: String?

    init(machine: Machine, pane: AgentSummary) {
        self.machine = machine
        self.paneID = pane.paneID
        self.terminalID = pane.terminalID
        // Identity metadata only; no session file is opened or read.
        self.nativeSessionID = pane.agentName.flatMap(AgentKind.init(herdrName:)).flatMap { kind in
            pane.sessionReference?.conversationID(for: kind)
        }
        self.herdrMachine = pane.herdrMachine
        self.title = pane.title
        self.agentName = pane.agentName
    }
}

private struct BoardList: View {
    let machine: Machine
    let monitor: MachineMonitor
    let cachedSnapshot: AgentListCache.Snapshot?

    private var showingCachedHost: Bool { !monitor.hasLoaded && cachedSnapshot != nil }
    private var showingCachedNestedGroups: Bool { monitor.herdrMachineRoundCount == 0 && cachedSnapshot != nil }
    private var hasVisiblePanes: Bool {
        if showingCachedHost {
            if !(cachedSnapshot?.host.panes.isEmpty ?? true) { return true }
        } else if !monitor.panes.isEmpty {
            return true
        }
        if showingCachedNestedGroups {
            return cachedSnapshot?.nestedGroups.contains { !$0.snapshot.panes.isEmpty } ?? false
        }
        return monitor.herdrMachineGroups.contains { !$0.agents.isEmpty }
    }

    var body: some View {
        List {
            if let error = monitor.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                    if !monitor.isRetrying {
                        Button("Retry") { monitor.retry() }
                    }
                }
            }
            if !monitor.hasLoaded, cachedSnapshot == nil, monitor.loadError == nil {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading panes…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !hasVisiblePanes, (monitor.hasLoaded || cachedSnapshot != nil) {
                Section {
                    Text("No panes")
                        .foregroundStyle(.secondary)
                }
            }
            if showingCachedHost, let cachedSnapshot {
                cachedSection(cachedSnapshot.host.panes, title: String(localized: "Cached panes"))
            } else {
                ForEach(BoardSection.sections(of: monitor.panes, in: monitor.workspaces)) { section in
                    paneSection(section, title: section.title,
                        showsWorkingActivity: monitor.hasLoaded && monitor.loadError == nil)
                }
            }
            if showingCachedNestedGroups, let cachedSnapshot {
                ForEach(cachedSnapshot.nestedGroups, id: \.machine.id) { group in
                    cachedSection(group.snapshot.panes, title: "\(group.machine.label) · \(String(localized: "Cached panes"))")
                }
            } else {
                ForEach(monitor.herdrMachineGroups) { group in
                    ForEach(BoardSection.sections(of: group.agents, in: group.workspaces)) { section in
                        paneSection(section, title: "\(group.machine.label) · \(section.title)",
                            showsWorkingActivity: group.hasLoaded && group.error == nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func paneSection(_ section: BoardSection, title: String, showsWorkingActivity: Bool) -> some View {
        Section(title) {
            ForEach(section.panes) { pane in
                NavigationLink(value: PaneDestination(machine: machine, pane: pane)) {
                    PaneRow(pane: pane, showsWorkingActivity: showsWorkingActivity)
                }
            }
        }
    }

    private func cachedSection(_ panes: [AgentListCache.AgentDTO], title: String) -> some View {
        Section(title) {
            ForEach(panes, id: \.paneID) { pane in
                // Cached DTOs deliberately omit sessionReference. They are
                // display-only until a live monitor resolves this exact pane.
                CachedPaneRow(pane: pane)
            }
        }
    }
}

/// One workspace's panes, in the board's order.
private struct BoardSection: Identifiable {
    let id: String
    let title: String
    let panes: [AgentSummary]

    /// The panes grouped by workspace, in the order herdr lists the
    /// workspaces, then any whose workspace herdr didn't list; from a herdr
    /// too old to report workspaces, all of them in one section.
    static func sections(of panes: [AgentSummary], in workspaces: [WorkspaceSummary]?) -> [BoardSection] {
        guard let workspaces, !workspaces.isEmpty else {
            return panes.isEmpty ? [] : [BoardSection(id: "all", title: String(localized: "Panes"), panes: BoardOrder.panes(panes))]
        }
        var sections: [BoardSection] = []
        var placed = Set<String>()
        for workspace in workspaces {
            let members = panes.filter { $0.workspaceID == workspace.workspaceID }
            guard !members.isEmpty else { continue }
            placed.formUnion(members.map(\.id))
            sections.append(BoardSection(id: workspace.id, title: workspace.label, panes: BoardOrder.panes(members)))
        }
        let rest = panes.filter { !placed.contains($0.id) }
        if !rest.isEmpty {
            sections.append(BoardSection(id: "rest", title: String(localized: "Other"), panes: BoardOrder.panes(rest)))
        }
        return sections
    }
}

private struct CachedPaneRow: View {
    let pane: AgentListCache.AgentDTO

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: pane.label ?? pane.terminalTitle ?? pane.agentName ?? pane.paneID)
                    .lineLimit(1)
                Text(verbatim: pane.agentName ?? String(localized: "Shell"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pane.agentName != nil {
                Text(stateTitle)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.15), in: Capsule())
                    .foregroundStyle(color)
            }
        }
        .accessibilityHint(Text("Connect to refresh this cached pane."))
    }

    private var stateTitle: String {
        switch pane.state {
        case "blocked": String(localized: "Blocked")
        case "working": String(localized: "Working")
        case "done": String(localized: "Done")
        case "idle": String(localized: "Idle")
        default: String(localized: "Unknown")
        }
    }

    private var color: Color {
        switch pane.state {
        case "blocked": .orange
        case "working": .blue
        case "done": .green
        default: .secondary
        }
    }
}

private struct PaneRow: View {
    let pane: AgentSummary
    /// A failed monitor retains its last rows for context, but those rows are
    /// no longer a live observation and therefore remain visually inert.
    let showsWorkingActivity: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: pane.title)
                    .lineLimit(1)
                Text(verbatim: pane.agentName ?? String(localized: "Shell"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pane.hasAgent {
                PaneStatusBadge(title: pane.state.title,
                    reservedTitles: [AgentState.idle, .working, .blocked, .done, .unknown].map(\.title),
                    color: color,
                    showsActivity: showsWorkingActivity && pane.state == .working)
            }
        }
    }

    private var color: Color {
        switch pane.state {
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        case .idle, .unknown: .secondary
        }
    }
}
