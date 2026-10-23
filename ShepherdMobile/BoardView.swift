import SwiftUI
import ShepherdKit

/// One machine's panes, by workspace, the most urgent first — kept up to
/// date by the machine's monitor for as long as the view is on screen, as
/// the macOS board is. Tapping a pane shows what it last printed.
struct BoardView: View {
    let machine: Machine
    let machineStore: MachineStore

    var body: some View {
        BoardList(machine: machine, monitor: MachineMonitors.shared.monitor(for: machine, in: machineStore))
            .navigationTitle(machine.displayName)
            .task(id: machine.connectionIdentity) {
                await MachineMonitors.shared.holdForBoard(machine, in: machineStore)
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
        // A session-file path is not a native ID and is never read here.
        self.nativeSessionID = pane.sessionReference.flatMap { reference in
            reference.kind == .id && AgentKind(herdrName: reference.agent) == pane.agentName.flatMap(AgentKind.init(herdrName:)) ? reference.value : nil
        }
        self.herdrMachine = pane.herdrMachine
        self.title = pane.title
        self.agentName = pane.agentName
    }
}

private struct BoardList: View {
    let machine: Machine
    let monitor: MachineMonitor

    var body: some View {
        List {
            if let error = monitor.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                    if !monitor.isRetrying {
                        Button("Retry") { monitor.retry() }
                    }
                }
            } else if !monitor.hasLoaded {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading panes…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if monitor.panes.isEmpty && monitor.herdrMachineGroups.isEmpty {
                Section {
                    Text("No panes")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(BoardSection.sections(of: monitor.panes, in: monitor.workspaces)) { section in
                paneSection(section, title: section.title)
            }
            ForEach(monitor.herdrMachineGroups) { group in
                ForEach(BoardSection.sections(of: group.agents, in: group.workspaces)) { section in
                    paneSection(section, title: "\(group.machine.label) · \(section.title)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func paneSection(_ section: BoardSection, title: String) -> some View {
        Section(title) {
            ForEach(section.panes) { pane in
                NavigationLink(value: PaneDestination(machine: machine, pane: pane)) {
                    PaneRow(pane: pane)
                }
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

private struct PaneRow: View {
    let pane: AgentSummary

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
                Text(pane.state.title)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.15), in: Capsule())
                    .foregroundStyle(color)
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
