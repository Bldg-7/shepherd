import Foundation

// Only AgentKind's runtime/launch dependencies are a seam; production JSON,
// pane/tab/session-reference models and title projection are compiled intact.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum PiTitleDisplayTests {
    static var checks = 0
    static func check(_ b: Bool) { precondition(b); checks += 1 }
    static func pane(_ terminal: String?, label: String? = nil, kind: String? = "pi", id: String = "p1") -> AgentSummary {
        var json: [String: JSONValue] = ["pane_id": .string(id), "terminal_id": .string("term-" + id), "tab_id": .string("t1"), "revision": .number(42), "cwd": .string("/owned/project"), "agent_status": .string("idle"), "agent_session": .object(["source": .string("herdr:pi"), "agent": .string("pi"), "kind": .string("id"), "value": .string("owned-session")])]
        if let terminal { json["terminal_title_stripped"] = .string(terminal) }
        if let label { json["label"] = .string(label) }
        if let kind { json["agent"] = .string(kind) }
        return AgentSummary(json: .object(json))!
    }
    static func tab(_ label: String, panes: [AgentSummary]) -> TabSummary {
        TabSummary(tab: .object(["tab_id": .string("t1"), "label": .string(label)]), layout: nil,
                   panes: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneID, $0) }), on: nil)!
    }
    static func main() {
        for (raw, expected) in [("π - project", "project"), ("π - named session - project", "named session - project"), ("pi - project", "project"), ("π - π - project", "π - project"), ("project pi - note", "project pi - note"), ("π - ", "π - "), ("π mathematics", "π mathematics"), ("pipeline - task", "pipeline - task"), ("PI - project", "PI - project")] {
            let value = pane(raw)
            check(value.title == expected)
            check(value.terminalTitle == raw)
            check(value.paneID == "p1" && value.terminalID == "term-p1" && value.revision == 42)
            check(value.sessionReference?.value == "owned-session")
        }
        check(pane("π - project", kind: "claude").title == "π - project")
        check(pane("pi - project", kind: "codex").title == "pi - project")
        check(pane("π - project", kind: nil).title == "π - project")
        check(pane("π - project", label: "π - user name").title == "π - user name")
        check(pane(nil).title == "pi")
        check(pane(nil, kind: nil).title == "p1")
        let pi = pane("π - project")
        let generated = tab("π - project", panes: [pi])
        check(generated.title == "project" && generated.label == "π - project")
        check(generated.panes[0] == pi && generated.tabID == "t1")
        check(tab("π - custom tab", panes: [pi]).title == "π - custom tab")
        check(tab("plain custom tab", panes: [pi]).title == "plain custom tab")
        check(tab("π - project", panes: [pane("π - project", label: "manual")]).title == "π - project")
        check(tab("π - project", panes: [pane("π - project", kind: "claude")]).title == "π - project")
        check(tab("π - project", panes: []).title == "π - project")
        check(tab("π - project", panes: [pi, pane("other", kind: "codex", id: "p2")]).title == "project")
        print("PASS \(checks) Pi display-prefix, custom-label, non-Pi, tab-caption and raw identity/session preservation checks; no Pi/user process changes")
    }
}
