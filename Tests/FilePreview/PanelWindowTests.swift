import SwiftUI
import AppKit

// The actual production panel, model, reader and store, shown in one owned
// window that is never ordered, activated or sent GUI input. Files are the
// runner's own; the local machine never reads a credential.
// Agent launches are not exercised: only the pane models need this.
public nonisolated enum AgentKind: String, Sendable {
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

/// Stands in for a terminal beside the preview: an AppKit view that takes
/// the keyboard.
final class OwnedTerminal: NSView {
    override var acceptsFirstResponder: Bool { true }
}
final class CloseCount { var count = 0 }

/// The panel at the side, as `ContentView.previewPanel` makes it, its
/// closes counted.
struct FindRoot: View {
    let entry: FilePreviewPaneStates.Entry?
    let store: MachineStore
    let closes: CloseCount
    var expanded = false
    var body: some View {
        if let entry {
            FilePreviewPanel(request: entry.request, model: entry.model, machineStore: store, onClose: { closes.count += 1 }, onFileLink: { _ in })
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

    /// The panel's accessibility elements that have an identifier, as
    /// VoiceOver would find them.
    static func accessibility(_ view: NSView) -> [String: NSObject] {
        var found: [String: NSObject] = [:]
        func walk(_ node: AnyObject, _ depth: Int) {
            guard depth < 60 else { return }
            if let element = node as? NSAccessibilityElementProtocol, let id = element.accessibilityIdentifier?(), !id.isEmpty,
               let object = node as? NSObject { found[id] = object }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
        }
        walk(view, 0)
        return found
    }
    static func label(_ element: NSObject) -> String? { element.value(forKey: "accessibilityLabel") as? String }
    static func isSelected(_ element: NSObject) -> Bool { (element.value(forKey: "accessibilitySelected") as? Bool) ?? false }
    /// What the table of contents lists, top to bottom, and which of it is
    /// marked as where the reader is.
    static func outline(_ view: NSView) -> (titles: [String], marked: [String]) {
        let items = accessibility(view).filter { $0.key.hasPrefix("preview.outline.") && $0.key != "preview.outline.toggle" }
            .sorted { Int($0.key.dropFirst("preview.outline.".count))! < Int($1.key.dropFirst("preview.outline.".count))! }
        return (items.compactMap { label($0.value) }, items.filter { isSelected($0.value) }.compactMap { label($0.value) })
    }
    /// Chooses an element as VoiceOver's press does: a click's action
    /// without a click, which a window that is never shown can't take.
    static func press(_ element: NSObject?) -> Bool {
        guard let element, element.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
        return true
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
        let previewChecks = checks
        try tableOfContents(directory: directory, store: store, local: local, states: states, host: host)
        let outlineChecks = checks - previewChecks
        try find(directory: directory, store: store, local: local, states: states)
        let findChecks = checks - previewChecks - outlineChecks
        try reload(directory: directory, store: store, local: local, states: states)
        print("PASS \(checks) actual preview panel checks in an owned never-shown window: per-pane read, source and scroll kept across P→Q→P, no reread, no scroll carried between panes (\(previewChecks)); the Markdown table of contents (\(outlineChecks)); find, ⌘F beside a terminal (\(findChecks)); reload, ⌘R beside a terminal (\(checks - previewChecks - outlineChecks - findChecks))")
    }

    /// The table of contents of a Markdown preview, read and chosen through
    /// the accessibility the panel gives VoiceOver. It is turned on for this
    /// process only, after the checks above, which ran without it.
    static func tableOfContents(directory: String, store: MachineStore, local: Machine, states: FilePreviewPaneStates,
                                host: NSHostingController<PanelRoot>) throws {
        let enable = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        check(NSApp.responds(to: enable), "this process can turn its own accessibility on")
        _ = NSApp.perform(enable, with: NSNumber(value: true), with: "AXEnhancedUserInterface" as NSString)

        func section(_ name: String, _ count: Int) -> String {
            (1...count).map { "Paragraph \($0) about \(name), long enough to wrap once or twice in a side panel of this width." }.joined(separator: "\n\n")
        }
        let guide = "---\ntitle: Owned guide\n---\n# Deploy guide\n\n" + section("the deploy", 6)
            + "\n\n## Install\n\n" + section("installing", 12) + "\n\n```sh\n# not a heading\n```\n\n## Configure **secrets**\n\n"
            + section("configuring", 12) + "\n\n### Secrets\n\n" + section("secrets", 12) + "\n\nRollback\n--------\n\n"
            + section("rolling back", 12) + "\n\n## [](#empty)\n\n" + section("nothing", 4) + "\n\n# Appendix\n\n" + section("the rest", 12)
        try Data(guide.utf8).write(to: URL(fileURLWithPath: directory + "/guide.md"))
        try Data("Just a paragraph.\n\nAnd another, with no heading.".utf8).write(to: URL(fileURLWithPath: directory + "/plain.md"))
        try Data("# Not Markdown here\nplain text".utf8).write(to: URL(fileURLWithPath: directory + "/notes.txt"))
        // Every block but the last few the same height: a document whose
        // scroll place this harness puts back exactly. One with headings of
        // their own sizes higher up comes back some points off, with or
        // without this change: the lazy stack's estimates.
        let tail = section("the plan", 240) + "\n\n## Tail\n\n" + section("the tail", 10)
        try Data(tail.utf8).write(to: URL(fileURLWithPath: directory + "/tail.md"))
        let titles = ["Deploy guide", "Install", "Configure secrets", "Secrets", "Rollback", "Appendix"]
        let headings = PreviewMarkdownDocument(guide).headings
        check(headings.map(\.title) == titles, "the guide's headings")
        func heading(_ title: String) -> PreviewMarkdownHeading { headings.first { $0.title == title }! }
        let sourceLines = guide.components(separatedBy: "\n")

        let r = pane("w1:p3", terminal: "term_r", cwd: directory), s = pane("w1:p4", terminal: "term_s", cwd: directory)
        let rItem = TerminalIdentity(connection: local.connectionIdentity, itemID: r.id)
        let sItem = TerminalIdentity(connection: local.connectionIdentity, itemID: s.id)
        func select(_ item: TerminalIdentity, _ pane: AgentSummary, expanded: Bool = false) {
            host.rootView = PanelRoot(entry: states.entry(for: item, panes: [pane]), store: store, expanded: expanded)
        }
        func outlineShown() -> [String] { outline(host.view).titles }
        func item(_ title: String) -> NSObject? { accessibility(host.view)["preview.outline.\(heading(title).id)"] }
        func toggle() -> NSObject? { accessibility(host.view)["preview.outline.toggle"] }
        func toggleIsOn() -> Bool { (toggle()?.value(forKey: "accessibilityValue") as? NSNumber)?.boolValue ?? false }
        func toggleIsEnabled() -> Bool { (toggle()?.value(forKey: "accessibilityEnabled") as? Bool) ?? false }
        func help() -> String? { toggle()?.value(forKey: "accessibilityHelp") as? String }

        // R: a Markdown file with headings.
        states.open(FilePreviewRequest(machine: local, pane: r, link: "guide.md"), for: rItem)
        let rModel = states.entry(for: rItem, panes: [r])!.model
        select(rItem, r)
        check(settle(host.view) { text(rModel) == guide }, "R's guide is read")
        check(rModel.showsOutline, "a Markdown preview starts with its table of contents on")
        check(settle(host.view) { outlineShown() == titles },
              "it lists the six headings by their plain names, not the fenced # or the heading that shows nothing")
        check(toggle() != nil && toggleIsEnabled() && toggleIsOn(), "the header's table of contents button is there, enabled and on")
        check(label(toggle()!) == "Table of Contents" && help() == "Hide Table of Contents", "named for VoiceOver, its help saying what it does")
        check(settle(host.view) { rModel.visibleBlocks.first == 0 } && outline(host.view).marked.isEmpty,
              "at the top, the rendering shows the frontmatter first, before any heading: nothing is marked")

        // Choosing a heading brings it to the top of the rendering, and marks it.
        check(press(item("Rollback")), "Rollback can be chosen")
        check(settle(host.view) { rModel.visibleBlocks.first == heading("Rollback").id }, "choosing Rollback brings its heading to the top of the rendering")
        check(settle(host.view) { outline(host.view).marked == ["Rollback"] }, "and marks it as where the reader is")
        check((rModel.scrollOffset?.y ?? 0) > 1000, "the scroll place kept is the heading's")
        check(press(item("Install")) && settle(host.view) { rModel.visibleBlocks.first == heading("Install").id }, "and back up to Install")
        check(settle(host.view) { outline(host.view).marked == ["Install"] }, "marked in turn")
        // Scrolled by hand to the middle of Configure secrets' text: that is marked.
        scroll(documentScroll(in: host.view)!, to: (rModel.scrollOffset?.y ?? 0) + 900)
        check(settle(host.view) {
            let first = rModel.visibleBlocks.first ?? -1
            return first > heading("Configure secrets").id && first < heading("Secrets").id && outline(host.view).marked == ["Configure secrets"]
        }, "text after a heading belongs to it")
        let kept = rModel.scrollOffset?.y ?? 0

        // S: the same file in another pane, with its own table of contents.
        states.open(FilePreviewRequest(machine: local, pane: s, link: "guide.md"), for: sItem)
        let sModel = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(settle(host.view) { text(sModel) == guide && outlineShown() == titles }, "S shows its own table of contents")
        check(press(toggle()) && settle(host.view) { !sModel.showsOutline && outlineShown().isEmpty && toggle() != nil && !toggleIsOn() },
              "the header button turns S's table of contents off")
        check(help() == "Show Table of Contents", "its help says it shows it again")
        check(rModel.showsOutline, "R's is left on")
        scroll(documentScroll(in: host.view)!, to: kept)
        check(settle(host.view) { abs((sModel.scrollOffset?.y ?? 0) - kept) < 1 }, "S is scrolled where R was left")

        // Back to R: as it was left (SHPHRD-69), with the table of contents on.
        select(rItem, r)
        check(settle(host.view) { outlineShown() == titles && !rModel.visibleBlocks.isEmpty }, "R comes back with its table of contents on")
        drain(host.view)
        let rBack = documentScroll(in: host.view)?.contentView.bounds.origin.y ?? -1
        let marked = PreviewOutline.current(in: headings, firstVisible: rModel.visibleBlocks.first, inSource: false)
        check(marked != nil && settle(host.view) { outline(host.view).marked == [headings.first { $0.id == marked }!.title] },
              "and marks the heading of the first block it shows")
        // Back to S: still off, and back where R came back, the same file
        // without a table of contents: it doesn't move the place put back.
        select(sItem, s)
        check(settle(host.view) { text(sModel) == guide && toggle() != nil } && !sModel.showsOutline && outlineShown().isEmpty && !toggleIsOn(),
              "S's table of contents stays off for S")
        drain(host.view)
        check(abs((documentScroll(in: host.view)?.contentView.bounds.origin.y ?? 0) - rBack) < 2,
              "R, with its table of contents on, came back where S, with it off, comes back from the same place")
        check(press(toggle()) && settle(host.view) { sModel.showsOutline && outlineShown() == titles }, "and comes back on with the button")
        check(press(toggle()) && settle(host.view) { !sModel.showsOutline && outlineShown().isEmpty }, "off again")
        // A Markdown file opened anew in S: on again.
        states.open(FilePreviewRequest(machine: local, pane: s, link: "guide.md"), for: sItem)
        let sAgain = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(settle(host.view) { text(sAgain) == guide && outlineShown() == titles } && sAgain.showsOutline,
              "a Markdown file opened anew starts with its table of contents on")

        // R in source: the same list, chosen by line.
        select(rItem, r)
        check(settle(host.view) { outlineShown() == titles }, "R again")
        rModel.scrollOffset = nil; rModel.visibleBlocks = []; rModel.visibleLines = []; rModel.showsSource = true
        check(settle(host.view) { rModel.visibleLines.first == 1 && outlineShown() == titles }, "the source view keeps the table of contents")
        check(press(item("Secrets")), "Secrets can be chosen in the source")
        check(settle(host.view) { rModel.visibleLines.first == heading("Secrets").line }, "choosing Secrets brings its line to the top of the source")
        check(sourceLines[heading("Secrets").line - 1] == "### Secrets", "that line is the heading's, frontmatter counted")
        check(settle(host.view) { outline(host.view).marked == ["Secrets"] }, "and marks it")
        // Expanded, R's source still has it.
        select(rItem, r, expanded: true)
        check(settle(host.view) { outlineShown() == titles }, "an expanded preview has its table of contents too")
        check(press(item("Appendix")) && settle(host.view) { rModel.visibleLines.first == heading("Appendix").line }, "and goes to a heading from it")
        check(sourceLines[heading("Appendix").line - 1] == "# Appendix" && settle(host.view) { outline(host.view).marked == ["Appendix"] },
              "the Appendix line, marked")
        // Rendered again, in the expanded preview.
        rModel.scrollOffset = nil; rModel.visibleBlocks = []; rModel.visibleLines = []; rModel.showsSource = false
        check(settle(host.view) { rModel.visibleBlocks.first == 0 } && press(item("Rollback"))
              && settle(host.view) { rModel.visibleBlocks.first == heading("Rollback").id }, "the expanded rendering goes to a heading too")

        // SHPHRD-69's place put back, to 2 points, with the table of
        // contents shown over the rendering and over the source.
        let t = pane("w1:p5", terminal: "term_t", cwd: directory)
        let tItem = TerminalIdentity(connection: local.connectionIdentity, itemID: t.id)
        states.open(FilePreviewRequest(machine: local, pane: t, link: "tail.md"), for: tItem)
        let tModel = states.entry(for: tItem, panes: [t])!.model
        select(tItem, t)
        check(settle(host.view) { text(tModel) == tail && outlineShown() == ["Tail"] }, "T lists its one heading")
        check(settle(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 2000 }, "T's rendering is laid out")
        scroll(documentScroll(in: host.view)!, to: 900)
        check(settle(host.view) { abs((tModel.scrollOffset?.y ?? 0) - 900) < 1 }, "T's place is kept as it scrolls")
        select(sItem, s)
        check(settle(host.view) { text(sAgain) == guide && outlineShown() == titles }, "S meanwhile")
        select(tItem, t)
        check(settle(host.view) { abs((documentScroll(in: host.view)?.contentView.bounds.origin.y ?? 0) - 900) < 2 && outlineShown() == ["Tail"] },
              "T comes back at its scroll place, to 2 points, under its table of contents")
        tModel.scrollOffset = nil; tModel.visibleBlocks = []; tModel.visibleLines = []; tModel.showsSource = true
        check(settle(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 1500 && outlineShown() == ["Tail"] }, "T's source is laid out")
        scroll(documentScroll(in: host.view)!, to: 400)
        check(settle(host.view) { abs((tModel.scrollOffset?.y ?? 0) - 400) < 1 }, "T's source place is kept as it scrolls")
        drain(host.view)
        check(abs((tModel.scrollOffset?.y ?? 0) - 400) < 1 && abs((documentScroll(in: host.view)?.contentView.bounds.origin.y ?? 0) - 400) < 1,
              "and stays there once its highlighting is in")
        select(sItem, s)
        check(settle(host.view) { text(sAgain) == guide }, "S meanwhile")
        select(tItem, t, expanded: true)
        check(settle(host.view) { abs((documentScroll(in: host.view)?.contentView.bounds.origin.y ?? 0) - 400) < 2 && outlineShown() == ["Tail"] },
              "T's source comes back at its place, to 2 points, expanded, under its table of contents")

        // A Markdown file with no heading: the button is there, off and
        // disabled, and there is no table of contents.
        states.open(FilePreviewRequest(machine: local, pane: r, link: "plain.md"), for: rItem)
        let plain = states.entry(for: rItem, panes: [r])!.model
        select(rItem, r)
        check(settle(host.view) { text(plain) != nil && toggle() != nil }, "plain.md is read, with the button")
        check(!toggleIsEnabled() && !toggleIsOn() && outlineShown().isEmpty && accessibility(host.view)["preview.outline"] == nil,
              "with no heading the button is off and disabled, and no table of contents is shown")
        check(help() == "No Headings", "its help says why")
        // A file that isn't Markdown: no button, no table of contents.
        states.open(FilePreviewRequest(machine: local, pane: r, link: "notes.txt"), for: rItem)
        let notes = states.entry(for: rItem, panes: [r])!.model
        select(rItem, r)
        check(settle(host.view) { text(notes) == "# Not Markdown here\nplain text" && (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 0 },
              "notes.txt is read")
        drain(host.view)
        check(toggle() == nil && outlineShown().isEmpty && accessibility(host.view)["preview.outline"] == nil,
              "a file that isn't Markdown has neither the button nor a table of contents, even with a # line")
        host.rootView = PanelRoot(entry: nil, store: store)
        drain(host.view)
    }

    static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// Find, in a second owned never-shown window: the panel beside a view
    /// standing in for a terminal, keys sent as AppKit sends key
    /// equivalents, and the keyboard moved only with `makeFirstResponder`,
    /// by the test or by the preview. Accessibility is on from the table of
    /// contents' checks.
    static func find(directory: String, store: MachineStore, local: Machine, states: FilePreviewPaneStates) throws {
        var parts = ["# Find plan"]
        for n in 1...200 {
            switch n {
            case 30: parts.append("**Deploy** step one, with [the notes](deploy.md).")
            case 60: parts.append("## Rollout")
            case 90: parts.append("**Deploy** step two, with [the notes](deploy.md).")
            case 150: parts.append("| Stage | Owner |\n| --- | --- |\n| deploy | ops |")
            case 190: parts.append("```sh\n./deploy.sh\n```")
            default: parts.append("Paragraph \(n) of the owned find plan, long enough to wrap once or twice in a side panel of this width.")
            }
        }
        let plan = parts.joined(separator: "\n\n")
        try Data(plan.utf8).write(to: URL(fileURLWithPath: directory + "/find.md"))
        let planLines = plan.components(separatedBy: "\n")
        let deployLines = planLines.indices.filter { planLines[$0].lowercased().contains("deploy") }.map { $0 + 1 }
        check(deployLines == [61, 181, 303, 384], "the plan's deploy lines")
        // A text file longer than the 120,000 characters shown: a needle
        // inside them, and one past them.
        let huge = (1...1_250).map { n -> String in
            let line = n == 600 || n == 1_220 ? "needle at line \(n) " : ""
            return line + String(repeating: "x", count: 99 - line.count)
        }.joined(separator: "\n")
        try Data(huge.utf8).write(to: URL(fileURLWithPath: directory + "/huge.txt"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        window.contentView = container
        let terminal = OwnedTerminal(frame: NSRect(x: 0, y: 0, width: 340, height: 520))
        container.addSubview(terminal)
        let closes = CloseCount()
        let host = NSHostingController(rootView: FindRoot(entry: nil, store: store, closes: closes))
        host.sizingOptions = []
        host.view.frame = NSRect(x: 340, y: 0, width: 560, height: 520)
        container.addSubview(host.view)
        drain(host.view)

        let f = pane("w2:p1", terminal: "term_f", cwd: directory), g = pane("w2:p2", terminal: "term_g", cwd: directory)
        let fItem = TerminalIdentity(connection: local.connectionIdentity, itemID: f.id)
        let gItem = TerminalIdentity(connection: local.connectionIdentity, itemID: g.id)
        func select(_ item: TerminalIdentity, _ pane: AgentSummary, expanded: Bool = false) {
            host.rootView = FindRoot(entry: states.entry(for: item, panes: [pane]), store: store, closes: closes, expanded: expanded)
        }
        func send(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
            window.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!)
        }
        func commandF() -> Bool { send("f", .command, keyCode: 3) }
        func commandG() -> Bool { send("g", .command, keyCode: 5) }
        func shiftCommandG() -> Bool { send("G", [.command, .shift], keyCode: 5) }
        func esc() {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            (window.firstResponder as? NSView)?.keyDown(with: key)
        }
        func field() -> PreviewFindTextField? { views(of: PreviewFindTextField.self, in: host.view).first }
        /// The find field's editor, while it has the keyboard.
        func editor() -> NSTextView? {
            guard let editor = window.firstResponder as? NSTextView, let field = field(), editor.delegate === field else { return nil }
            return editor
        }
        func type(_ text: String) {
            editor()!.selectAll(nil)
            editor()!.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        /// What the bar says of its matches, as VoiceOver reads it.
        func count() -> String? { accessibility(host.view)["preview.find.count"]?.value(forKey: "accessibilityValue") as? String }
        func bar() -> NSObject? { accessibility(host.view)["preview.find"] }
        func inPreview() -> Bool { PreviewKeyCatcherView.isInPreview(window.firstResponder, root: host.view) }
        func frame(_ element: NSObject?) -> NSRect? { (element?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }

        // F: the plan, rendered.
        states.open(FilePreviewRequest(machine: local, pane: f, link: "find.md"), for: fItem)
        let fModel = states.entry(for: fItem, panes: [f])!.model
        select(fItem, f)
        check(settle(host.view) { text(fModel) == plan && fModel.visibleBlocks.first == 0 }, "F's plan is read and rendered from its top")
        check(fModel.find == PreviewFindState(), "with no find bar")

        // The terminal has the keyboard: ⌘F and ⌘G go past the preview.
        window.makeFirstResponder(terminal)
        check(!commandF() && !commandG() && !shiftCommandG() && !fModel.find.isShown, "with the terminal's keyboard, the preview takes neither ⌘F nor ⌘G")
        drain(host.view)
        check(window.firstResponder === terminal && bar() == nil, "the terminal keeps the keyboard, and no find bar shows")

        // The preview has it: ⌘F shows the bar, the keyboard in its field.
        window.makeFirstResponder(host.view)
        check(commandF() && fModel.find.isShown, "with the preview's keyboard, ⌘F is the preview's: the find bar shows")
        check(settle(host.view) { bar() != nil && editor() != nil }, "with the keyboard in its field")
        check(settle(host.view) {
            guard let bar = frame(bar()), let outline = frame(accessibility(host.view)["preview.outline"]) else { return false }
            return bar.minY >= outline.maxY - 0.5
        }, "the table of contents is under the find bar, not under it")

        // Typed: the first match from where the view is, brought to the top.
        type("DEPLOY")
        check(fModel.find.query == "DEPLOY" && fModel.find.current == 0, "what is typed is looked for, case ignored: at the first match")
        check(settle(host.view) { fModel.visibleBlocks.first == 30 }, "the first Deploy's block is brought to the top")
        check(settle(host.view) { count() == "1 / 4" }, "1 / 4: two Deploys, a table cell and the code, not the link targets")
        check(commandG() && fModel.find.current == 1 && settle(host.view) { fModel.visibleBlocks.first == 90 }, "⌘G: the next, at the top")
        check(settle(host.view) { count() == "2 / 4" }, "2 / 4")
        check(commandG() && settle(host.view) { fModel.find.current == 2 && fModel.visibleBlocks.first == 150 }, "the table")
        check(commandG() && settle(host.view) { fModel.find.current == 3 && fModel.visibleBlocks.contains(190) }, "the code, near the end")
        // Coming back up a lazy stack, it may report a block or two it let
        // go of as still shown: the match's block is in view, the code not.
        check(commandG() && settle(host.view) { fModel.find.current == 0 && fModel.visibleBlocks.contains(30) && !fModel.visibleBlocks.contains(190) },
              "past the last, round to the first")
        check(shiftCommandG() && settle(host.view) { fModel.find.current == 3 && fModel.visibleBlocks.contains(190) }, "⇧⌘G from the first: round to the last")
        editor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(settle(host.view) { fModel.find.current == 0 && fModel.visibleBlocks.contains(30) && !fModel.visibleBlocks.contains(190) }, "Return in the field: the next")
        check(editor() != nil, "the field keeps the keyboard through ⌘G, ⇧⌘G and Return")
        type("zzz")
        check(fModel.find.current == nil && settle(host.view) { count() == "No Results" }, "nothing found: No Results")
        type("deploy")
        check(fModel.find.current == 0 && settle(host.view) { count() == "1 / 4" }, "found again from where the view is")

        // The source: what is looked for is kept, in the source's lines.
        check(press(accessibility(host.view)["preview.source"]), "Source can be chosen")
        check(settle(host.view) { fModel.showsSource && fModel.visibleLines.first == 1 } && fModel.find.query == "deploy" && fModel.find.current == nil,
              "in the source, from its top: what is looked for kept, at no match yet")
        check(settle(host.view) { count() == "0 / 6" }, "0 / 6: in the source, the link targets count")
        check(commandG() && settle(host.view) { fModel.find.current == 0 && fModel.visibleLines.first == deployLines[0] }, "⌘G: the first, its line at the top")
        check(commandG() && settle(host.view) { fModel.find.current == 1 && fModel.visibleLines.first == deployLines[0] }, "the same line's second")
        check(commandG() && settle(host.view) { fModel.find.current == 2 && fModel.visibleLines.first == deployLines[1] }, "the next line")

        // Esc in the field closes the bar only.
        editor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check(!fModel.find.isShown && fModel.find.query == "deploy" && closes.count == 0, "Esc in the field closes the find bar, not the preview, keeping what it looked for")
        check(settle(host.view) { bar() == nil && editor() == nil && inPreview() }, "the bar gone, its marks with it, the keyboard with the preview")
        check(commandF() && settle(host.view) { editor() != nil && editor()?.selectedRange() == NSRange(location: 0, length: 6) },
              "⌘F again: the bar, what it looked for selected in its field")
        check(fModel.find.current == 2, "opened anew, at the first match from where the view is")

        // Esc with the keyboard in the preview, not in the field: the bar
        // closes first, then the preview at the side.
        views(of: PreviewKeyCatcherView.self, in: host.view).first?.takeKeyboard()
        check(settle(host.view) { editor() == nil && inPreview() && window.firstResponder !== host.view },
              "a click in the preview takes the keyboard from the field to the preview, with SwiftUI's focus")
        esc()
        check(settle(host.view) { !fModel.find.isShown } && closes.count == 0, "Esc closes the find bar first")
        esc()
        check(settle(host.view) { closes.count == 1 }, "and then the preview, at the side as well")

        // Another pane and back: F's find bar as it was left.
        check(commandF() && settle(host.view) { editor() != nil }, "the bar again")
        check(commandG(), "⌘G")
        let kept = fModel.find
        check(kept.isShown && kept.query == "deploy" && kept.current == 3, "at the fourth match")
        states.open(FilePreviewRequest(machine: local, pane: g, link: "plan.md"), for: gItem)
        let gModel = states.entry(for: gItem, panes: [g])!.model
        select(gItem, g)
        check(settle(host.view) { text(gModel) != nil } && gModel.find == PreviewFindState() && bar() == nil, "G has no find bar of its own")
        check(fModel.find == kept, "leaving F keeps its find bar, what it looks for and the match it is at")
        select(fItem, f)
        check(settle(host.view) { field()?.stringValue == "deploy" && count() == "4 / 6" }, "back to F: its bar, what it looked for, at the same match")
        drain(host.view)
        check(editor() == nil && fModel.find == kept, "coming back doesn't put the keyboard in the field")

        // A new read of F starts its find bar over.
        let request = states.entry(for: fItem, panes: [f])!.request
        let reading = Task { await fModel.load(request, store: store) }
        check(settle(host.view) { fModel.find == PreviewFindState() && text(fModel) == plan && bar() == nil }, "a new read: no bar, nothing looked for")
        reading.cancel()

        // A text file: found in its first 120,000 characters, as shown.
        states.open(FilePreviewRequest(machine: local, pane: g, link: "huge.txt"), for: gItem)
        let hModel = states.entry(for: gItem, panes: [g])!.model
        select(gItem, g)
        check(settle(host.view) { text(hModel) == huge && hModel.visibleLines.first == 1 }, "huge.txt is read")
        window.makeFirstResponder(host.view)
        check(commandG() && settle(host.view) { editor() != nil } && hModel.find.isShown,
              "a text file has the find bar too: with nothing looked for yet, ⌘G shows it as ⌘F does")
        type("NEEDLE")
        check(settle(host.view) { count() == "1 / 1" && hModel.visibleLines.first == 600 },
              "only the needle in the 120,000 characters shown is found, its line brought to the top")
        // No text: ⌘F isn't the preview's.
        states.open(FilePreviewRequest(machine: local, pane: g, link: "missing.md"), for: gItem)
        let missing = states.entry(for: gItem, panes: [g])!.model
        select(gItem, g)
        check(settle(host.view) { if case .failed = missing.state { return true } else { return false } }, "missing.md can't be read")
        window.makeFirstResponder(host.view)
        check(!commandF() && !missing.find.isShown, "with no text shown, ⌘F goes past the preview")

        // A click: where it gives the preview the keyboard, and what it
        // does. The preview gone, the keyboard goes back to the terminal.
        select(fItem, f)
        check(settle(host.view) { text(fModel) == plan && fModel.visibleBlocks.first == 0 }, "F again")
        window.makeFirstResponder(terminal)
        check(commandF() == false, "the terminal's keyboard")
        window.makeFirstResponder(host.view)
        check(commandF() && settle(host.view) { editor() != nil }, "the bar, for its field")
        let catcher = views(of: PreviewKeyCatcherView.self, in: host.view).first!
        func point(_ view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        let body = host.view.convert(NSPoint(x: host.view.bounds.midX, y: host.view.bounds.maxY - 300), to: nil)
        check(!catcher.takesKeyboard(forClickAt: point(field()!)), "a click on the find field is the field's own")
        check(!catcher.takesKeyboard(forClickAt: NSPoint(x: host.view.convert(host.view.bounds, to: nil).maxX - 20, y: point(field()!).y)),
              "a click elsewhere on the find bar, as on its buttons, leaves the keyboard in its field")
        check(catcher.takesKeyboard(forClickAt: body), "a click in the preview's text takes the keyboard from the field")
        window.makeFirstResponder(terminal)
        check(catcher.takesKeyboard(forClickAt: body), "with the terminal's keyboard, a click in the preview's text takes it")
        check(!catcher.takesKeyboard(forClickAt: point(terminal)), "a click on the terminal doesn't")
        catcher.takeKeyboard()
        check(settle(host.view) { inPreview() && window.firstResponder !== host.view }, "the click's taking: AppKit's keyboard and SwiftUI's focus in the preview")
        check(!catcher.takesKeyboard(forClickAt: body), "a click with the keyboard in the preview already changes nothing")
        check(commandF(), "⌘F is then the preview's")
        // Expanded and restored to its size, as before: the keyboard goes
        // back to the terminal it came from.
        select(fItem, f, expanded: true)
        check(settle(host.view) { inPreview() && window.firstResponder !== host.view }, "expanded, the preview keeps the keyboard")
        select(fItem, f)
        check(settle(host.view) { window.firstResponder === terminal }, "restored to its size, the terminal has the keyboard back")
        catcher.takeKeyboard()
        check(settle(host.view) { inPreview() }, "a click in the preview again")
        host.rootView = FindRoot(entry: nil, store: store, closes: closes)
        check(settle(host.view) { window.firstResponder === terminal }, "the preview gone, the terminal has the keyboard back")
        drain(host.view)
    }

    /// The first button whose name for VoiceOver is `name`.
    static func button(_ view: NSView, named name: String) -> NSObject? {
        var found: NSObject?
        func walk(_ node: AnyObject, _ depth: Int) {
            guard found == nil, depth < 60 else { return }
            if node is NSAccessibilityElementProtocol, let object = node as? NSObject,
               object.responds(to: NSSelectorFromString("accessibilityRole")), object.responds(to: NSSelectorFromString("accessibilityLabel")),
               (object.value(forKey: "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue, label(object) == name {
                found = object
                return
            }
            for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
        }
        walk(view, 0)
        return found
    }

    /// A PNG of one gray, `width` by `height` pixels.
    static func png(width: Int, height: Int, white: CGFloat) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: white, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Reload (SHPHRD-98), in a third owned never-shown window beside a view
    /// standing in for a terminal: the header's button, Retry and ⌘R read the
    /// file again, keeping how it is looked at. Accessibility is on from the
    /// table of contents' checks.
    static func reload(directory: String, store: MachineStore, local: Machine, states: FilePreviewPaneStates) throws {
        // Every block the same height but the headings, as for the table of
        // contents' scroll places; each version adds a heading and a needle
        // at the end, after where the preview is scrolled to.
        func plan(_ version: Int) -> String {
            var parts = ["# Reload plan"]
            for n in 1...240 {
                parts.append("Paragraph \(n) of the owned reload plan, \(n == 50 || n == 120 ? "a needle" : "long enough") to wrap once or twice in a side panel.")
            }
            parts.append("## Tail")
            for n in 241...250 { parts.append("Paragraph \(n) of the owned reload plan, long enough to wrap once or twice in a side panel.") }
            for v in 0..<version {
                parts.append("## Added \(v + 1)")
                parts.append("Paragraph added \(v + 1), with a needle in it, long enough to wrap once or twice in a side panel.")
            }
            return parts.joined(separator: "\n\n")
        }
        func write(_ text: String, _ name: String = "reload.md") throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: directory + "/" + name))
        }
        try write(plan(0))
        try write("int main(void) {\n" + (1...300).map { "    step(\($0));" }.joined(separator: "\n") + "\n}\n", "main.c")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        window.contentView = container
        let terminal = OwnedTerminal(frame: NSRect(x: 0, y: 0, width: 340, height: 520))
        container.addSubview(terminal)
        let closes = CloseCount()
        let host = NSHostingController(rootView: FindRoot(entry: nil, store: store, closes: closes))
        host.sizingOptions = []
        host.view.frame = NSRect(x: 340, y: 0, width: 560, height: 520)
        container.addSubview(host.view)
        drain(host.view)

        let r = pane("w3:p1", terminal: "term_r3", cwd: directory), s = pane("w3:p2", terminal: "term_s3", cwd: directory)
        let rItem = TerminalIdentity(connection: local.connectionIdentity, itemID: r.id)
        let sItem = TerminalIdentity(connection: local.connectionIdentity, itemID: s.id)
        func select(_ item: TerminalIdentity, _ pane: AgentSummary, expanded: Bool = false) {
            host.rootView = FindRoot(entry: states.entry(for: item, panes: [pane]), store: store, closes: closes, expanded: expanded)
        }
        func element(_ id: String) -> NSObject? { accessibility(host.view)[id] }
        func reloadButton() -> NSObject? { element("preview.reload") }
        func isEnabled(_ element: NSObject?) -> Bool { (element?.value(forKey: "accessibilityEnabled") as? Bool) ?? false }
        func frame(_ element: NSObject?) -> NSRect? { (element?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
        func place() -> CGPoint { documentScroll(in: host.view)?.contentView.bounds.origin ?? CGPoint(x: -1, y: -1) }
        func outlineShown() -> [String] { outline(host.view).titles }
        func failed(_ model: FilePreviewModel) -> Bool { if case .failed = model.state { return true } else { return false } }
        func commandR() -> Bool {
            window.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!)
        }
        func commandF() -> Bool {
            window.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!)
        }
        func field() -> PreviewFindTextField? { views(of: PreviewFindTextField.self, in: host.view).first }
        func editor() -> NSTextView? {
            guard let editor = window.firstResponder as? NSTextView, let field = field(), editor.delegate === field else { return nil }
            return editor
        }
        func count() -> String? { element("preview.find.count")?.value(forKey: "accessibilityValue") as? String }

        // R: the plan, rendered, its table of contents on.
        states.open(FilePreviewRequest(machine: local, pane: r, link: "reload.md"), for: rItem)
        let rModel = states.entry(for: rItem, panes: [r])!.model
        select(rItem, r)
        check(settle(host.view) { text(rModel) == plan(0) && outlineShown() == ["Reload plan", "Tail"] }, "R's plan is read, with its table of contents")
        check(settle(host.view) { reloadButton() != nil }, "the header has a Reload button")
        check(label(reloadButton()!) == "Reload" && reloadButton()!.value(forKey: "accessibilityHelp") as? String == "Reload (⌘R)" && isEnabled(reloadButton()),
              "named Reload for VoiceOver, its help giving ⌘R, enabled once the file is read")
        check(settle(host.view) {
            guard let outlineToggle = frame(element("preview.outline.toggle")), let reload = frame(reloadButton()),
                  let expand = frame(element("preview.expand")), let close = frame(button(host.view, named: "Close Preview")) else { return false }
            return outlineToggle.maxX <= reload.minX && reload.maxX <= expand.minX && expand.maxX <= close.minX && abs(reload.midY - expand.midY) < 2
        }, "between the table of contents' button and Expand, before Close: third from the right")

        // Scrolled down, read again: the new text in the same scroll view,
        // at the same place, its new heading listed.
        check(settle(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 2000 }, "R's rendering is laid out")
        let scrollView = documentScroll(in: host.view)
        scroll(scrollView!, to: 900)
        check(settle(host.view) { abs((rModel.scrollOffset?.y ?? 0) - 900) < 1 }, "R is scrolled to 900")
        try write(plan(1))
        check(press(reloadButton()), "Reload can be pressed")
        check(settle(host.view) { text(rModel) == plan(1) && !rModel.isReading }, "pressed, R's file is read again")
        check(settle(host.view) { outlineShown() == ["Reload plan", "Tail", "Added 1"] }, "the table of contents lists the new heading")
        drain(host.view)
        check(documentScroll(in: host.view) === scrollView, "the same scroll view shows the new text: the rendering isn't made anew")
        check(abs(place().y - 900) < 2 && abs((rModel.scrollOffset?.y ?? 0) - 900) < 2, "at the place it was scrolled to")
        check(!rModel.showsSource && rModel.showsOutline && rModel.link?.line == nil && isEnabled(reloadButton()), "still rendered, the table of contents on, Reload enabled again")

        // Another pane and back: R comes back at 900, is scrolled on to
        // 1500, and read again stays there, not taken back to 900.
        try write("# S's own\n\nA short file.", "other.md")
        states.open(FilePreviewRequest(machine: local, pane: s, link: "other.md"), for: sItem)
        let sModel = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(settle(host.view) { text(sModel) == "# S's own\n\nA short file." }, "S meanwhile")
        select(rItem, r)
        check(settle(host.view) { abs(place().y - 900) < 2 } && text(rModel) == plan(1), "R comes back at 900, not read again")
        drain(host.view)
        scroll(documentScroll(in: host.view)!, to: 1500)
        check(settle(host.view) { abs((rModel.scrollOffset?.y ?? 0) - 1500) < 1 }, "and is scrolled on to 1500")
        let backView = documentScroll(in: host.view)
        try write(plan(2))
        check(press(reloadButton()) && settle(host.view) { text(rModel) == plan(2) }, "read again")
        drain(host.view)
        check(documentScroll(in: host.view) === backView && abs(place().y - 1500) < 2 && abs((rModel.scrollOffset?.y ?? 0) - 1500) < 2,
              "read again, it stays at 1500: the place it came back at isn't put back")

        // The table of contents turned off stays off, read again; on, it
        // lists what was read.
        check(press(element("preview.outline.toggle")) && settle(host.view) { !rModel.showsOutline && outlineShown().isEmpty }, "the table of contents off")
        try write(plan(3))
        check(press(reloadButton()) && settle(host.view) { text(rModel) == plan(3) }, "read again")
        drain(host.view)
        check(!rModel.showsOutline && outlineShown().isEmpty && element("preview.outline.toggle") != nil, "the table of contents stays off")
        check(press(element("preview.outline.toggle")) && settle(host.view) { outlineShown() == ["Reload plan", "Tail", "Added 1", "Added 2", "Added 3"] },
              "turned on, it lists the headings read")

        // The find bar: kept open, with what it looks for, its matches
        // counted in the new text, at none of them yet.
        window.makeFirstResponder(host.view)
        check(commandF() && settle(host.view) { editor() != nil }, "the find bar, the keyboard in its field")
        editor()!.insertText("needle", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(settle(host.view) { rModel.find.query == "needle" && count().map { $0.hasSuffix("/ 5") } == true }, "five needles")
        let findField = field()
        try write(plan(4))
        check(commandR(), "⌘R with the keyboard in the find field is the preview's")
        check(settle(host.view) { text(rModel) == plan(4) && count() == "0 / 6" }, "read again: six needles counted, at none of them yet")
        drain(host.view)
        check(rModel.find.isShown && rModel.find.query == "needle" && rModel.find.current == nil && field() === findField && field()?.stringValue == "needle",
              "the same find bar, what it looks for kept")
        check(editor() != nil, "the field keeps the keyboard")
        editor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check(settle(host.view) { !rModel.find.isShown && element("preview.find") == nil }, "the find bar closed")

        // A link to a line, in the source: read again, the line stays
        // marked, and the preview isn't taken back to it.
        states.open(FilePreviewRequest(machine: local, pane: s, link: "reload.md:40"), for: sItem)
        let lined = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(settle(host.view) { text(lined) == plan(4) && lined.showsSource && lined.visibleLines.first == 40 }, "the link's line at the top of the source")
        scroll(documentScroll(in: host.view)!, to: 2500)
        check(settle(host.view) { abs((lined.scrollOffset?.y ?? 0) - 2500) < 1 && (lined.visibleLines.first ?? 0) > 80 }, "scrolled away from it")
        let linedView = documentScroll(in: host.view)
        try write(plan(5))
        check(press(reloadButton()) && settle(host.view) { text(lined) == plan(5) }, "read again")
        drain(host.view)
        check(documentScroll(in: host.view) === linedView && abs(place().y - 2500) < 2 && (lined.visibleLines.first ?? 0) > 80,
              "it stays where it was scrolled to, not taken back to the line")
        check(lined.showsSource && lined.link?.line == 40, "in the source, the line linked to kept")

        // The file gone: Cannot Preview File, Reload there too; back, Retry
        // shows it in the source at the place it was left. A list, its
        // lines all as tall in the source, whose place comes back exactly.
        func list(_ version: Int) -> String {
            "# Owned list\n" + (1...300).map { "- item \($0) of the owned list, version \(version)" }.joined(separator: "\n")
        }
        try write(list(0), "list.md")
        states.open(FilePreviewRequest(machine: local, pane: r, link: "list.md"), for: rItem)
        let listed = states.entry(for: rItem, panes: [r])!.model
        select(rItem, r)
        check(settle(host.view) { text(listed) == list(0) && element("preview.source") != nil }, "the list is read")
        check(press(element("preview.source")) && settle(host.view) { listed.showsSource && listed.visibleLines.first == 1 }, "in the source, at its top")
        check(settle(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 3000 }, "the list's source is laid out")
        scroll(documentScroll(in: host.view)!, to: 1200)
        check(settle(host.view) { abs((listed.scrollOffset?.y ?? 0) - 1200) < 1 }, "scrolled to 1200")
        try FileManager.default.removeItem(atPath: directory + "/list.md")
        check(press(reloadButton()) && settle(host.view) { failed(listed) && button(host.view, named: "Retry") != nil }, "the file gone: Cannot Preview File, with Retry")
        drain(host.view)
        check(reloadButton() != nil && isEnabled(reloadButton()) && element("preview.source") == nil, "the header's Reload stays, enabled")
        check(listed.showsSource && abs((listed.scrollOffset?.y ?? 0) - 1200) < 1 && listed.link?.path == directory + "/list.md",
              "how it was looked at is kept")
        check(press(reloadButton()) && settle(host.view) { failed(listed) && !listed.isReading } && button(host.view, named: "Retry") != nil, "Reload again: still gone")
        try write(list(1), "list.md")
        check(press(button(host.view, named: "Retry")) && settle(host.view) { text(listed) == list(1) }, "back, Retry reads it")
        check(settle(host.view) { listed.showsSource && element("preview.source") != nil && (listed.visibleLines.first ?? 0) > 1 }, "in the source")
        drain(host.view)
        check(abs(place().y - 1200) < 2, "at the place it was left")

        // ⌘R: the preview's while it has the keyboard, from the failed
        // screen too; the terminal's while the terminal has it.
        try write(list(2), "list.md")
        window.makeFirstResponder(terminal)
        check(!commandR(), "with the terminal's keyboard, ⌘R goes past the preview")
        drain(host.view)
        check(text(listed) == list(1) && window.firstResponder === terminal, "and nothing is read")
        window.makeFirstResponder(host.view)
        check(commandR() && settle(host.view) { text(listed) == list(2) }, "with the preview's keyboard, ⌘R reads it again")
        try FileManager.default.removeItem(atPath: directory + "/list.md")
        check(commandR() && settle(host.view) { failed(listed) }, "⌘R: gone")
        try write(list(3), "list.md")
        window.makeFirstResponder(host.view)
        check(commandR() && settle(host.view) { text(listed) == list(3) }, "⌘R on the failed screen reads it again")
        drain(host.view)
        check(listed.showsSource && abs(place().y - 1200) < 2, "in the source, at its place")
        check(commandR() && commandR() && commandR() && settle(host.view) { !listed.isReading && text(listed) == list(3) }, "⌘R pressed over and over")
        drain(host.view)
        check(abs(place().y - 1200) < 2, "still at its place")
        window.makeFirstResponder(terminal)

        // A file that isn't Markdown has Reload too, with no Source or
        // table of contents button.
        states.open(FilePreviewRequest(machine: local, pane: s, link: "main.c"), for: sItem)
        let source = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(settle(host.view) { text(source) != nil && reloadButton() != nil }, "main.c is read, with Reload")
        check(element("preview.source") == nil && element("preview.outline.toggle") == nil, "with no Source or table of contents button")
        check(settle(host.view) {
            guard let reload = frame(reloadButton()), let expand = frame(element("preview.expand")),
                  let close = frame(button(host.view, named: "Close Preview")) else { return false }
            return reload.maxX <= expand.minX && expand.maxX <= close.minX
        }, "third from the right there too")

        // An image: read again, at the same place across and down, drawn anew.
        try png(width: 1600, height: 1600, white: 0.2).write(to: URL(fileURLWithPath: directory + "/photo.png"))
        states.open(FilePreviewRequest(machine: local, pane: s, link: "photo.png"), for: sItem)
        let photo = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(settle(host.view) {
            guard case .loaded(let document) = photo.state, case .image = document.content else { return false }
            return (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 1600
        }, "the image is read and drawn")
        check(reloadButton() != nil && isEnabled(reloadButton()), "an image has Reload too")
        let imageView = documentScroll(in: host.view)!
        imageView.contentView.scroll(to: NSPoint(x: 300, y: 500))
        imageView.reflectScrolledClipView(imageView.contentView)
        check(settle(host.view) { abs((photo.scrollOffset?.x ?? 0) - 300) < 1 && abs((photo.scrollOffset?.y ?? 0) - 500) < 1 }, "scrolled across and down")
        try png(width: 1600, height: 1200, white: 0.8).write(to: URL(fileURLWithPath: directory + "/photo.png"))
        check(press(reloadButton()) && settle(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) < 1500 }, "read again, the new image is drawn")
        drain(host.view)
        check(documentScroll(in: host.view) === imageView && abs(place().x - 300) < 2 && abs(place().y - 500) < 2, "at the same place across and down")

        host.rootView = FindRoot(entry: nil, store: store, closes: closes)
        drain(host.view)
    }
}
