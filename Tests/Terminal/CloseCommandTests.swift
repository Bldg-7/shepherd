import SwiftUI

// Runtime launch/authentication is not exercised by deciding what ⌘W closes.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum CloseCommandTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func main() {
        let pane = AgentSummary(json: .object(["pane_id": .string("w1:p1"), "tab_id": .string("w1:t1"), "terminal_id": .string("terminal-1")]), on: nil)!
        let tab = TabSummary(tab: .object(["tab_id": .string("w1:t1"), "workspace_id": .string("w1"), "label": .string("Owned")]), layout: nil, panes: [pane.paneID: pane], on: nil)!

        let tabMode = CloseCommandTarget(selection: .tab(tab), showsTabs: true, coversTerminal: false)
        check(tabMode.closesTab && tabMode.item == .tab(tab), "Group by Tab on: ⌘W closes the selected tab")
        let paneMode = CloseCommandTarget(selection: .pane(pane), showsTabs: false, coversTerminal: false)
        check(!paneMode.closesTab && paneMode.item == .pane(pane), "Group by Tab off: ⌘W closes the selected pane")
        let oldHerdr = CloseCommandTarget(selection: .pane(pane), showsTabs: true, coversTerminal: false)
        check(!oldHerdr.closesTab && oldHerdr.item == .pane(pane), "pane rows kept in the tab mode close the pane")

        let noTab = CloseCommandTarget(selection: nil, showsTabs: true, coversTerminal: false)
        check(noTab.closesTab && noTab.item == nil, "nothing selected: Close Tab disabled")
        let noPane = CloseCommandTarget(selection: nil, showsTabs: false, coversTerminal: false)
        check(!noPane.closesTab && noPane.item == nil, "nothing selected: Close Pane disabled")

        let coveredTab = CloseCommandTarget(selection: .tab(tab), showsTabs: true, coversTerminal: true)
        check(coveredTab.closesTab && coveredTab.item == nil, "covered terminal: ⌘W closes nothing, title kept")
        let coveredPane = CloseCommandTarget(selection: .pane(pane), showsTabs: false, coversTerminal: true)
        check(!coveredPane.closesTab && coveredPane.item == nil, "covered terminal: ⌘W closes no pane")
        print("PASS \(checks) close command tab/pane/old herdr/no selection/covered terminal checks; snapshots only, no network")
    }
}
