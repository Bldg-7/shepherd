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
            // This never-shown fixture measures a stable nonanimated end
            // state. It does not validate normal visible-window insertion
            // animation timing.
            FilePreviewPanel(request: entry.request, model: entry.model, machineStore: store, onClose: {}, onFileLink: { _ in })
                .previewExpansion(isExpanded: expanded, onToggle: {})
                .transaction { $0.disablesAnimations = true }
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
    /// Lets MainActor work scheduled by a newly selected preview run between
    /// the same layout checks. It keeps the existing five-second condition
    /// deadline without adding a sleep or changing production scheduling.
    static func settleAsync(_ view: NSView, seconds: Double = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            await Task.yield()
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
        let items = accessibility(view).compactMap { entry -> (id: Int, element: NSObject)? in
            guard entry.key.hasPrefix("preview.outline."),
                  let id = Int(entry.key.dropFirst("preview.outline.".count)) else { return nil }
            return (id, entry.value)
        }.sorted { $0.id < $1.id }
        return (items.compactMap { label($0.element) }, items.filter { isSelected($0.element) }.compactMap { label($0.element) })
    }
    /// Chooses an element as VoiceOver's press does: a click's action
    /// without a click, which a window that is never shown can't take.
    static func press(_ element: NSObject?) -> Bool {
        guard let element, element.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
        return true
    }
    /// Routes an Escape key only through the owned never-shown window.
    static func escape(in window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53) else { return false }
        window.sendEvent(event)
        return true
    }

    static func main() async throws {
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
        outlinePresentationPolicy()
        try await tableOfContents(directory: directory, store: store, local: local, states: states, host: host)
        let outlineChecks = checks - previewChecks
        try await find(directory: directory, store: store, local: local, states: states)
        let findChecks = checks - previewChecks - outlineChecks
        try await reload(directory: directory, store: store, local: local, states: states)
        print("PASS \(checks) actual preview panel checks in an owned never-shown window: per-pane read, source and scroll kept across P→Q→P, no reread, no scroll carried between panes (\(previewChecks)); the Markdown table of contents (\(outlineChecks)); find, ⌘F beside a terminal (\(findChecks)); reload, ⌘R beside a terminal (\(checks - previewChecks - outlineChecks - findChecks))")
    }

    /// The production presentation policy has eight independent view-local
    /// states. This is policy coverage only, not system-pointer integration.
    static func outlinePresentationPolicy() {
        let cases: [(pointer: Bool, focus: Bool, explicit: Bool, presented: Bool, name: String)] = [
            (false, false, false, false, "TOC policy is closed without pointer, focus, or explicit reveal"),
            (true, false, false, true, "TOC policy presents for pointer state"),
            (false, true, false, true, "TOC policy presents for keyboard focus"),
            (true, true, false, true, "TOC policy presents when pointer and keyboard focus overlap"),
            (false, false, true, true, "TOC policy presents for explicit accessible reveal"),
            (true, false, true, true, "TOC policy presents for pointer and explicit reveal"),
            (false, true, true, true, "TOC policy presents for keyboard focus and explicit reveal"),
            (true, true, true, true, "TOC policy presents when all local states overlap")
        ]
        for state in cases {
            check(PreviewOutlineHover.isPresented(pointerInside: state.pointer, hasKeyboardFocus: state.focus,
                                                   hasExplicitReveal: state.explicit) == state.presented, state.name)
        }
    }

    /// The production panel's accessibility geometry and accessibility-focus
    /// path are checked in an owned, never-shown window. System pointer hover,
    /// transfer, and leave are deliberately outside this fixture's coverage.
    static func tableOfContents(directory: String, store: MachineStore, local: Machine, states: FilePreviewPaneStates,
                                host: NSHostingController<PanelRoot>) async throws {
        let enable = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        check(NSApp.responds(to: enable), "this process can turn its own accessibility on")
        _ = NSApp.perform(enable, with: NSNumber(value: true), with: "AXEnhancedUserInterface" as NSString)

        // Kept genuinely short for trigger/panel geometry and Escape. It is
        // intentionally not used to demand exact top navigation of its last
        // heading, which a viewport can clamp at the document bottom.
        let guide = "# Deploy guide\n\nIntroduction.\n\n## Install\n\nInstall it.\n\n### Secrets\n\nKeep secrets."
        try Data(guide.utf8).write(to: URL(fileURLWithPath: directory + "/guide.md"))
        try Data("Just a paragraph.".utf8).write(to: URL(fileURLWithPath: directory + "/plain.md"))
        let headings = PreviewMarkdownDocument(guide).headings
        let titles = ["Deploy guide", "Install", "Secrets"]
        func heading(_ title: String) -> PreviewMarkdownHeading { headings.first { $0.title == title }! }

        // The navigation fixture has the same headings, with substantial body
        // after Secrets. Exact top navigation therefore cannot bottom-clamp.
        func body(_ topic: String, count: Int) -> String {
            (1...count).map { "Paragraph \($0) after \(topic), long enough to wrap in the preview viewport." }.joined(separator: "\n\n")
        }
        let navigationGuide = "# Deploy guide\n\n" + body("the title", count: 16)
            + "\n\n## Install\n\n" + body("Install", count: 20)
            + "\n\n### Secrets\n\n" + body("Secrets", count: 40)
        try Data(navigationGuide.utf8).write(to: URL(fileURLWithPath: directory + "/navigation.md"))
        let navigationHeadings = PreviewMarkdownDocument(navigationGuide).headings
        func navigationHeading(_ title: String) -> PreviewMarkdownHeading { navigationHeadings.first { $0.title == title }! }

        let longGuide = "# Long guide\n\n" + (1...48).map { n in
            "## Topic \(n)\n\n" + (1...4).map { p in "Paragraph \(p) of topic \(n), long enough to wrap in the preview viewport." }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        let longHeadings = PreviewMarkdownDocument(longGuide).headings
        func longHeading(_ title: String) -> PreviewMarkdownHeading { longHeadings.first { $0.title == title }! }
        try Data(longGuide.utf8).write(to: URL(fileURLWithPath: directory + "/long.md"))

        // The rendered Markdown budget is 120,000 ASCII characters. Keep a
        // bounded two-heading document whose changed suffix is outside it.
        let largeHeader = "# Large guide\n\n## Stable heading\n\n"
        let largePrefix = largeHeader + String(repeating: "x", count: 120_000 - largeHeader.count)
        let largeOriginal = largePrefix + "\n\noriginal suffix"
        let largeChanged = largePrefix + "\n\nchanged suffix"
        check(largeOriginal != largeChanged && String(largeOriginal.prefix(120_000)) == String(largeChanged.prefix(120_000)),
              "the large Markdown changes only outside the rendered prefix")
        try Data(largeOriginal.utf8).write(to: URL(fileURLWithPath: directory + "/large.md"))

        let r = pane("w1:p3", terminal: "term_r", cwd: directory), s = pane("w1:p4", terminal: "term_s", cwd: directory),
            t = pane("w1:p5", terminal: "term_t", cwd: directory), u = pane("w1:p6", terminal: "term_u", cwd: directory),
            n = pane("w1:p7", terminal: "term_n", cwd: directory), v = pane("w1:p8", terminal: "term_v", cwd: directory)
        let rItem = TerminalIdentity(connection: local.connectionIdentity, itemID: r.id)
        let sItem = TerminalIdentity(connection: local.connectionIdentity, itemID: s.id)
        let tItem = TerminalIdentity(connection: local.connectionIdentity, itemID: t.id)
        let uItem = TerminalIdentity(connection: local.connectionIdentity, itemID: u.id)
        let nItem = TerminalIdentity(connection: local.connectionIdentity, itemID: n.id)
        let vItem = TerminalIdentity(connection: local.connectionIdentity, itemID: v.id)
        let window = host.view.window!
        func select(_ item: TerminalIdentity, _ pane: AgentSummary, expanded: Bool = false) {
            host.rootView = PanelRoot(entry: states.entry(for: item, panes: [pane]), store: store, expanded: expanded)
        }
        func outlineShown() -> [String] { outline(host.view).titles }
        func item(_ heading: PreviewMarkdownHeading) -> NSObject? { accessibility(host.view)["preview.outline.\(heading.id)"] }
        func trigger() -> NSObject? { accessibility(host.view)["preview.outline.trigger"] }
        func outlinePanel() -> NSObject? { accessibility(host.view)["preview.outline"] }
        func outlineRegion() -> NSObject? { accessibility(host.view)["preview.outline.region"] }
        func frame(_ element: NSObject?) -> NSRect? { (element?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
        func viewportFrame() -> NSRect { host.view.accessibilityFrame() }
        func rect(_ value: NSRect?) -> String {
            guard let value else { return "missing" }
            return String(format: "(x=%.1f y=%.1f w=%.1f h=%.1f maxX=%.1f maxY=%.1f)", value.minX, value.minY, value.width, value.height, value.maxX, value.maxY)
        }
        func elementDescription(_ id: String) -> String {
            let elements = accessibility(host.view)
            guard let element = elements[id] else { return "\(id)=missing" }
            return "\(id)=\(String(describing: type(of: element))) frame=\(rect(frame(element))) label=\(label(element) ?? "nil")"
        }
        func accessibilityElements(_ identifier: String) -> [NSObject] {
            var found: [NSObject] = []
            func walk(_ node: AnyObject, _ depth: Int) {
                guard depth < 60 else { return }
                if let element = node as? NSAccessibilityElementProtocol,
                   element.accessibilityIdentifier?() == identifier,
                   let object = node as? NSObject { found.append(object) }
                for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
            }
            walk(host.view, 0)
            return found
        }
        func axRole(_ element: NSObject) -> String { element.value(forKey: "accessibilityRole") as? String ?? "missing" }
        func axDescription(_ identifier: String) -> String {
            let matches = accessibilityElements(identifier)
            guard !matches.isEmpty else { return "\(identifier)=missing" }
            return matches.map { "\(String(describing: type(of: $0))) role=\(axRole($0)) frame=\(rect(frame($0)))" }.joined(separator: " | ")
        }
        /// AX projects this control through its containing semantic region, so
        /// its public frame is not a proxy for the separately measured 32-point
        /// SwiftUI layout. Keep the AX contract to identity, role, and label.
        func hasAccessibleOutlineTriggerButton() -> Bool {
            let matches = accessibilityElements("preview.outline.trigger")
            return matches.count == 1 && axRole(matches[0]).contains("Button") && label(matches[0]) == "Table of Contents"
        }
        func outlineScrollToEnd() -> (scrolled: Bool, detail: String) {
            guard let scroll = outlinePanel() as? NSScrollView, let document = scroll.documentView else {
                return (false, "outlineAX=\(axDescription("preview.outline"))")
            }
            let viewport = scroll.contentView.bounds.height
            let maximumTop = max(0, document.frame.height - viewport)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximumTop))
            scroll.reflectScrolledClipView(scroll.contentView)
            return (maximumTop > 0, String(format: "outlineDocumentHeight=%.1f viewportHeight=%.1f maximumTop=%.1f", document.frame.height, viewport, maximumTop))
        }
        func geometryDiagnostic(short: Bool) -> (passes: Bool, detail: String) {
            let viewport = viewportFrame()
            let triggerFrame = frame(trigger())
            let panelFrame = frame(outlinePanel())
            let regionFrame = frame(outlineRegion())
            let containsVisibleParts = regionFrame.map { region in
                triggerFrame.map(region.contains) == true && panelFrame.map(region.contains) == true
            } ?? false
            let trailing = triggerFrame.map { abs($0.maxX - viewport.maxX) < 2 } == true
                && panelFrame.map { abs($0.maxX - viewport.maxX) < 2 } == true
                && regionFrame.map { abs($0.maxX - viewport.maxX) < 2 } == true
            let boundedToVisibleParts = regionFrame.map { region in panelFrame.map { region.height <= $0.height + 40 } == true } == true
            let shortEnough = !short || (regionFrame.map { $0.height < viewport.height - 8 } == true)
            let detail = "viewportAX=\(rect(viewport)) outlineTitles=\(outlineShown()) contains=\(containsVisibleParts) trailing=\(trailing) bounded=\(boundedToVisibleParts) shortEnough=\(shortEnough) AX[\(elementDescription("preview.outline.trigger")); \(elementDescription("preview.outline")); \(elementDescription("preview.outline.region"))] triggerMatches=[\(axDescription("preview.outline.trigger"))] regionMatches=[\(axDescription("preview.outline.region"))]"
            return (containsVisibleParts && trailing && boundedToVisibleParts && shortEnough, detail)
        }

        states.open(FilePreviewRequest(machine: local, pane: r, link: "guide.md"), for: rItem)
        let rModel = states.entry(for: rItem, panes: [r])!.model
        select(rItem, r)
        check(settle(host.view) { text(rModel) == guide }, "R's guide is read")
        check(outlineShown().isEmpty && trigger() != nil, "a headed Markdown preview has a closed viewport TOC trigger, not a header toggle")
        check(label(trigger()!) == "Table of Contents", "the trigger is named for VoiceOver")

        // Public accessibility press opens the real production panel for
        // native AX geometry and accessibility-focus checks. It is not a
        // system-pointer hover/transfer/leave integration test.
        check(press(trigger()), "VoiceOver can perform the trigger's public accessibility action")
        check(settle(host.view) { outlineShown() == titles }, "the VoiceOver action reveals the short TOC; \(geometryDiagnostic(short: true).detail)")
        let shortGeometry = geometryDiagnostic(short: true)
        check(shortGeometry.passes, "the short TOC's actual trigger, panel and region are trailing and do not cover the viewport height; \(shortGeometry.detail)")
        check(escape(in: window) && settle(host.view) { outlineShown().isEmpty },
              "Escape leaves the accessibility-focused TOC without closing the preview; \(geometryDiagnostic(short: true).detail)")
        check(press(trigger()) && settle(host.view) { outlineShown() == titles }, "the accessibility trigger can reveal the short TOC again after Escape")

        // Exact heading-to-top navigation needs body below the target. Keep
        // that assertion on a scrollable document rather than weakening it
        // for the short geometry fixture's bottom-clamped last heading.
        states.open(FilePreviewRequest(machine: local, pane: n, link: "navigation.md"), for: nItem)
        let nModel = states.entry(for: nItem, panes: [n])!.model
        select(nItem, n)
        check(settle(host.view) { text(nModel) == navigationGuide && trigger() != nil }, "the scrollable navigation fixture is read")
        check(settle(host.view) { documentScroll(in: host.view)?.documentView != nil }, "the navigation fixture is laid out")
        let navigationCapacity: (enough: Bool, detail: String) = {
            guard let scroll = documentScroll(in: host.view), let document = scroll.documentView else { return (false, "scroll/document missing") }
            let viewport = scroll.contentView.bounds.height
            let documentHeight = document.frame.height
            let maximumTop = max(0, documentHeight - viewport)
            return (documentHeight > viewport * 2 && maximumTop > viewport,
                    String(format: "documentHeight=%.1f viewportHeight=%.1f maximumTop=%.1f", documentHeight, viewport, maximumTop))
        }()
        check(navigationCapacity.enough, "the navigation fixture has enough body after Secrets to avoid bottom clamping; \(navigationCapacity.detail)")
        check(press(trigger()) && settle(host.view) { outlineShown() == titles },  "the accessibility trigger reveals the scrollable navigation TOC")
        check(press(item(navigationHeading("Secrets"))) && settle(host.view) { nModel.visibleBlocks.first == navigationHeading("Secrets").id },
              "choosing Secrets brings its rendered block exactly to the top when bottom clamping is impossible")
        check(settle(host.view) { outlineShown().isEmpty }, "selecting a heading dismisses an explicit accessible reveal")
        check(press(trigger()) && settle(host.view) { outline(host.view).marked == ["Secrets"] },
              "the current heading remains tracked when the accessible TOC is revealed again")

        // Source mode uses the same scrollable fixture, retaining exact
        // source-line navigation below the selected heading.
        nModel.scrollOffset = nil; nModel.visibleBlocks = []; nModel.visibleLines = []; nModel.showsSource = true
        check(settle(host.view) { outlineShown() == titles && nModel.visibleLines.first == 1 }, "the revealed TOC remains available in Source")
        check(press(item(navigationHeading("Install"))) && settle(host.view) { nModel.visibleLines.first == navigationHeading("Install").line },
              "a source TOC heading goes to its source line without bottom clamping")

        // A long list is constrained by the visible viewport, and the same
        // trailing geometry remains when the production panel is expanded.
        states.open(FilePreviewRequest(machine: local, pane: t, link: "long.md"), for: tItem)
        let tModel = states.entry(for: tItem, panes: [t])!.model
        select(tItem, t)
        check(settle(host.view) { text(tModel) == longGuide && trigger() != nil }, "the long Markdown preview is read with its viewport trigger")
        check(longHeadings.count == 49, "the long fixture parses all 49 headings before LazyVStack virtualization")
        check(hasAccessibleOutlineTriggerButton(), "the long TOC exposes one named AXButton trigger; \(geometryDiagnostic(short: false).detail)")
        check(press(trigger()) && settle(host.view) {
            let rows = outlineShown()
            return rows.count >= 2 && rows.count < longHeadings.count && rows.first == "Long guide" && rows.contains("Topic 1")
        }, "the long TOC initially realizes a meaningful leading LazyVStack subset; \(geometryDiagnostic(short: false).detail)")
        let longGeometry = geometryDiagnostic(short: false)
        check(longGeometry.passes, "the long TOC's actual panel is bounded to the viewport and its region to visible parts; \(longGeometry.detail)")
        let longScroll = outlineScrollToEnd()
        check(longScroll.scrolled && settle(host.view) {
            guard let last = item(longHeading("Topic 48")) else { return false }
            return label(last) == "Topic 48"
        }, "publicly scrolling the owned TOC realizes its last heading; \(longScroll.detail) \(geometryDiagnostic(short: false).detail)")
        select(tItem, t, expanded: true)
        check(settle(host.view) { trigger() != nil }, "the expanded preview keeps its viewport TOC trigger")
        // Resizing the same pane need not clear a legitimate local explicit
        // reveal. If it remains open, retain it; if not, the same public AX
        // action must open the expanded panel.
        if outlineShown().isEmpty {
            check(press(trigger()) && settle(host.view) { !outlineShown().isEmpty },
                  "the accessibility trigger opens a closed expanded TOC; \(geometryDiagnostic(short: false).detail)")
        }
        check(hasAccessibleOutlineTriggerButton(), "the expanded TOC exposes one named AXButton trigger; \(geometryDiagnostic(short: false).detail)")
        let expandedGeometry = geometryDiagnostic(short: false)
        check(expandedGeometry.passes, "the expanded preview keeps the long TOC at the viewport's trailing edge; \(expandedGeometry.detail)")
        let expandedScroll = outlineScrollToEnd()
        check(expandedScroll.scrolled && settle(host.view) {
            guard let last = item(longHeading("Topic 48")) else { return false }
            return label(last) == "Topic 48"
        }, "publicly scrolling the expanded owned TOC realizes its last heading; \(expandedScroll.detail) \(geometryDiagnostic(short: false).detail)")

        // A different pane with the same document identity has its own local
        // reveal state, so identical text cannot carry an accessible reveal.
        states.open(FilePreviewRequest(machine: local, pane: u, link: "guide.md"), for: uItem)
        let uModel = states.entry(for: uItem, panes: [u])!.model
        select(uItem, u)
        check(settle(host.view) { text(uModel) == guide && trigger() != nil && outlineShown().isEmpty },
              "same-content different-pane identity starts with a closed TOC")

        // A different pane creates a new viewport region, so the old pane's
        // focused/revealed TOC cannot stick. A no-heading Markdown has none.
        states.open(FilePreviewRequest(machine: local, pane: s, link: "plain.md"), for: sItem)
        let sModel = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(settle(host.view) { text(sModel) == "Just a paragraph." } && trigger() == nil && outlineShown().isEmpty,
              "a no-heading Markdown has no unusable TOC affordance")
        select(rItem, r)
        check(settle(host.view) { trigger() != nil && outlineShown().isEmpty }, "pane changes do not retain hover visibility")

        // A changed reload is a new document and closes a previously revealed
        // TOC; its headings are available again through the same trigger.
        check(press(trigger()) && settle(host.view) { outlineShown() == titles }, "R can reveal the TOC again")
        try Data("# Replacement\n\n## New heading".utf8).write(to: URL(fileURLWithPath: directory + "/guide.md"))
        await rModel.reload(states.entry(for: rItem, panes: [r])!.request, store: store)
        check(settle(host.view) { text(rModel) == "# Replacement\n\n## New heading" && outlineShown().isEmpty },
              "a changed reload does not retain the previous document's reveal")
        check(press(trigger()) && settle(host.view) { outlineShown() == ["Replacement", "New heading"] },
              "reloaded headings are revealed and remain navigable")

        // The local accessible reveal observes the complete loaded document,
        // not only the 120,000 characters rendered on screen.
        states.open(FilePreviewRequest(machine: local, pane: v, link: "large.md"), for: vItem)
        let vModel = states.entry(for: vItem, panes: [v])!.model
        select(vItem, v)
        check(await settleAsync(host.view) { text(vModel) == largeOriginal && trigger() != nil }, "the bounded large Markdown preview is read")
        check(press(trigger()), "the large preview's accessibility trigger can be pressed")
        check(await settleAsync(host.view) { outlineShown() == ["Large guide", "Stable heading"] },
              "the large preview's accessible TOC is revealed")
        try Data(largeChanged.utf8).write(to: URL(fileURLWithPath: directory + "/large.md"))
        await vModel.reload(states.entry(for: vItem, panes: [v])!.request, store: store)
        check(await settleAsync(host.view) { text(vModel) == largeChanged && outlineShown().isEmpty },
              "a suffix-only change outside the rendered prefix closes the accessible TOC")
    }

    static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// Find, in a second owned never-shown window: the panel beside a view
    /// standing in for a terminal, keys sent as AppKit sends key
    /// equivalents, and the keyboard moved only with `makeFirstResponder`,
    /// by the test or by the preview. Accessibility is on from the table of
    /// contents' checks.
    static func find(directory: String, store: MachineStore, local: Machine, states: FilePreviewPaneStates) async throws {
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
        func phase(_ model: FilePreviewModel) -> String {
            switch model.state {
            case .loading: return "loading"
            case .loaded(let document):
                switch document.content {
                case .text(let value, let markdown): return "loaded-text(chars=\(value.count),markdown=\(markdown))"
                case .image: return "loaded-image"
                }
            case .failed: return "failed"
            }
        }
        func after(_ immediate: Bool, until condition: @escaping () -> Bool) async -> Bool {
            guard immediate else { return false }
            return await settleAsync(host.view, until: condition)
        }
        func focusDiagnostic() -> String {
            let findField = field()
            let responder = window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
            return "findShown=\(fModel.find.isShown) barPresent=\(bar() != nil) fieldPresent=\(findField != nil) fieldInWindow=\(findField?.window != nil) fieldWanted=\(findField?.keyboard?.fieldWanted.description ?? "missing") editorPresent=\(editor() != nil) firstResponder=\(responder)"
        }
        func initialLoadDiagnostic() -> String {
            let scroll = documentScroll(in: host.view)
            let documentFrame = scroll?.documentView?.frame
            let viewport = scroll?.contentView.bounds
            let offset = scroll?.contentView.bounds.origin
            return "textMatches=\(text(fModel) == plan) phase=\(phase(fModel)) showsSource=\(fModel.showsSource) visibleBlocks=\(fModel.visibleBlocks) scrollDocument=\(documentFrame.map { "(w=\(String(format: "%.1f", $0.width)),h=\(String(format: "%.1f", $0.height)))" } ?? "missing") scrollViewport=\(viewport.map { "(w=\(String(format: "%.1f", $0.width)),h=\(String(format: "%.1f", $0.height)))" } ?? "missing") scrollOffset=\(offset.map { "(x=\(String(format: "%.1f", $0.x)),y=\(String(format: "%.1f", $0.y)))" } ?? "missing")"
        }

        // F: the plan, rendered.
        states.open(FilePreviewRequest(machine: local, pane: f, link: "find.md"), for: fItem)
        let fModel = states.entry(for: fItem, panes: [f])!.model
        select(fItem, f)
        check(await settleAsync(host.view) { text(fModel) == plan && fModel.visibleBlocks.first == 0 },
              "F's plan is read and rendered from its top; \(initialLoadDiagnostic())")
        check(fModel.find == PreviewFindState(), "with no find bar")

        // The terminal has the keyboard: ⌘F and ⌘G go past the preview.
        window.makeFirstResponder(terminal)
        check(!commandF() && !commandG() && !shiftCommandG() && !fModel.find.isShown, "with the terminal's keyboard, the preview takes neither ⌘F nor ⌘G")
        drain(host.view)
        check(window.firstResponder === terminal && bar() == nil, "the terminal keeps the keyboard, and no find bar shows")

        // The preview has it: ⌘F shows the bar, the keyboard in its field.
        window.makeFirstResponder(host.view)
        check(commandF() && fModel.find.isShown, "with the preview's keyboard, ⌘F is the preview's: the find bar shows")
        check(await settleAsync(host.view) { bar() != nil && editor() != nil }, "with the keyboard in its field; \(focusDiagnostic())")
        check(await settleAsync(host.view) {
            guard let bar = frame(bar()), let trigger = frame(accessibility(host.view)["preview.outline.trigger"]) else { return false }
            return !bar.intersects(trigger)
        }, "the closed viewport TOC trigger does not overlap the Find bar")

        // Typed: the first match from where the view is, brought to the top.
        type("DEPLOY")
        check(fModel.find.query == "DEPLOY" && fModel.find.current == 0, "what is typed is looked for, case ignored: at the first match")
        check(await settleAsync(host.view) { fModel.visibleBlocks.first == 30 }, "the first Deploy's block is brought to the top")
        check(await settleAsync(host.view) { count() == "1 / 4" }, "1 / 4: two Deploys, a table cell and the code, not the link targets")
        check(await after(commandG() && fModel.find.current == 1) { fModel.visibleBlocks.first == 90 }, "⌘G: the next, at the top")
        check(await settleAsync(host.view) { count() == "2 / 4" }, "2 / 4")
        check(await after(commandG()) { fModel.find.current == 2 && fModel.visibleBlocks.first == 150 }, "the table")
        check(await after(commandG()) { fModel.find.current == 3 && fModel.visibleBlocks.contains(190) }, "the code")
        // Coming back up a lazy stack, it may report a block or two it let
        // go of as still shown: the match's block is in view, the code not.
        check(await after(commandG()) { fModel.find.current == 0 && fModel.visibleBlocks.contains(30) && !fModel.visibleBlocks.contains(190) },
              "past the last, round to the first")
        check(await after(shiftCommandG()) { fModel.find.current == 3 && fModel.visibleBlocks.contains(190) }, "⇧⌘G from the first: round to the last")
        editor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(await settleAsync(host.view) { fModel.find.current == 0 && fModel.visibleBlocks.contains(30) && !fModel.visibleBlocks.contains(190) }, "Return in the field: the next")
        check(editor() != nil, "the field keeps the keyboard through ⌘G, ⇧⌘G and Return")
        type("zzz")
        check(await after(fModel.find.current == nil) { count() == "No Results" }, "nothing found: No Results")
        type("deploy")
        check(await after(fModel.find.current == 0) { count() == "1 / 4" }, "found again from where the view is")
        // A new search goes from the first block shown: on from Deploy's block
        // at the top to the last paragraph, not back up to those above it,
        // though the lazy stack has laid out blocks there it never showed.
        check(await settleAsync(host.view) { fModel.visibleBlocks.first == 30 }, "Deploy's block at the top")
        type("paragraph 2")
        check(await after(fModel.find.current == 11) { count() == "12 / 12" && fModel.visibleBlocks.contains(200) && !fModel.visibleBlocks.contains(20) },
              "a new search from Deploy's block: the last paragraph's, block 200, not block 20 above it")
        type("deploy")
        check(fModel.find.query == "deploy" && fModel.find.current != nil, "deploy again")

        // The source: what is looked for is kept, in the source's lines.
        check(press(accessibility(host.view)["preview.source"]), "Source can be chosen")
        check(await settleAsync(host.view) { fModel.showsSource && fModel.visibleLines.first == 1 } && fModel.find.query == "deploy" && fModel.find.current == nil,
              "in the source, from its top: what is looked for kept, at no match yet")
        check(await settleAsync(host.view) { count() == "0 / 6" }, "0 / 6: in the source, the link targets count")
        check(await after(commandG()) { fModel.find.current == 0 && fModel.visibleLines.first == deployLines[0] }, "⌘G: the first, its line at the top")
        check(await after(commandG()) { fModel.find.current == 1 && fModel.visibleLines.first == deployLines[0] }, "the same line's second")
        check(await after(commandG()) { fModel.find.current == 2 && fModel.visibleLines.first == deployLines[1] }, "the next line")
        // A new search there goes from the first line shown too: on from it to
        // a line already in view, which stays where it is, not up to line 19.
        type("paragraph 9")
        let paragraphNineCount = await settleAsync(host.view) { count() == "2 / 10" }
        let paragraphNineRows = await settleAsync(host.view) { fModel.visibleLines.first == deployLines[1] && fModel.visibleLines.contains(183) }
        check(fModel.find.current == 1 && paragraphNineCount && paragraphNineRows,
              "a new search from the line at the top: paragraph 91's line below it, in view already, not paragraph 9's above")
        // None after it: round to the first, up among lines shown before,
        // which come back where they were. A new search from there goes on
        // from its first line, not from the top.
        type("paragraph 4")
        check(await after(fModel.find.current == 0) { count() == "1 / 11" && fModel.visibleLines.first == 9 },
              "with no paragraph 4 after the view, round to the first: its line 9 at the top, the lines shown counted")
        type("paragraph 1")
        check(await after(fModel.find.current == 1) { fModel.visibleLines.first == 9 && fModel.visibleLines.contains(21) },
              "a new search from line 9: paragraph 10's line below it, in view already, not paragraph 1's above")
        type("deploy")
        check(await after(fModel.find.current == 0) { count() == "1 / 6" && fModel.visibleLines.first == deployLines[0] }, "deploy again, from line 9: its first line")
        check(await after(commandG() && commandG()) { fModel.find.current == 2 && fModel.visibleLines.first == deployLines[1] }, "and on to the next line, as before")

        // Esc in the field closes the bar only.
        editor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check(!fModel.find.isShown && fModel.find.query == "deploy" && closes.count == 0, "Esc in the field closes the find bar, not the preview, keeping what it looked for")
        check(await settleAsync(host.view) { bar() == nil && editor() == nil && inPreview() }, "the bar gone, its marks with it, the keyboard with the preview")
        check(await after(commandF()) { editor() != nil && editor()?.selectedRange() == NSRange(location: 0, length: 6) },
              "⌘F again: the bar, what it looked for selected in its field")
        check(fModel.find.current == 2, "opened anew, at the first match from where the view is")

        // Esc with the keyboard in the preview, not in the field: the bar
        // closes first, then the preview at the side.
        views(of: PreviewKeyCatcherView.self, in: host.view).first?.takeKeyboard()
        check(await settleAsync(host.view) { editor() == nil && inPreview() && window.firstResponder !== host.view },
              "a click in the preview takes the keyboard from the field to the preview, with SwiftUI's focus")
        esc()
        check(await settleAsync(host.view) { !fModel.find.isShown } && closes.count == 0, "Esc closes the find bar first")
        esc()
        check(await settleAsync(host.view) { closes.count == 1 }, "and then the preview, at the side as well")

        // Another pane and back: F's find bar as it was left.
        check(await after(commandF()) { editor() != nil }, "the bar again")
        check(commandG(), "⌘G")
        let kept = fModel.find
        check(kept.isShown && kept.query == "deploy" && kept.current == 3, "at the fourth match")
        states.open(FilePreviewRequest(machine: local, pane: g, link: "plan.md"), for: gItem)
        let gModel = states.entry(for: gItem, panes: [g])!.model
        select(gItem, g)
        check(await settleAsync(host.view) { text(gModel) != nil } && gModel.find == PreviewFindState() && bar() == nil,
              "G has no find bar of its own")
        check(fModel.find == kept, "leaving F keeps its find bar, what it looks for and the match it is at")
        select(fItem, f)
        check(await settleAsync(host.view) { field()?.stringValue == "deploy" && count() == "4 / 6" }, "back to F: its bar, what it looked for, at the same match")
        drain(host.view)
        check(editor() == nil && fModel.find == kept, "coming back doesn't put the keyboard in the field")

        // A new read of F starts its find bar over.
        let request = states.entry(for: fItem, panes: [f])!.request
        let reading = Task { await fModel.load(request, store: store) }
        check(await settleAsync(host.view) { fModel.find == PreviewFindState() && text(fModel) == plan && bar() == nil }, "a new read: no bar, nothing looked for")
        reading.cancel()

        // A text file: found in its first 120,000 characters, as shown.
        states.open(FilePreviewRequest(machine: local, pane: g, link: "huge.txt"), for: gItem)
        let hModel = states.entry(for: gItem, panes: [g])!.model
        select(gItem, g)
        check(await settleAsync(host.view) { text(hModel) == huge && hModel.visibleLines.first == 1 }, "huge.txt is read")
        window.makeFirstResponder(host.view)
        check(await after(commandG()) { editor() != nil && hModel.find.isShown },
              "a text file has the find bar too: with nothing looked for yet, ⌘G shows it as ⌘F does")
        type("NEEDLE")
        check(await settleAsync(host.view) { count() == "1 / 1" && hModel.visibleLines.first == 600 },
              "only the needle in the 120,000 characters shown is found, its line brought to the top")
        // No text: ⌘F isn't the preview's.
        states.open(FilePreviewRequest(machine: local, pane: g, link: "missing.md"), for: gItem)
        let missing = states.entry(for: gItem, panes: [g])!.model
        select(gItem, g)
        check(await settleAsync(host.view) { if case .failed = missing.state { return true } else { return false } }, "missing.md can't be read")
        window.makeFirstResponder(host.view)
        check(!commandF() && !missing.find.isShown, "with no text shown, ⌘F goes past the preview")

        // A click: where it gives the preview the keyboard, and what it
        // does. The preview gone, the keyboard goes back to the terminal.
        select(fItem, f)
        check(await settleAsync(host.view) { text(fModel) == plan && fModel.visibleBlocks.first == 0 }, "F again")
        window.makeFirstResponder(terminal)
        check(commandF() == false, "the terminal's keyboard")
        window.makeFirstResponder(host.view)
        check(await after(commandF()) { editor() != nil }, "the bar, for its field")
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
        check(await settleAsync(host.view) { inPreview() && window.firstResponder !== host.view }, "the click's taking: AppKit's keyboard and SwiftUI's focus in the preview")
        check(!catcher.takesKeyboard(forClickAt: body), "a click with the keyboard in the preview already changes nothing")
        check(commandF(), "⌘F is then the preview's")
        // Expanded and restored to its size, as before: the keyboard goes
        // back to the terminal it came from.
        select(fItem, f, expanded: true)
        check(await settleAsync(host.view) { inPreview() && window.firstResponder !== host.view }, "expanded, the preview keeps the keyboard")
        select(fItem, f)
        check(await settleAsync(host.view) { window.firstResponder === terminal }, "restored to its size, the terminal has the keyboard back")
        catcher.takeKeyboard()
        check(await settleAsync(host.view) { inPreview() }, "a click in the preview again")
        host.rootView = FindRoot(entry: nil, store: store, closes: closes)
        check(await settleAsync(host.view) { window.firstResponder === terminal }, "the preview gone, the terminal has the keyboard back")
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
    static func reload(directory: String, store: MachineStore, local: Machine, states: FilePreviewPaneStates) async throws {
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
        let mainSource = "int main(void) {\n" + (1...300).map { "    step(\($0));" }.joined(separator: "\n") + "\n}\n"
        try write(mainSource, "main.c")

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
        func outlineTrigger() -> NSObject? { element("preview.outline.trigger") }
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
        func after(_ immediate: Bool, until condition: @escaping () -> Bool) async -> Bool {
            guard immediate else { return false }
            return await settleAsync(host.view, until: condition)
        }
        func phase(_ model: FilePreviewModel) -> String {
            switch model.state {
            case .loading: return "loading"
            case .loaded(let document):
                switch document.content {
                case .text(let value, let markdown): return "loaded-text(chars=\(value.count),markdown=\(markdown))"
                case .image: return "loaded-image"
                }
            case .failed: return "failed"
            }
        }
        func initialLoadDiagnostic(_ model: FilePreviewModel, expectedText: String?, requestID: UUID) -> String {
            let scroll = documentScroll(in: host.view)
            let frame = scroll?.documentView?.frame
            let viewport = scroll?.contentView.bounds
            let offset = scroll?.contentView.bounds.origin
            let textMatches = expectedText.map { String(text(model) == $0) } ?? "not-applicable"
            return "textMatches=\(textMatches) phase=\(phase(model)) requestID=\(requestID.uuidString) visibleBlocks=\(model.visibleBlocks) visibleLines=\(model.visibleLines) scrollDocument=\(frame.map { "(w=\(String(format: "%.1f", $0.width)),h=\(String(format: "%.1f", $0.height)))" } ?? "missing") scrollViewport=\(viewport.map { "(w=\(String(format: "%.1f", $0.width)),h=\(String(format: "%.1f", $0.height)))" } ?? "missing") scrollOffset=\(offset.map { "(x=\(String(format: "%.1f", $0.x)),y=\(String(format: "%.1f", $0.y)))" } ?? "missing")"
        }

        // R: the plan, rendered, with its table of contents closed until its viewport trigger is revealed.
        states.open(FilePreviewRequest(machine: local, pane: r, link: "reload.md"), for: rItem)
        let rModel = states.entry(for: rItem, panes: [r])!.model
        select(rItem, r)
        check(await settleAsync(host.view) { text(rModel) == plan(0) && outlineShown().isEmpty && outlineTrigger() != nil },
              "R's plan is read, with a closed viewport TOC trigger; \(initialLoadDiagnostic(rModel, expectedText: plan(0), requestID: states.entry(for: rItem, panes: [r])!.request.id))")
        check(await settleAsync(host.view) { reloadButton() != nil }, "the header has a Reload button")
        check(label(reloadButton()!) == "Reload" && reloadButton()!.value(forKey: "accessibilityHelp") as? String == "Reload (⌘R)" && isEnabled(reloadButton()),
              "named Reload for VoiceOver, its help giving ⌘R, enabled once the file is read")
        check(await settleAsync(host.view) {
            guard let reload = frame(reloadButton()), let expand = frame(element("preview.expand")),
                  let close = frame(button(host.view, named: "Close Preview")) else { return false }
            return reload.maxX <= expand.minX && expand.maxX <= close.minX && abs(reload.midY - expand.midY) < 2
        }, "Reload remains in the header before Expand and Close")

        // Scrolled down, read again: the new text in the same scroll view,
        // at the same place, its new heading listed.
        check(await settleAsync(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 2000 }, "R's rendering is laid out")
        let scrollView = documentScroll(in: host.view)
        scroll(scrollView!, to: 900)
        check(await settleAsync(host.view) { abs((rModel.scrollOffset?.y ?? 0) - 900) < 1 }, "R is scrolled to 900")
        try write(plan(1))
        check(press(reloadButton()), "Reload can be pressed")
        check(await settleAsync(host.view) { text(rModel) == plan(1) && !rModel.isReading }, "pressed, R's file is read again")
        check(await after(outlineShown().isEmpty && press(outlineTrigger())) { outlineShown() == ["Reload plan", "Tail", "Added 1"] },
              "the changed reload closes the TOC until its trigger reveals the new heading")
        drain(host.view)
        check(documentScroll(in: host.view) === scrollView, "the same scroll view shows the new text: the rendering isn't made anew")
        check(abs(place().y - 900) < 2 && abs((rModel.scrollOffset?.y ?? 0) - 900) < 2, "at the place it was scrolled to")
        check(!rModel.showsSource && rModel.link?.line == nil && isEnabled(reloadButton()), "still rendered, Reload enabled again")

        // Another pane and back: R comes back at 900, is scrolled on to
        // 1500, and read again stays there, not taken back to 900.
        let other = "# S's own\n\nA short file."
        try write(other, "other.md")
        states.open(FilePreviewRequest(machine: local, pane: s, link: "other.md"), for: sItem)
        let sModel = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(await settleAsync(host.view) { text(sModel) == other },
              "S meanwhile; \(initialLoadDiagnostic(sModel, expectedText: other, requestID: states.entry(for: sItem, panes: [s])!.request.id))")
        select(rItem, r)
        check(await settleAsync(host.view) { abs(place().y - 900) < 2 } && text(rModel) == plan(1), "R comes back at 900, not read again")
        drain(host.view)
        scroll(documentScroll(in: host.view)!, to: 1500)
        check(await settleAsync(host.view) { abs((rModel.scrollOffset?.y ?? 0) - 1500) < 1 }, "and is scrolled on to 1500")
        let backView = documentScroll(in: host.view)
        try write(plan(2))
        check(await after(press(reloadButton())) { text(rModel) == plan(2) }, "read again")
        drain(host.view)
        check(documentScroll(in: host.view) === backView && abs(place().y - 1500) < 2 && abs((rModel.scrollOffset?.y ?? 0) - 1500) < 2,
              "read again, it stays at 1500: the place it came back at isn't put back")

        // Changed documents always start with a closed viewport TOC, then
        // expose the headings again through their one-way trigger.
        try write(plan(3))
        check(await after(press(reloadButton())) { text(rModel) == plan(3) && outlineShown().isEmpty }, "read again with a closed TOC")
        check(await after(press(outlineTrigger())) { outlineShown() == ["Reload plan", "Tail", "Added 1", "Added 2", "Added 3"] },
              "the trigger reveals headings from the new document")

        // The find bar: kept open, with what it looks for, its matches
        // counted in the new text, at none of them yet.
        window.makeFirstResponder(host.view)
        check(await after(commandF()) { editor() != nil }, "the find bar, the keyboard in its field")
        editor()!.insertText("needle", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(await settleAsync(host.view) { rModel.find.query == "needle" && count().map { $0.hasSuffix("/ 5") } == true }, "five needles")
        let findField = field()
        try write(plan(4))
        check(commandR(), "⌘R with the keyboard in the find field is the preview's")
        check(await settleAsync(host.view) { text(rModel) == plan(4) && count() == "0 / 6" }, "read again: six needles counted, at none of them yet")
        drain(host.view)
        check(rModel.find.isShown && rModel.find.query == "needle" && rModel.find.current == nil && field() === findField && field()?.stringValue == "needle",
              "the same find bar, what it looks for kept")
        check(editor() != nil, "the field keeps the keyboard")
        editor()?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check(await settleAsync(host.view) { !rModel.find.isShown && element("preview.find") == nil }, "the find bar closed")

        // A link to a line, in the source: read again, the line stays
        // marked, and the preview isn't taken back to it.
        states.open(FilePreviewRequest(machine: local, pane: s, link: "reload.md:40"), for: sItem)
        let lined = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(await settleAsync(host.view) { text(lined) == plan(4) && lined.showsSource && lined.visibleLines.first == 40 },
              "the link's line at the top of the source; \(initialLoadDiagnostic(lined, expectedText: plan(4), requestID: states.entry(for: sItem, panes: [s])!.request.id))")
        scroll(documentScroll(in: host.view)!, to: 2500)
        check(await settleAsync(host.view) { abs((lined.scrollOffset?.y ?? 0) - 2500) < 1 && (lined.visibleLines.first ?? 0) > 80 }, "scrolled away from it")
        let linedView = documentScroll(in: host.view)
        try write(plan(5))
        check(await after(press(reloadButton())) { text(lined) == plan(5) }, "read again")
        drain(host.view)
        check(documentScroll(in: host.view) === linedView && abs(place().y - 2500) < 2 && (lined.visibleLines.first ?? 0) > 80,
              "it stays where it was scrolled to, not taken back to the line")
        check(lined.showsSource && lined.link?.line == 40, "in the source, the line linked to kept")
        // Read again shorter than where it was scrolled to: at its end.
        let shorter = (1...60).map { "Line \($0) of the shorter plan" }.joined(separator: "\n")
        try write(shorter)
        check(await after(press(reloadButton())) { text(lined) == shorter }, "read again, shorter")
        drain(host.view)
        check(await settleAsync(host.view) {
            guard let scroll = documentScroll(in: host.view), let height = scroll.documentView?.frame.height else { return false }
            let end = height - scroll.contentView.bounds.height
            return end > 100 && abs(scroll.contentView.bounds.origin.y - end) < 2
        }, "at its end, not its top")

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
        check(await settleAsync(host.view) { text(listed) == list(0) && element("preview.source") != nil },
              "the list is read; \(initialLoadDiagnostic(listed, expectedText: list(0), requestID: states.entry(for: rItem, panes: [r])!.request.id))")
        check(await after(press(element("preview.source"))) { listed.showsSource && listed.visibleLines.first == 1 }, "in the source, at its top")
        check(await settleAsync(host.view) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 3000 }, "the list's source is laid out")
        scroll(documentScroll(in: host.view)!, to: 1200)
        check(await settleAsync(host.view) { abs((listed.scrollOffset?.y ?? 0) - 1200) < 1 }, "scrolled to 1200")
        try FileManager.default.removeItem(atPath: directory + "/list.md")
        check(await after(press(reloadButton())) { failed(listed) && button(host.view, named: "Retry") != nil }, "the file gone: Cannot Preview File, with Retry")
        drain(host.view)
        check(reloadButton() != nil && isEnabled(reloadButton()) && element("preview.source") == nil, "the header's Reload stays, enabled")
        check(listed.showsSource && abs((listed.scrollOffset?.y ?? 0) - 1200) < 1 && listed.link?.path == directory + "/list.md",
              "how it was looked at is kept")
        let reloadStillGone = await after(press(reloadButton())) { failed(listed) && !listed.isReading }
        check(reloadStillGone && button(host.view, named: "Retry") != nil, "Reload again: still gone")
        try write(list(1), "list.md")
        check(await after(press(button(host.view, named: "Retry"))) { text(listed) == list(1) }, "back, Retry reads it")
        check(await settleAsync(host.view) { listed.showsSource && element("preview.source") != nil && (listed.visibleLines.first ?? 0) > 1 }, "in the source")
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
        check(await after(commandR()) { text(listed) == list(2) }, "with the preview's keyboard, ⌘R reads it again")
        try FileManager.default.removeItem(atPath: directory + "/list.md")
        check(await after(commandR()) { failed(listed) }, "⌘R: gone")
        try write(list(3), "list.md")
        window.makeFirstResponder(host.view)
        check(await after(commandR()) { text(listed) == list(3) }, "⌘R on the failed screen reads it again")
        drain(host.view)
        check(listed.showsSource && abs(place().y - 1200) < 2, "in the source, at its place")
        check(await after(commandR() && commandR() && commandR()) { !listed.isReading && text(listed) == list(3) }, "⌘R pressed over and over")
        drain(host.view)
        check(abs(place().y - 1200) < 2, "still at its place")
        window.makeFirstResponder(terminal)

        // A file that isn't Markdown has Reload too, with no Source or
        // table of contents button.
        states.open(FilePreviewRequest(machine: local, pane: s, link: "main.c"), for: sItem)
        let source = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(await settleAsync(host.view) { text(source) == mainSource && reloadButton() != nil },
              "main.c is read, with Reload; \(initialLoadDiagnostic(source, expectedText: mainSource, requestID: states.entry(for: sItem, panes: [s])!.request.id))")
        check(element("preview.source") == nil && element("preview.outline.trigger") == nil, "with no Source or table of contents trigger")
        check(await settleAsync(host.view) {
            guard let reload = frame(reloadButton()), let expand = frame(element("preview.expand")),
                  let close = frame(button(host.view, named: "Close Preview")) else { return false }
            return reload.maxX <= expand.minX && expand.maxX <= close.minX
        }, "third from the right there too")

        // An image: read again, at the same place across and down, drawn anew.
        try png(width: 1600, height: 1600, white: 0.2).write(to: URL(fileURLWithPath: directory + "/photo.png"))
        states.open(FilePreviewRequest(machine: local, pane: s, link: "photo.png"), for: sItem)
        let photo = states.entry(for: sItem, panes: [s])!.model
        select(sItem, s)
        check(await settleAsync(host.view) {
            guard case .loaded(let document) = photo.state, case .image = document.content else { return false }
            return (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) > 1600
        }, "the image is read and drawn; \(initialLoadDiagnostic(photo, expectedText: nil, requestID: states.entry(for: sItem, panes: [s])!.request.id))")
        check(reloadButton() != nil && isEnabled(reloadButton()), "an image has Reload too")
        let imageView = documentScroll(in: host.view)!
        imageView.contentView.scroll(to: NSPoint(x: 300, y: 500))
        imageView.reflectScrolledClipView(imageView.contentView)
        check(await settleAsync(host.view) { abs((photo.scrollOffset?.x ?? 0) - 300) < 1 && abs((photo.scrollOffset?.y ?? 0) - 500) < 1 }, "scrolled across and down")
        try png(width: 1600, height: 1200, white: 0.8).write(to: URL(fileURLWithPath: directory + "/photo.png"))
        check(await after(press(reloadButton())) { (documentScroll(in: host.view)?.documentView?.frame.height ?? 0) < 1500 }, "read again, the new image is drawn")
        drain(host.view)
        check(documentScroll(in: host.view) === imageView && abs(place().x - 300) < 2 && abs(place().y - 500) < 2, "at the same place across and down")

        host.rootView = FindRoot(entry: nil, store: store, closes: closes)
        drain(host.view)
    }
}
