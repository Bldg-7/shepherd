import SwiftUI
import AppKit

// Runtime launch/authentication is not exercised by the window's title.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

/// The window's title as `ContentView` builds it, around the production
/// split views: the column's title, the terminal's own title set inside the
/// detail's native hosting, a file preview's beside it, and the title taken
/// out of the toolbar while a name is typed in its place.
@MainActor @Observable final class TitleState {
    var columnTitle = "column"
    var terminalTitle: String? = "terminal"
    var showsPanel = false
    var editing = false
}

struct SplitRoot: View {
    let state: TitleState
    var body: some View {
        WorkspaceNavigationSplitView { Text(verbatim: "board").navigationTitle("Machine") } detail: {
            WorkspaceDetailSplitView(showsPanel: state.showsPanel, panelMinimum: 320, panelIdeal: 560) {
                if let title = state.terminalTitle { Color.black.navigationTitle(title) } else { Color.black }
            } panel: {
                if state.showsPanel { Color.white.navigationTitle("README.md") }
            }
            .navigationTitle(state.columnTitle)
            .toolbar(removing: state.editing ? .title : nil)
        }
    }
}

/// The production field in a `.navigation` toolbar item of the production
/// split views' detail, with the space after it, as `ContentView` puts them
/// there; and the production watcher for a double-click on the title,
/// which renames `item` unless something covers the terminal.
@MainActor @Observable final class ToolbarProbe {
    var session: TitleRenameSession?
    @ObservationIgnored var item: BoardItem?
    @ObservationIgnored var coversTerminal = false
    @ObservationIgnored var endings: [(TitleRenameEnding, String)] = []
    @ObservationIgnored var renamesFromTitle = 0
    func end(_ session: TitleRenameSession, _ ending: TitleRenameEnding) {
        guard session.end() else { return }
        endings.append((ending, session.text))
        if self.session === session { self.session = nil }
    }
    func renameFromTitle() -> Bool {
        guard session == nil, !coversTerminal, let item else { return false }
        renamesFromTitle += 1
        session = TitleRenameSession(item: item)
        return true
    }
}

struct ToolbarRoot: View {
    let probe: ToolbarProbe
    var body: some View {
        WorkspaceNavigationSplitView { Text(verbatim: "board") } detail: {
            WorkspaceDetailSplitView(showsPanel: false, panelMinimum: 320, panelIdeal: 560) {
                Color.black.navigationTitle("pane title")
            } panel: { EmptyView() }
                .navigationTitle("pane title")
                .background { TitleDoubleClick(rename: probe.renameFromTitle) }
                .toolbar(removing: probe.session == nil ? nil : .title)
                .toolbar {
                    if let session = probe.session {
                        ToolbarItem(placement: .navigation) {
                            TitleRenameField(session: session, canSubmit: { TitleRename.canSubmit($0, for: session.item) }, onEnd: probe.end)
                                .id(session.id)
                                .frame(minWidth: 160, idealWidth: 280, maxWidth: 420)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.flexible, placement: .navigation)
                    }
                    ToolbarItem(placement: .primaryAction) { Button("Preview") {} }
                }
        }
    }
}

/// A window that keeps the mouse presses and releases it is handed: those
/// no local monitor has kept from it.
final class RecordingWindow: NSWindow {
    var received: [(type: NSEvent.EventType, clickCount: Int)] = []
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp {
            received.append((event.type, event.clickCount))
        }
        super.sendEvent(event)
    }
}

@main @MainActor enum TitleRenameToolbarTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func spin(until condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        check(condition(), message)
    }
    static func fields(in view: NSView) -> [TitleRenameTextField] {
        ((view as? TitleRenameTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields(in:))
    }
    static func window(_ root: some View, width: CGFloat) -> RecordingWindow {
        let window = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                                     styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        window.contentViewController = host
        // Taking the controller's view resizes the window to it.
        window.setContentSize(NSSize(width: width, height: 500))
        return window
    }

    /// A click, or a double-click, at `point` in `window` as the app's
    /// event loop hands it out: each press with its count, its release
    /// queued behind it for whatever tracking the press starts, and what is
    /// still queued after that sent on.
    static func click(_ window: NSWindow, at point: NSPoint, count: Int) {
        let time = ProcessInfo.processInfo.systemUptime
        for n in 1...count {
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time + Double(n) * 0.05,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 2 * n, clickCount: n, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + Double(n) * 0.05 + 0.01,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 2 * n + 1, clickCount: n, pressure: 0)!
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// The label showing `window`'s title in its toolbar, if it shows.
    static func titleLabel(in window: NSWindow) -> NSTextField? {
        func labels(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(labels(in:))
        }
        return labels(in: window.contentView!.superview!).first {
            !$0.isEditable && $0.stringValue == window.title && !$0.isDescendant(of: window.contentView!) && !$0.isHiddenOrHasHiddenAncestor
        }
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // Whose title the window takes.
        let state = TitleState()
        let split = window(SplitRoot(state: state), width: 1200)
        spin(until: { split.title == "terminal" }, "the terminal's own title is the window's, over the column's")
        state.terminalTitle = "typed name"
        spin(until: { split.title == "typed name" }, "so a name shown before herdr reports it has to be set on the terminal")
        state.showsPanel = true
        state.terminalTitle = "terminal"
        spin(until: { split.title == "terminal" }, "and it stays the window's while a file preview is open beside it")
        state.showsPanel = false
        state.terminalTitle = nil
        state.columnTitle = "column 2"
        spin(until: { split.title == "column 2" }, "without one, the column's title is the window's")
        state.terminalTitle = "terminal"
        spin(until: { split.title == "terminal" && split.titleVisibility == .visible }, "the title shows")
        state.editing = true
        spin(until: { split.titleVisibility == .hidden }, "taken out of the toolbar from around the column while a name is typed, whoever's it is")
        check(split.title == "terminal", "the window keeps its title meanwhile (the Window menu's)")
        state.editing = false
        spin(until: { split.titleVisibility == .visible }, "and put back")
        split.close()

        // The field in the toolbar, in the title's place.
        let probe = ToolbarProbe()
        let toolbar = window(ToolbarRoot(probe: probe), width: 1000)
        spin(until: { toolbar.toolbar != nil && toolbar.title == "pane title" }, "the detail's title is the window's")
        let item = AgentSummary(json: .object(["pane_id": .string("w1:p1"), "terminal_id": .string("terminal-1"), "label": .string("build")]), on: nil)!
        /// The detail's last item, the Preview button, where it is in the window.
        func previewFrame() -> NSRect? {
            toolbar.contentView!.superview!.layoutSubtreeIfNeeded()
            guard let view = toolbar.toolbar!.items.last?.view, view.window === toolbar else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        let previewBefore = previewFrame()
        check(previewBefore != nil, "the Preview button is in the window's toolbar")
        let session = TitleRenameSession(item: .pane(item))
        probe.session = session
        func frameView() -> NSView { toolbar.contentView!.superview! }
        spin(until: { fields(in: frameView()).count == 1 && fields(in: frameView())[0].window === toolbar }, "the field is in the window's toolbar")
        let field = fields(in: frameView())[0]
        check(toolbar.titleVisibility == .hidden, "the title is out of the toolbar while the field stands in its place")
        let identifiers = toolbar.toolbar!.items.map(\.itemIdentifier.rawValue)
        let separator = identifiers.firstIndex { $0.contains("splitViewSeparator") }
        let fieldItem = toolbar.toolbar!.items.firstIndex { $0.view.map { !fields(in: $0).isEmpty } ?? false }
        check(separator != nil && fieldItem != nil && fieldItem! > separator! && fieldItem! < identifiers.count - 1,
              "in the detail's part of the toolbar, before its other items: where the title was")
        spin(until: { (toolbar.firstResponder as? NSTextView)?.delegate === field }, "with the keyboard")
        let previewEditing = previewFrame(), fieldFrame = field.convert(field.bounds, to: nil)
        check(previewEditing == previewBefore, "the buttons after the title stay where they were while the field stands in its place")
        check(abs(fieldFrame.midY - previewBefore!.midY) < 0.5 && fieldFrame.height <= previewBefore!.height,
              "the field is on the buttons' line, and no taller than they are")
        let text = toolbar.firstResponder as! NSTextView
        check(text.string == "build" && text.selectedRange() == NSRange(location: 0, length: 5), "starting from the name, selected")
        text.insertText("server", replacementRange: NSRange(location: NSNotFound, length: 0))
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(probe.endings.count == 1 && probe.endings[0].0 == .submit && probe.endings[0].1 == "server", "Return in the toolbar sends the name")
        spin(until: { fields(in: frameView()).isEmpty && toolbar.titleVisibility == .visible }, "the field goes, and the title is back")
        check(previewFrame() == previewBefore, "the buttons too")

        // A double-click on the title's text: the same rename. Every other
        // click, and a double-click anywhere else, is the system's.
        probe.item = .pane(item)
        spin(until: { titleLabel(in: toolbar) != nil }, "the title's label is in the toolbar")
        let label = titleLabel(in: toolbar)!, title = label.convert(label.bounds, to: nil)
        let onTitle = NSPoint(x: title.midX, y: title.midY)
        func presses() -> [Int] { toolbar.received.filter { $0.type == .leftMouseDown }.map(\.clickCount) }
        toolbar.received = []
        click(toolbar, at: onTitle, count: 1)
        check(probe.renamesFromTitle == 0 && presses() == [1], "a click on the title is the system's")
        toolbar.received = []
        click(toolbar, at: NSPoint(x: (title.maxX + previewBefore!.minX) / 2, y: title.midY), count: 2)
        check(probe.renamesFromTitle == 0 && presses() == [1, 2], "so is a double-click in the bar beside it, to zoom or minimize the window")
        toolbar.received = []
        click(toolbar, at: NSPoint(x: title.maxX + 4, y: title.midY), count: 2)
        check(probe.renamesFromTitle == 0 && presses() == [1, 2], "and one just past the title's text")
        probe.coversTerminal = true
        toolbar.received = []
        click(toolbar, at: onTitle, count: 2)
        check(probe.renamesFromTitle == 0 && probe.session == nil && presses() == [1, 2], "and one on it while there is nothing to rename")
        probe.coversTerminal = false
        toolbar.received = []
        click(toolbar, at: onTitle, count: 2)
        check(probe.renamesFromTitle == 1 && presses() == [1], "a double-click on the title's text renames, and its second press goes no further")
        check(toolbar.received.filter { $0.type == .leftMouseUp }.map(\.clickCount).allSatisfy { $0 == 1 }, "nor does the release after it")
        spin(until: { fields(in: frameView()).count == 1 && (toolbar.firstResponder as? NSTextView)?.delegate === fields(in: frameView())[0] },
             "the field comes up in the title's place, with the keyboard")
        let titleText = toolbar.firstResponder as! NSTextView
        check(titleText.string == "build" && titleText.selectedRange() == NSRange(location: 0, length: 5), "starting from the name, selected, as from the row's Rename")
        toolbar.received = []
        click(toolbar, at: onTitle, count: 2)
        check(probe.renamesFromTitle == 1 && presses() == [1, 2] && (toolbar.firstResponder as? NSTextView) === titleText,
              "a double-click where the title was is the field's while it is up")
        titleText.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check(probe.endings.count == 2 && probe.endings[1].0 == .cancel, "Escape takes it back")
        spin(until: { fields(in: frameView()).isEmpty && toolbar.titleVisibility == .visible }, "the field goes, and the title is back")
        check(!toolbar.isVisible, "none of it showed the window")
        toolbar.close()

        print("PASS \(checks) title rename window title/terminal title precedence/preview/title removal/toolbar field/layout/title double-click checks; owned never-shown windows, no app or herdr")
    }
}
