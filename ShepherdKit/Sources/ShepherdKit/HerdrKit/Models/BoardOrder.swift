import Foundation

/// The order the board lists one workspace's rows in, pane rows or tab rows.
///
/// By status first, in `AgentState.urgency`'s order — Blocked, Done,
/// Working, Idle, then an agent herdr can't tell the status of — and after
/// them all the panes with no agent in them. Within a status, the agent that
/// came to it last goes first (see `AgentSummary.stateChangeSequence`), and
/// one that herdr doesn't say that for goes after those it does. Rows still
/// level keep the order herdr listed them in, so they don't trade places
/// from one refresh to the next.
///
/// The numbers of different herdrs say nothing of each other, but the board
/// never orders one herdr's rows among another's: each workspace is one
/// herdr's.
public nonisolated enum BoardOrder {
    public static func panes(_ panes: [AgentSummary]) -> [AgentSummary] {
        sorted(panes) { $0 }
    }

    /// Each tab goes where its leading pane would go, and a tab with no
    /// agent in it at the end.
    public static func tabs(_ tabs: [TabSummary]) -> [TabSummary] {
        sorted(tabs, by: leadingPane(of:))
    }

    /// Of the panes in the tab with an agent, the one listed first — the
    /// one whose status the tab's row shows (`TabSummary.mostUrgentState`).
    /// Nil for a tab with no agent in it.
    public static func leadingPane(of tab: TabSummary) -> AgentSummary? {
        panes(tab.panes.filter(\.hasAgent)).first
    }

    private static func sorted<Row>(_ rows: [Row], by pane: (Row) -> AgentSummary?) -> [Row] {
        rows.enumerated()
            .map { (row: $0.element, pane: pane($0.element), position: $0.offset) }
            .sorted { lhs, rhs in
                if rank(lhs.pane) != rank(rhs.pane) { return rank(lhs.pane) < rank(rhs.pane) }
                let lhsChange = lhs.pane?.stateChangeSequence, rhsChange = rhs.pane?.stateChangeSequence
                if lhsChange != rhsChange {
                    // A change herdr numbered before one it didn't, and a
                    // later one before an earlier.
                    guard let lhsChange else { return false }
                    guard let rhsChange else { return true }
                    return lhsChange > rhsChange
                }
                return lhs.position < rhs.position
            }
            .map(\.row)
    }

    /// The status, as `AgentState.urgency` ranks it, or one past them all
    /// for no agent.
    private static func rank(_ pane: AgentSummary?) -> Int {
        guard let pane, pane.hasAgent else { return AgentState.unknown.urgency + 1 }
        return pane.state.urgency
    }
}
