import Foundation
import CoreGraphics

// Agent launches are not exercised: only the pane models need this.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

// The actual production store, request, model and pane/tab models; nothing
// is read: no store, reader, file, Keychain or network is used.
@main @MainActor enum PaneStatesTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static func pane(_ id: String, terminal: String, on machine: HerdrMachine? = nil) -> AgentSummary {
        AgentSummary(json: .object(["pane_id": .string(id), "tab_id": .string("w1:t1"), "terminal_id": .string(terminal),
                                    "cwd": .string("/owned")]), on: machine)!
    }

    static func main() {
        let host = Machine(displayName: "Owned Host", hostname: "owned.invalid", username: "owned")
        let other = Machine(displayName: "Owned Other", hostname: "other.invalid", username: "owned")
        let nested = HerdrMachine(id: "gpu", label: "GPU", target: "never-connect", session: "default", enabled: true)
        let p = pane("w1:p1", terminal: "term_p"), q = pane("w1:p2", terminal: "term_q")
        let nestedPane = pane("w1:p1", terminal: "term_n", on: nested)
        let pItem = TerminalIdentity(connection: host.connectionIdentity, itemID: p.id)
        let qItem = TerminalIdentity(connection: host.connectionIdentity, itemID: q.id)
        let nestedItem = TerminalIdentity(connection: host.connectionIdentity, itemID: nestedPane.id)
        check(pItem != nestedItem, "the same pane ID on a herdr machine is another pane")
        let states = FilePreviewPaneStates()

        // P's preview stays P's while Q is selected, and comes back as it was.
        let pRequest = FilePreviewRequest(machine: host, pane: p, link: "/owned/plan.md")
        states.open(pRequest, for: pItem)
        let pModel = states.entry(for: pItem, panes: [p])!.model
        pModel.showsSource = true; pModel.scrollOffset = CGPoint(x: 0, y: 300)
        let anchor = PreviewScrollAnchor(inSource: true, row: 12, offset: 7, height: 30)
        pModel.scrollAnchor = anchor
        check(states.entry(for: qItem, panes: [q]) == nil, "Q has no preview of its own")
        let back = states.entry(for: pItem, panes: [p])
        check(back?.request.id == pRequest.id && back?.isShown == true && back?.model === pModel, "P's preview comes back: file, shown, same read")
        check(back?.model.showsSource == true && back?.model.scrollOffset == CGPoint(x: 0, y: 300), "source choice and scroll place come back")

        // Q's own preview doesn't touch P's.
        let qRequest = FilePreviewRequest(machine: host, pane: q, link: "/owned/notes.md")
        states.open(qRequest, for: qItem)
        check(states.count == 2 && states.entry(for: pItem, panes: [p])?.model === pModel, "previews are kept per pane")
        check(states.entry(for: pItem, panes: [p])?.model.scrollAnchor == anchor && states.entry(for: qItem, panes: [q])?.model.scrollAnchor == nil, "each pane keeps only its own anchor")

        // Closing keeps the file for the toolbar; showing it again reads anew.
        states.hide(pItem)
        let closed = states.entry(for: pItem, panes: [p])
        check(closed?.isShown == false && closed?.request.id == pRequest.id && closed?.model !== pModel, "closed: file kept, read let go of")
        check(closed?.model.showsSource == false && closed?.model.scrollOffset == nil && closed?.model.scrollAnchor == nil, "a preview shown again starts afresh, as it always did")
        states.show(pItem)
        check(states.entry(for: pItem, panes: [p])?.isShown == true, "shown again")
        // A new file for P replaces its preview.
        let followed = pRequest.following("/owned/next.md", directory: "/owned")
        states.open(followed, for: pItem)
        check(states.entry(for: pItem, panes: [p])?.request.id == followed.id && states.count == 2, "a new file replaces the pane's preview")

        // A pane ID that now names another terminal is another pane.
        let reused = pane("w1:p1", terminal: "term_new")
        check(states.entry(for: pItem, panes: [reused]) == nil && states.isStale(pItem, panes: [reused]), "reused pane ID: not shown, stale")
        check(!states.isStale(pItem, panes: [p]) && !states.isStale(TerminalIdentity(connection: host.connectionIdentity, itemID: "none"), panes: []), "only a kept preview can be stale")

        // A tab's preview belongs to the tab while its pane is in it.
        let tabItem = TerminalIdentity(connection: host.connectionIdentity, itemID: "w1:t1")
        states.open(FilePreviewRequest(machine: host, pane: q, link: "/owned/tab.md"), for: tabItem)
        check(states.entry(for: tabItem, panes: [p, q]) != nil, "a tab's preview, opened from one of its panes")
        check(states.isStale(tabItem, panes: [p]), "its pane left the tab: stale")
        states.forget(tabItem)
        check(states.count == 2, "forgotten")

        // Panes the board no longer lists go; a herdr that couldn't be read keeps its own.
        states.open(FilePreviewRequest(machine: host, pane: nestedPane, link: "/owned/gpu.md"), for: nestedItem)
        let otherP = pane("w1:p1", terminal: "term_p")
        let otherItem = TerminalIdentity(connection: other.connectionIdentity, itemID: otherP.id)
        states.open(FilePreviewRequest(machine: other, pane: otherP, link: "/owned/other.md"), for: otherItem)
        check(states.count == 4, "four kept")
        states.forgetPanes(on: host.connectionIdentity, notIn: [])
        check(states.count == 4, "nothing read says nothing about any pane")
        states.forgetPanes(on: host.connectionIdentity, notIn: [p])
        check(states.entry(for: pItem, panes: [p]) != nil && states.entry(for: qItem, panes: [q]) == nil, "Q, no longer listed by its herdr, goes")
        check(states.entry(for: nestedItem, panes: [nestedPane]) != nil, "the herdr machine wasn't read: its preview stays")
        check(states.entry(for: otherItem, panes: [otherP]) != nil, "another machine's preview is left alone")
        states.forgetPanes(on: host.connectionIdentity, notIn: [p, pane("w1:p9", terminal: "term_9", on: nested)])
        check(states.entry(for: nestedItem, panes: [nestedPane]) == nil && states.count == 2, "read, and not listed: it goes")
        states.forgetPanes(on: host.connectionIdentity, notIn: [reused])
        check(states.entry(for: pItem, panes: [p]) == nil && states.count == 1, "a listed pane ID now on another terminal: it goes")

        // A machine that is removed, or edited into another connection, takes its previews.
        states.open(FilePreviewRequest(machine: host, pane: p, link: "/owned/plan.md"), for: pItem)
        states.forgetConnections(notIn: [host.connectionIdentity, other.connectionIdentity])
        check(states.count == 2, "both connections still there")
        var edited = other; edited.hostname = "moved.invalid"
        check(edited.connectionIdentity != other.connectionIdentity, "an edited endpoint is another connection")
        states.forgetConnections(notIn: [host.connectionIdentity, edited.connectionIdentity])
        check(states.count == 1 && states.entry(for: otherItem, panes: [otherP]) == nil, "the old connection's preview goes")
        print("PASS \(checks) actual pane-preview store checks: per pane and tab, kept across selection and machine switches, stale terminals, board and connection pruning; no reads")
    }
}
