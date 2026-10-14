import Foundation

// Only AgentKind's runtime/launch dependencies are a seam; the production
// pane, tab and snapshot models and the board's order are compiled intact.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum BoardOrderTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static let remote = HerdrMachine(id: "owned-remote", label: "Owned", target: "owned-invalid", session: "default", enabled: true)

    /// A pane row as `session.snapshot` gives it: no `state_change_seq` of
    /// its own, unless `ownSequence`.
    static func paneJSON(_ id: String, _ status: String?, agent: String? = "claude", tab: String = "w1:t1", ownSequence: Int? = nil) -> JSONValue {
        var json: [String: JSONValue] = ["pane_id": .string(id), "terminal_id": .string("term-" + id), "tab_id": .string(tab), "workspace_id": .string("w1"),
                                         "terminal_title_stripped": .string("Owned"), "revision": .number(1)]
        if let status { json["agent_status"] = .string(status) }
        if let agent { json["agent"] = .string(agent) }
        if let ownSequence { json["state_change_seq"] = .number(Double(ownSequence)) }
        return .object(json)
    }
    /// A pane as the board gets it, with `seq` from its agent's entry.
    static func pane(_ id: String, _ status: String? = "idle", seq: Int? = nil, agent: String? = "claude", tab: String = "w1:t1") -> AgentSummary {
        AgentSummary(json: paneJSON(id, status, agent: agent, tab: tab), stateChangeSequence: seq)!
    }
    static func shell(_ id: String, tab: String = "w1:t1") -> AgentSummary { pane(id, "unknown", agent: nil, tab: tab) }
    static func tab(_ id: String, _ panes: [AgentSummary]) -> TabSummary {
        TabSummary(tab: .object(["tab_id": .string(id), "workspace_id": .string("w1"), "label": .string(id)]), layout: nil,
                   panes: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) }), on: nil)!
    }
    static func ids(_ panes: [AgentSummary]) -> [String] { panes.map(\.paneID) }
    static func ids(_ tabs: [TabSummary]) -> [String] { tabs.map(\.tabID) }
    /// `panes` with the one whose ID is `id` replaced by `changed`, where it was.
    static func replacing(_ id: String, with changed: AgentSummary, in panes: [AgentSummary]) -> [AgentSummary] {
        panes.map { $0.paneID == id ? changed : $0 }
    }

    static func main() {
        // Status first: Blocked, Done, Working, Idle, an agent of unknown
        // status, and the panes with no agent — whatever herdr says of those.
        check([AgentState.blocked, .done, .working, .idle, .unknown].map(\.urgency) == [0, 1, 2, 3, 4], "urgency: blocked, done, working, idle, unknown")
        let byStatus = [pane("p1", "idle"), shell("p2"), pane("p3", "working"), pane("p4", "unknown"), pane("p5", "done"), pane("p6", "blocked"), pane("p7", "done", agent: nil)]
        check(ids(BoardOrder.panes(byStatus)) == ["p6", "p5", "p3", "p1", "p4", "p2", "p7"], "status order: Blocked, Done, Working, Idle, unknown, no agent")
        check(ids(BoardOrder.panes([pane("p1", "idle", seq: 99), pane("p2", "working", seq: 98), pane("p3", "blocked", seq: 1)])) == ["p3", "p2", "p1"], "status before recency")

        // Within a status, the latest change first.
        check(ids(BoardOrder.panes([pane("p1", "done", seq: 10), pane("p2", "done", seq: 30), pane("p3", "done", seq: 20)])) == ["p2", "p3", "p1"], "same status: latest change first")
        check(ids(BoardOrder.panes([pane("p1", "idle", seq: 0), pane("p2", "idle", seq: 1)])) == ["p2", "p1"], "seq 0 is a known change, the earliest")

        // A change herdr doesn't give a number for goes after those it does,
        // within its own status only.
        let unknownChange = [pane("p1", "done"), pane("p2", "done", seq: 5), pane("p3", "done"), pane("p4", "done", seq: 7), pane("p5", "working", seq: 100), pane("p6", "blocked")]
        check(ids(BoardOrder.panes(unknownChange)) == ["p6", "p4", "p2", "p1", "p3", "p5"], "unknown change: after the known ones of its status, before the next status")

        // Still level: herdr's order, either way round.
        let level = [pane("p1"), pane("p2"), pane("p3", seq: 4), pane("p4", seq: 4), shell("p5"), shell("p6")]
        check(ids(BoardOrder.panes(level)) == ["p3", "p4", "p1", "p2", "p5", "p6"], "level rows: herdr's order")
        check(ids(BoardOrder.panes(level.reversed())) == ["p4", "p3", "p2", "p1", "p6", "p5"], "level rows, listed the other way: that order")
        check(BoardOrder.panes([]).isEmpty && BoardOrder.tabs([]).isEmpty, "nothing to order")

        // One agent's status changes: it goes to the top of its new status,
        // and every other row keeps its place relative to the rest.
        let board = [pane("i2", "idle", seq: 10), pane("w1", "working", seq: 45), shell("s1"), pane("d2", "done", seq: 30), pane("b1", "blocked", seq: 50),
                     pane("i3", "idle"), pane("w2", "working", seq: 20), pane("d1", "done", seq: 40), pane("i1", "idle", seq: 35)]
        let before = BoardOrder.panes(board)
        check(ids(before) == ["b1", "d1", "d2", "w1", "w2", "i1", "i2", "i3", "s1"], "the board before")
        for (id, status, expected) in [("w2", "done", ["b1", "w2", "d1", "d2", "w1", "i1", "i2", "i3", "s1"]),
                                        ("i2", "working", ["b1", "d1", "d2", "i2", "w1", "w2", "i1", "i3", "s1"]),
                                        ("d1", "idle", ["b1", "d2", "w1", "w2", "d1", "i1", "i2", "i3", "s1"]),
                                        ("i3", "blocked", ["i3", "b1", "d1", "d2", "w1", "w2", "i1", "i2", "s1"])] {
            let after = BoardOrder.panes(replacing(id, with: pane(id, status, seq: 51), in: board))
            check(ids(after) == expected, id + " to " + status + ": to the top of " + status)
            check(ids(after).filter { $0 != id } == ids(before).filter { $0 != id }, id + " to " + status + ": no other row moves")
        }
        let unchanged = BoardOrder.panes(replacing("w1", with: pane("w1", "working", seq: 45, tab: "w1:t1"), in: board))
        check(ids(unchanged) == ids(before), "a refresh with nothing changed: no row moves")

        // Group by Tab: each tab by its leading pane — of those with an agent,
        // the one the order puts first — whose status its row shows.
        let working = tab("t1", [pane("a1", "idle", seq: 50, tab: "t1"), pane("a2", "working", seq: 10, tab: "t1"), shell("a3", tab: "t1")])
        let twoDone = tab("t2", [pane("b1", "done", seq: 9, tab: "t2"), pane("b2", "done", seq: 5, tab: "t2")])
        let shellOnly = tab("t3", [shell("c1", tab: "t3")])
        let workingAndDone = tab("t4", [pane("d1", "working", seq: 70, tab: "t4"), pane("d2", "done", seq: 2, tab: "t4")])
        let empty = tab("t5", [])
        let blocked = tab("t6", [pane("f1", "blocked", seq: 1, tab: "t6"), pane("f2", "done", seq: 80, tab: "t6")])
        let recentWorking = tab("t7", [pane("g1", "working", seq: 30, tab: "t7")])
        check(BoardOrder.leadingPane(of: working)?.paneID == "a2" && working.mostUrgentState == .working, "leading pane: the working one, not the idle one changed later")
        check(BoardOrder.leadingPane(of: twoDone)?.paneID == "b1", "leading pane: of two Done, the one changed later")
        check(BoardOrder.leadingPane(of: workingAndDone)?.paneID == "d2" && workingAndDone.mostUrgentState == .done, "Working and Done in one tab: Done leads, and the row shows Done")
        check(BoardOrder.leadingPane(of: shellOnly) == nil && shellOnly.mostUrgentState == nil, "no agent in the tab: no leading pane")
        check(BoardOrder.leadingPane(of: empty) == nil, "no panes listed: no leading pane")
        let tabs = [shellOnly, working, empty, twoDone, workingAndDone, blocked, recentWorking]
        for tab in tabs { check(tab.mostUrgentState == BoardOrder.leadingPane(of: tab)?.state, tab.tabID + ": the row shows its leading pane's status") }
        check(ids(BoardOrder.tabs(tabs)) == ["t6", "t2", "t4", "t7", "t1", "t3", "t5"], "tabs by leading pane, tabs with no agent last in herdr's order")
        check(ids(BoardOrder.tabs(tabs.reversed())) == ["t6", "t2", "t4", "t7", "t1", "t5", "t3"], "tabs with no agent, listed the other way: that order")
        let movedTab = tab("t1", [pane("a1", "idle", seq: 50, tab: "t1"), pane("a2", "done", seq: 81, tab: "t1"), shell("a3", tab: "t1")])
        let tabsAfter = BoardOrder.tabs(tabs.map { $0.tabID == "t1" ? movedTab : $0 })
        check(ids(tabsAfter) == ["t6", "t1", "t2", "t4", "t7", "t3", "t5"], "a pane in a tab finishes: the tab to the top of Done")
        check(ids(tabsAfter).filter { $0 != "t1" } == ids(BoardOrder.tabs(tabs)).filter { $0 != "t1" }, "no other tab moves")

        // The snapshot: panes get their agent's state_change_seq from
        // `agents`, by pane ID; without `agents`, none.
        let panes: [JSONValue] = [paneJSON("w1:p1", "working"), paneJSON("w1:p2", "done"), paneJSON("w1:p3", "unknown", agent: nil), paneJSON("w1:p4", "working"),
                                  paneJSON("w1:p5", "idle", ownSequence: 77), paneJSON("w1:p6", "idle")]
        let agents: [JSONValue] = [.object(["pane_id": .string("w1:p1"), "terminal_id": .string("term-w1:p1"), "agent_status": .string("working"), "state_change_seq": .number(15)]),
                                   .object(["pane_id": .string("w1:p2"), "state_change_seq": .number(12)]),
                                   .object(["pane_id": .string("w1:p4"), "state_change_seq": .number(20)]),
                                   .object(["pane_id": .string("w1:p5"), "state_change_seq": .number(3)]),
                                   .object(["pane_id": .string("w1:p6")]),
                                   .object(["pane_id": .string("w1:p9"), "state_change_seq": .number(99)]),
                                   .object(["state_change_seq": .number(98)])]
        func snapshot(agents: [JSONValue]?, on machine: HerdrMachine? = nil) -> HerdrSnapshot {
            var json: [String: JSONValue] = ["panes": .array(panes),
                                             "workspaces": .array([.object(["workspace_id": .string("w1"), "label": .string("Owned")])]),
                                             "tabs": .array([.object(["tab_id": .string("w1:t1"), "workspace_id": .string("w1"), "label": .string("Owned")])])]
            if let agents { json["agents"] = .array(agents) }
            return HerdrSnapshot(snapshot: .object(json), on: machine)
        }
        func sequences(_ panes: [AgentSummary]) -> [String: Int?] {
            Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0.stateChangeSequence) })
        }
        let merged = snapshot(agents: agents)
        let expected: [String: Int?] = ["w1:p1": 15, "w1:p2": 12, "w1:p3": nil, "w1:p4": 20, "w1:p5": 77, "w1:p6": nil]
        check(ids(merged.panes) == ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5", "w1:p6"], "snapshot: the panes, in herdr's order, and no pane for an agent's entry alone")
        check(sequences(merged.panes) == expected, "snapshot: each pane's seq from its agent's entry; none for no agent or none given; a pane's own wins")
        check(sequences(merged.tabs?.first?.panes ?? []) == expected, "snapshot: the tabs' panes carry it too")
        check(ids(BoardOrder.panes(merged.panes)) == ["w1:p2", "w1:p4", "w1:p1", "w1:p5", "w1:p6", "w1:p3"], "snapshot to board: the later of two working agents first")
        let onMachine = snapshot(agents: agents, on: remote)
        check(sequences(onMachine.panes) == expected && onMachine.panes.allSatisfy { $0.herdrMachine == remote }, "snapshot from a herdr machine: the same")
        let withoutAgents = snapshot(agents: nil)
        check(withoutAgents.panes.filter { $0.paneID != "w1:p5" }.allSatisfy { $0.stateChangeSequence == nil }, "snapshot with no agents: no seq")
        check(ids(BoardOrder.panes(withoutAgents.panes)) == ["w1:p2", "w1:p1", "w1:p4", "w1:p5", "w1:p6", "w1:p3"], "snapshot with no agents: by status, then herdr's order")
        check(snapshot(agents: []).panes.allSatisfy { $0.paneID == "w1:p5" || $0.stateChangeSequence == nil }, "snapshot with an empty agents: no seq")
        check(AgentSummary(json: paneJSON("p1", "idle"))!.stateChangeSequence == nil, "a pane row alone, as pane.list gives it to a herdr too old for a snapshot: no seq")

        print("PASS \(checks) board-order checks: status order, latest change first, unknown change, level rows, one row moving, tabs by leading pane, agents' seq merged into the snapshot's panes; models only, no herdr")
    }
}
