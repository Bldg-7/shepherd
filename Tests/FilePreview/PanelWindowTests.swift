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
        print("PASS \(checks) actual preview panel checks in an owned never-shown window: per-pane read, source and scroll kept across P→Q→P, no reread, no scroll carried between panes (\(previewChecks)); the Markdown table of contents (\(checks - previewChecks))")
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
}
