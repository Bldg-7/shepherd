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

/// Whether the board lists tabs rather than panes. The key keeps the name it
/// was stored under, so the choice a person made carries over.
enum BoardDisplayPreferences {
    static let showsTabsKey = "AgentBoardView.showsTabs"
}
