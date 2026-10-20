import Foundation

/// A tab to tell herdr has been looked at (see `HerdrClient.focusTab`), on
/// the herdr it is in.
public nonisolated struct SeenRequest: Hashable, Sendable {
    public let tabID: String
    /// The herdr machine the tab is on, or nil for the host's own herdr.
    public let herdrMachine: HerdrMachine?
}

/// Whether what is selected on the board is to be marked as seen in herdr.
///
/// herdr reports an agent that has finished as `done` until it is looked at,
/// and as `idle` after. Only herdr's own view, or a focus request, counts as
/// looking: attaching to the pane's terminal, which is all selecting it on
/// the board does otherwise, doesn't. So a finished agent read in Shepherd
/// stayed Done until it was given more work.
///
/// herdr keeps what has been seen per tab, so the request is for the tab
/// the selection is in, and marks every finished agent in it seen at once.
/// It is only asked for while there is something to mark — a done agent in
/// what is selected — since each request moves herdr's own view, and to a
/// herdr machine or over SSH costs a connection of its own. And only while
/// the window is key: a selection left on a pane whose agent finishes behind
/// another app's window isn't being looked at, until the person comes back.
public nonisolated enum SeenMarking {
    /// For a selected pane: its tab, when its agent is done.
    public static func request(forPane pane: AgentSummary, windowIsKey: Bool) -> SeenRequest? {
        guard windowIsKey, isDone(pane), let tabID = pane.tabID else { return nil }
        return SeenRequest(tabID: tabID, herdrMachine: pane.herdrMachine)
    }

    /// For a selected tab: the tab, when the agent in any of its panes is
    /// done — whichever state its row shows.
    public static func request(forTab tab: TabSummary, windowIsKey: Bool) -> SeenRequest? {
        guard windowIsKey, tab.panes.contains(where: isDone) else { return nil }
        return SeenRequest(tabID: tab.tabID, herdrMachine: tab.herdrMachine)
    }

    /// Done as the board shows it: only a pane with an agent in it has a
    /// status to show (herdr reports `unknown` for the others).
    private static func isDone(_ pane: AgentSummary) -> Bool {
        pane.hasAgent && pane.state == .done
    }
}
