import Foundation

// Only AgentKind's runtime/launch dependencies are a seam; the production
// pane, tab and herdr machine models and the seen rule are compiled intact.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum SeenMarkingTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static let remote = HerdrMachine(id: "owned-remote", label: "Owned", target: "owned-invalid", session: "default", enabled: true)
    static func pane(_ id: String, tab: String? = "w1:t1", status: String? = "done", agent: String? = "claude", title: String = "Owned", revision: Double = 1, on machine: HerdrMachine? = nil) -> AgentSummary {
        var json: [String: JSONValue] = ["pane_id": .string(id), "terminal_id": .string("term-" + id), "workspace_id": .string("w1"),
                                         "terminal_title_stripped": .string(title), "revision": .number(revision)]
        if let tab { json["tab_id"] = .string(tab) }
        if let status { json["agent_status"] = .string(status) }
        if let agent { json["agent"] = .string(agent) }
        return AgentSummary(json: .object(json), on: machine)!
    }
    static func tab(_ panes: [AgentSummary], id: String = "w1:t1", on machine: HerdrMachine? = nil) -> TabSummary {
        TabSummary(tab: .object(["tab_id": .string(id), "workspace_id": .string("w1"), "label": .string("Owned")]), layout: nil,
                   panes: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) }), on: machine)!
    }
    static func seen(_ pane: AgentSummary, key: Bool = true) -> SeenRequest? { SeenMarking.request(forPane: pane, windowIsKey: key) }
    static func seen(_ tab: TabSummary, key: Bool = true) -> SeenRequest? { SeenMarking.request(forTab: tab, windowIsKey: key) }

    static func main() {
        let done = pane("w1:p1")
        let hostTab = SeenRequest(tabID: "w1:t1", herdrMachine: nil)
        check(seen(done) == hostTab, "Done pane: its tab, on the host's herdr")
        for status in ["idle", "working", "blocked", "unknown"] {
            check(seen(pane("w1:p1", status: status)) == nil, status + " pane: nothing sent")
        }
        check(seen(pane("w1:p1", status: nil)) == nil, "pane with no status: nothing sent")
        check(seen(pane("w1:p1", status: "done", agent: nil)) == nil, "done but no agent, so no Done shown: nothing sent")
        check(seen(pane("w1:p1", tab: nil)) == nil, "Done pane without a tab_id: nothing sent")
        check(seen(done, key: false) == nil, "window not key: nothing sent until it is")

        check(seen(pane("w1:p1", title: "Renamed", revision: 9)) == seen(done), "a refreshed snapshot of the same Done pane: the same request, not sent again")
        check(seen(pane("w1:p2")) == seen(done), "two Done panes in one tab: one request")
        check(seen(pane("w1:p3", tab: "w1:t2")) == SeenRequest(tabID: "w1:t2", herdrMachine: nil), "a Done pane in another tab: that tab")

        let remoteDone = pane("w1:p1", on: remote)
        check(seen(remoteDone) == SeenRequest(tabID: "w1:t1", herdrMachine: remote), "Done pane on a herdr machine: its tab there")
        check(seen(remoteDone) != seen(done), "the same IDs on the host and on a herdr machine: different requests")

        check(seen(tab([done])) == hostTab, "Group by Tab: a tab with a Done pane")
        let mixed = tab([pane("w1:p1", status: "working"), pane("w1:p2"), pane("w1:p3", status: "unknown", agent: nil)])
        check(mixed.mostUrgentState == .working && seen(mixed) == hostTab, "a tab with one Done pane among others, whatever state its row shows")
        check(seen(tab([pane("w1:p1", status: "idle"), pane("w1:p2", status: "blocked")])) == nil, "a tab with no Done pane: nothing sent")
        check(seen(tab([pane("w1:p1", status: "done", agent: nil)])) == nil, "a tab with only a shell: nothing sent")
        check(seen(tab([])) == nil, "a tab with no panes listed: nothing sent")
        check(seen(tab([done]), key: false) == nil, "tab, window not key: nothing sent until it is")
        check(seen(tab([pane("w1:p1", on: remote)], on: remote)) == SeenRequest(tabID: "w1:t1", herdrMachine: remote), "a tab on a herdr machine: that tab there")
        check(seen(tab([done, pane("w1:p2")])) == seen(done), "Group by Tab on and off ask for the same tab")
        print("PASS \(checks) seen-marking checks: Done pane/tab, other states, no agent, no tab_id, window not key, refresh, same tab, host and herdr machine; models only, no network")
    }
}
