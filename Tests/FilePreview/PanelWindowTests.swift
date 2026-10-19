import SwiftUI
import AppKit

// The actual production panel, model, reader and store, shown in one owned
// window that is never ordered, activated or sent GUI input. Files are the
// runner's own; the local machine never reads a credential.
// Agent launches are not exercised: only the pane models need this.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}
final class OwnedSecrets: MachineSecretStore {
    func saveSecret(_ data: Data, tag: String) throws {}
    func loadSecret(tag: String) throws -> Data? { preconditionFailure("a local preview must not read a credential") }
    func deleteSecret(tag: String) throws {}
}

/// The panel as `ContentView.previewPanel` makes it: one view per preview.
struct PanelRoot: View {
    let entry: FilePreviewPaneStates.Entry?
    let store: MachineStore
    var expanded = false
    var body: some View {
        if let entry {
            FilePreviewPanel(request: entry.request, model: entry.model, machineStore: store, onClose: {}, onFileLink: { _ in })
                .previewExpansion(isExpanded: expanded, onToggle: {})
                .id(entry.model.id)
        } else {
            Color.clear
        }
    }
}

@main @MainActor enum PanelWindowTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
    }
    /// The preview's own scroll view: the one with the most to scroll.
    static func documentScroll(in view: NSView) -> NSScrollView? {
        scrollViews(in: view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    static func settle(_ view: NSView, seconds: Double = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return false
    }
    static func drain(_ view: NSView, _ turns: Int = 30) {
        for _ in 0..<turns { view.layoutSubtreeIfNeeded(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    static func text(_ model: FilePreviewModel) -> String? {
        if case .loaded(let document) = model.state, case .text(let text, _) = document.content { return text }
        return nil
    }
    static func pane(_ id: String, terminal: String, cwd: String) -> AgentSummary {
        AgentSummary(json: .object(["pane_id": .string(id), "terminal_id": .string(terminal), "cwd": .string(cwd)]), on: nil)!
    }
    /// Scrolls as a person would leave it: the clip view moved, which
    /// SwiftUI hears of as for a scroll wheel.
    static func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = ProcessInfo.processInfo.arguments[1]
        let longText = (1...240).map { "Paragraph \($0) of the owned plan, long enough to wrap once or twice in a side panel of this width." }.joined(separator: "\n\n")
        try Data(longText.utf8).write(to: URL(fileURLWithPath: directory + "/plan.md"))
        let notesText = (1...160).map { "- note \($0)" }.joined(separator: "\n")
        try Data(notesText.utf8).write(to: URL(fileURLWithPath: directory + "/notes.md"))
        let suite = "owned-panel-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = Machine(displayName: "Owned Local", hostname: "localhost", username: "owned", isLocal: true)
        let store = MachineStore(defaults: defaults, localMachine: local, keychain: OwnedSecrets())
        let p = pane("w1:p1", terminal: "term_p", cwd: directory), q = pane("w1:p2", terminal: "term_q", cwd: directory)
        let pItem = TerminalIdentity(connection: local.connectionIdentity, itemID: p.id)
        let qItem = TerminalIdentity(connection: local.connectionIdentity, itemID: q.id)
        let states = FilePreviewPaneStates()
        states.open(FilePreviewRequest(machine: local, pane: p, link: "plan.md"), for: pItem)
        states.open(FilePreviewRequest(machine: local, pane: q, link: "notes.md"), for: qItem)
        let pModel = states.entry(for: pItem, panes: [p])!.model, qModel = states.entry(for: qItem, panes: [q])!.model

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingController(rootView: PanelRoot(entry: nil, store: store))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 560, height: 420))
        func select(_ item: TerminalIdentity, _ pane: AgentSummary, expanded: Bool = false) {
            host.rootView = PanelRoot(entry: states.entry(for: item, panes: [pane]), store: store, expanded: expanded)
        }

        // P: read, laid out, scrolled down.
        select(pItem, p)
        check(settle(host.view) { text(pModel) == longText }, "P's file is read once it is shown")
        check(settle(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 2000 }, "P's document is laid out")
        scroll(documentScroll(in: host.view)!, to: 900)
        check(settle(host.view) { abs((pModel.scrollOffset?.y ?? 0) - 900) < 1 }, "P's scroll place is kept with P as it scrolls")
        // The file changes while P isn't selected; what was read stays P's.
        try Data("# Changed while away".utf8).write(to: URL(fileURLWithPath: directory + "/plan.md"))

        // Q: its own read, at its own top, P's place untouched.
        select(qItem, q)
        check(settle(host.view) { text(qModel) == notesText }, "Q's file is read once it is shown")
        drain(host.view)
        check(abs(documentScroll(in: host.view)!.contentView.bounds.origin.y) < 1, "Q starts at its top, not at P's place")
        check(abs((pModel.scrollOffset?.y ?? 0) - 900) < 1, "leaving P doesn't move P's kept place")
        // Q shows its source, scrolled down a little.
        qModel.showsSource = true
        check(settle(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 1500 }, "Q's source is laid out")
        scroll(documentScroll(in: host.view)!, to: 400)
        check(settle(host.view) { abs((qModel.scrollOffset?.y ?? 0) - 400) < 1 }, "Q's scroll place is kept in source too")

        // Back to P, expanded or not: as it was left, without reading again.
        select(pItem, p)
        check(text(pModel) == longText && !pModel.showsSource, "P comes back with what was read, rendered: no new read")
        check(settle(host.view) { abs((documentScroll(in: host.view)?.contentView.bounds.origin.y ?? 0) - 900) < 2 }, "P comes back at its scroll place")
        drain(host.view)
        check(text(pModel) == longText, "still not read again once shown")
        check(abs((qModel.scrollOffset?.y ?? 0) - 400) < 1 && qModel.showsSource, "leaving Q keeps its source choice and place")

        // Back to Q: its source, at its place.
        select(qItem, q, expanded: true)
        check(settle(host.view) { abs((documentScroll(in: host.view)?.contentView.bounds.origin.y ?? 0) - 400) < 2 }, "Q comes back in source at its place")
        check(qModel.showsSource && text(qModel) == notesText, "Q's source choice and read are kept")
        // From an expanded preview to another pane's and back.
        select(pItem, p)
        check(settle(host.view) { abs((documentScroll(in: host.view)?.contentView.bounds.origin.y ?? 0) - 900) < 2 }, "P again, at its place after Q was expanded")

        // Closed and shown again, the file is read again, as it always was:
        // whether the closed panel was taken off screen in between or not.
        check(states.entry(for: pItem, panes: [p])?.model === pModel, "P's model is the one kept")
        states.hide(pItem)
        host.rootView = PanelRoot(entry: nil, store: store)
        drain(host.view)
        states.show(pItem)
        let reopened = states.entry(for: pItem, panes: [p])!.model
        select(pItem, p)
        check(settle(host.view) { text(reopened) == "# Changed while away" }, "closed and shown again, the file is read again, as before")
        check(reopened.scrollOffset == nil || abs(reopened.scrollOffset!.y) < 1, "and starts at its top")
        try Data("# Changed again".utf8).write(to: URL(fileURLWithPath: directory + "/plan.md"))
        states.hide(pItem); states.show(pItem)
        let again = states.entry(for: pItem, panes: [p])!.model
        select(pItem, p)
        check(settle(host.view) { text(again) == "# Changed again" }, "also when the panel stayed on screen in between")
        host.rootView = PanelRoot(entry: nil, store: store)
        drain(host.view)
        print("PASS \(checks) actual preview panel checks in an owned never-shown window: per-pane read, source and scroll kept across P→Q→P, no reread, no scroll carried between panes")
    }
}
