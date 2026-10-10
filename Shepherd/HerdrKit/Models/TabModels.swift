import Foundation

/// Where one pane sits in its tab, as fractions of the tab's area (0...1),
/// so that the tab can be laid out at whatever size it is shown at.
nonisolated struct PanePlacement: Equatable, Sendable {
    let paneID: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// One herdr tab: its panes, and how herdr has them laid out.
///
/// The layout comes from `session.snapshot`'s `layouts` — per tab, the area
/// panes are laid out in and each pane's rect in it, in terminal cells
/// (verified against `herdr 0.9.1` on 2026-10-03). Those rects are worked
/// out from the tab's splits whether or not one pane is zoomed, so they
/// always place every pane.
nonisolated struct TabSummary: Identifiable, Equatable, Sendable {
    let tabID: String
    /// The workspace the tab is in. Nil only from a herdr that doesn't say.
    let workspaceID: String?
    /// As herdr shows it: the name it was given, or its number in its
    /// workspace if it was never named.
    let label: String
    /// The herdr machine the tab is on, or nil for the host's own herdr.
    let herdrMachine: HerdrMachine?
    /// The tab's panes, in the order its layout lists them.
    let panes: [AgentSummary]
    /// One per pane in `panes`.
    let placements: [PanePlacement]
    /// The pane that has focus in herdr's own view of the tab.
    let focusedPaneID: String?

    /// The tab ID, qualified by the herdr machine it is on.
    var id: String { herdrMachine.map { "\($0.id)/\(tabID)" } ?? tabID }

    /// Strip a Pi-generated caption only when this tab label is an exact
    /// copy of a Pi pane's automatic terminal title. Unrelated/user names
    /// remain untouched; the raw label is still used for rename operations.
    var title: String {
        guard let pane = panes.first(where: { $0.agentName == "pi" && $0.label == nil && $0.terminalTitle == label }) else { return label }
        return pane.automaticTitle
    }

    /// The state of the agent in the tab that most needs the person, for
    /// a tab with any agent in it.
    var mostUrgentState: AgentState? {
        panes.filter(\.hasAgent).map(\.state).min { $0.urgency < $1.urgency }
    }

    func placement(of paneID: String) -> PanePlacement? {
        placements.first { $0.paneID == paneID }
    }

    /// `tab` is one of `session.snapshot`'s `tabs`, `layout` its entry in
    /// `layouts`, and `panes` the snapshot's panes by pane ID.
    init?(tab: JSONValue, layout: JSONValue?, panes: [String: AgentSummary], on herdrMachine: HerdrMachine?) {
        guard let tabID = tab["tab_id"]?.stringValue else { return nil }
        self.tabID = tabID
        self.workspaceID = tab["workspace_id"]?.stringValue
        self.label = tab["label"]?.stringValue ?? tab["number"]?.intValue.map(String.init) ?? tabID
        self.herdrMachine = herdrMachine
        self.focusedPaneID = layout?["focused_pane_id"]?.stringValue

        let areaX = layout?["area"]?["x"]?.doubleValue ?? 0
        let areaY = layout?["area"]?["y"]?.doubleValue ?? 0
        let areaWidth = layout?["area"]?["width"]?.doubleValue ?? 0
        let areaHeight = layout?["area"]?["height"]?.doubleValue ?? 0
        var tabPanes: [AgentSummary] = []
        var placements: [PanePlacement] = []
        if areaWidth > 0, areaHeight > 0 {
            for entry in layout?["panes"]?.arrayValue ?? [] {
                guard let paneID = entry["pane_id"]?.stringValue,
                      let pane = panes[paneID],
                      let x = entry["rect"]?["x"]?.doubleValue,
                      let y = entry["rect"]?["y"]?.doubleValue,
                      let width = entry["rect"]?["width"]?.doubleValue,
                      let height = entry["rect"]?["height"]?.doubleValue else { continue }
                tabPanes.append(pane)
                placements.append(PanePlacement(
                    paneID: paneID,
                    x: (x - areaX) / areaWidth,
                    y: (y - areaY) / areaHeight,
                    width: width / areaWidth,
                    height: height / areaHeight
                ))
            }
        }
        // No layout to go by — none was sent for the tab, or it named none
        // of its panes: the panes herdr says are in the tab, side by side.
        if tabPanes.isEmpty {
            tabPanes = panes.values.filter { $0.tabID == tabID }.sorted { $0.paneID < $1.paneID }
            placements = tabPanes.enumerated().map { index, pane in
                PanePlacement(
                    paneID: pane.paneID,
                    x: Double(index) / Double(tabPanes.count),
                    y: 0,
                    width: 1 / Double(tabPanes.count),
                    height: 1
                )
            }
        }
        self.panes = tabPanes
        self.placements = placements
    }
}

/// One herdr workspace, which the board labels the rows in it with.
nonisolated struct WorkspaceSummary: Identifiable, Equatable, Sendable {
    let workspaceID: String
    /// As herdr shows it: the name it was given, or its number if it was
    /// never named.
    let label: String

    var id: String { workspaceID }

    init?(json: JSONValue) {
        guard let workspaceID = json["workspace_id"]?.stringValue else { return nil }
        self.workspaceID = workspaceID
        self.label = json["label"]?.stringValue ?? json["number"]?.intValue.map(String.init) ?? workspaceID
    }
}

/// What the board shows of one herdr: its panes and, from a herdr new
/// enough to report them, its tabs and workspaces.
nonisolated struct HerdrSnapshot: Equatable, Sendable {
    let panes: [AgentSummary]
    /// The tabs in herdr's order — workspace by workspace, each one's tabs
    /// in turn — or nil when herdr can't report them: `session.snapshot`,
    /// the request they come from, is herdr 0.7.2's.
    let tabs: [TabSummary]?
    /// The workspaces in herdr's order, or nil when herdr can't report
    /// them, as for `tabs`.
    let workspaces: [WorkspaceSummary]?

    /// A snapshot of panes alone, from a herdr too old for the rest.
    init(panes: [AgentSummary]) {
        self.panes = panes
        self.tabs = nil
        self.workspaces = nil
    }

    /// `snapshot` is the `snapshot` object of a `session.snapshot` result.
    init(snapshot: JSONValue, on herdrMachine: HerdrMachine? = nil) {
        let panes = (snapshot["panes"]?.arrayValue ?? []).compactMap { AgentSummary(json: $0, on: herdrMachine) }
        let panesByID = Dictionary(panes.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        let layouts = snapshot["layouts"]?.arrayValue ?? []
        self.panes = panes
        self.workspaces = (snapshot["workspaces"]?.arrayValue ?? []).compactMap(WorkspaceSummary.init(json:))
        self.tabs = (snapshot["tabs"]?.arrayValue ?? []).compactMap { tab in
            let tabID = tab["tab_id"]?.stringValue
            let layout = layouts.first { $0["tab_id"]?.stringValue == tabID }
            return TabSummary(tab: tab, layout: layout, panes: panesByID, on: herdrMachine)
        }
    }
}

extension AgentState {
    /// How much a pane in this state needs the person — lower is more.
    /// A blocked agent is waiting on them; one that is working may soon be.
    nonisolated var urgency: Int {
        switch self {
        case .blocked: 0
        case .working: 1
        case .idle: 2
        case .done: 3
        case .unknown: 4
        }
    }
}
