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
/// split views' detail, as `ContentView` puts it there.
@MainActor @Observable final class ToolbarProbe {
    var session: TitleRenameSession?
    @ObservationIgnored var endings: [(TitleRenameEnding, String)] = []
    func end(_ session: TitleRenameSession, _ ending: TitleRenameEnding) {
        guard session.end() else { return }
        endings.append((ending, session.text))
        if self.session === session { self.session = nil }
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
                .toolbar(removing: probe.session == nil ? nil : .title)
                .toolbar {
                    if let session = probe.session {
                        ToolbarItem(placement: .navigation) {
                            TitleRenameField(session: session, canSubmit: { TitleRename.canSubmit($0, for: session.item) }, onEnd: probe.end)
                                .id(session.id)
                                .frame(minWidth: 160, idealWidth: 280, maxWidth: 420)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarItem(placement: .primaryAction) { Button("Preview") {} }
                }
        }
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
    static func window(_ root: some View, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        window.contentViewController = host
        // Taking the controller's view resizes the window to it.
        window.setContentSize(NSSize(width: width, height: 500))
        return window
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
        let text = toolbar.firstResponder as! NSTextView
        check(text.string == "build" && text.selectedRange() == NSRange(location: 0, length: 5), "starting from the name, selected")
        text.insertText("server", replacementRange: NSRange(location: NSNotFound, length: 0))
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(probe.endings.count == 1 && probe.endings[0].0 == .submit && probe.endings[0].1 == "server", "Return in the toolbar sends the name")
        spin(until: { fields(in: frameView()).isEmpty && toolbar.titleVisibility == .visible }, "the field goes, and the title is back")
        toolbar.close()

        print("PASS \(checks) title rename window title/terminal title precedence/preview/title removal/toolbar field checks; owned never-shown windows, no app or herdr")
    }
}
