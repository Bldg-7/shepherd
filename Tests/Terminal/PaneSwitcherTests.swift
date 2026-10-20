import SwiftUI

// Runtime launch/authentication is not exercised by snapshot-only navigation.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum PaneSwitcherTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func main() {
        func pane(_ terminal: String, on machine: HerdrMachine? = nil) -> AgentSummary {
            AgentSummary(json: .object(["pane_id": .string("w1:p1"), "tab_id": .string("w1:t1"), "terminal_id": .string(terminal), "terminal_title_stripped": .string("π - 작업"), "agent": .string("pi"), "cwd": .string("/owned/Projects/demo"), "agent_status": .string("idle")]), on: machine)!
        }
        let hostPane = pane("terminal-1")
        let host = PaneDestination(pane: hostPane, item: .pane(hostPane), location: "This Mac · Workspace A", isAvailable: true)
        check(host.matches(""), "empty query lists panes")
        check(host.matches("pi demo"), "all query words match agent/cwd across fields")
        check(host.matches("작업 Workspace"), "localized title + workspace search")
        check(host.matches("w1:p1"), "pane ID searchable")
        check(!host.matches("pi missing"), "AND search narrows result")
        let remote = HerdrMachine(id: "other", label: "Other", target: "never-connect", session: "default", enabled: true)
        let remotePane = pane("terminal-1", on: remote)
        let nested = PaneDestination(pane: remotePane, item: .pane(remotePane), location: "Other", isAvailable: true)
        check(host.id != nested.id, "nested herdr pane IDs never collide")
        check(PaneDestination.resolve(host, in: [nested], contextMatches: true) == nil, "same raw pane/terminal on other herdr must not route")
        check(PaneDestination.resolve(host, in: [host], contextMatches: false) == nil, "machine/endpoint/session/auth change denies stale destination")
        check(PaneDestination.resolve(host, in: [], contextMatches: true) == nil, "closed pane denied")
        let replacement = pane("terminal-2")
        let reused = PaneDestination(pane: replacement, item: .pane(replacement), location: "Host", isAvailable: true)
        check(PaneDestination.resolve(host, in: [reused], contextMatches: true) == nil, "reused pane ID with new terminal denied")
        let unavailable = PaneDestination(pane: hostPane, item: .pane(hostPane), location: "Host", isAvailable: false)
        check(PaneDestination.resolve(host, in: [unavailable], contextMatches: true) == nil, "disconnected stale snapshot not selected")
        let tab = TabSummary(tab: .object(["tab_id": .string("w1:t1"), "label": .string("Owned")]), layout: nil, panes: [hostPane.paneID: hostPane], on: nil)!
        let grouped = PaneDestination(pane: hostPane, item: .tab(tab), location: "Host", isAvailable: true)
        let result = PaneDestination.resolve(host, in: [grouped], contextMatches: true)!
        if case .tab = result.item { checks += 1 } else { preconditionFailure("latest grouped-tab destination used") }
        check(result.pane.id == host.id, "grouped choice retains exact pane for keyboard focus")
        let a = TerminalPaneFocus(paneID: host.id), b = TerminalPaneFocus(paneID: host.id)
        check(a != b && a.paneID == b.paneID, "same-pane repeated navigation has fresh focus request without attach recreation")
        print("PASS \(checks) pane search/machine+nested identity/stale terminal/disconnection/tab destination/repeated focus checks; snapshots only, no network")
    }
}
