import SwiftUI
import AppKit

// Runtime launch/authentication is not exercised by the window's size.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

/// Where the terminal and the panel end up, found by identifier.
final class Marker: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
struct MarkerView: NSViewRepresentable {
    let tag: String
    func makeNSView(context: Context) -> Marker { let view = Marker(); view.identifier = .init(tag); return view }
    func updateNSView(_ view: Marker, context: Context) {}
}

enum Panel { case none, preview, browser }

@MainActor @Observable final class SizeProbe {
    var panel = Panel.none
    var session: TitleRenameSession?
}

/// The production split views with the detail as `ContentView` lays it out:
/// the terminal at 320pt or more, the preview's or the browser's column
/// beside it, the window's toolbar items over the sidebar and the detail.
struct SizeRoot: View {
    let probe: SizeProbe
    let sidebarState: WorkspaceSidebarState
    var body: some View {
        let shownPreview: Bool? = probe.panel == .preview ? true : nil
        let browserShown = probe.panel == .browser
        // The same expression as ContentView's (the runner checks it there).
        let detailMinimumWidth: CGFloat = 320 + (shownPreview != nil ? 1 + 320 : browserShown ? 1 + 360 : 0)
        WorkspaceNavigationSplitView(sidebarState: sidebarState, detailMinimumWidth: detailMinimumWidth) {
            Text(verbatim: "board")
                .navigationSplitViewColumnWidth(min: WorkspaceSidebarMetrics.minimum, ideal: WorkspaceSidebarMetrics.preferred, max: WorkspaceSidebarMetrics.maximum)
                .toolbar {
                    ToolbarItem { Button {} label: { Label("Settings", systemImage: "gearshape") } }
                    ToolbarItem { Button {} label: { Label("New Tab", systemImage: "plus") } }
                    ToolbarItem { Button {} label: { Label("Go to Agent or Pane", systemImage: "rectangle.stack") } }
                }
        } detail: {
            WorkspaceDetailSplitView(showsPanel: shownPreview != nil || browserShown,
                                     panelMinimum: shownPreview != nil ? 320 : 360, panelIdeal: shownPreview != nil ? 560 : 640) {
                MarkerView(tag: "terminal").frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(WorkspaceSidebarDetailLayout())
            } panel: {
                if shownPreview != nil || browserShown {
                    MarkerView(tag: "panel").frame(minWidth: browserShown ? 360 : 320, maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(WorkspaceSidebarDetailLayout())
                }
            }
            .navigationTitle("pane title")
            .background { TitleRenameToolbarRoom(active: probe.session != nil) }
            .toolbar(removing: probe.session == nil ? nil : .title)
            .toolbar {
                if let session = probe.session {
                    ToolbarItem(id: TitleRenameToolbar.itemID, placement: .navigation) {
                        TitleRenameField(session: session, canSubmit: { _ in true }, onEnd: { session, _ in _ = session.end() })
                            .id(session.id)
                            .frame(minWidth: TitleRenameToolbar.minimumWidth, idealWidth: TitleRenameToolbar.idealWidth, maxWidth: TitleRenameToolbar.idealWidth)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .navigation)
                }
                ToolbarItem(placement: .primaryAction) { Button {} label: { Label("Show Browser", systemImage: "globe") } }
                ToolbarItem(placement: .primaryAction) { Button {} label: { Label("Show Preview", systemImage: "doc.text") } }
            }
        }
    }
}

@main @MainActor enum WindowMinimumSizeTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: @autoclosure () -> String) { precondition(value, message()); checks += 1 }
    static func spin(_ turns: Int = 60) {
        for _ in 0..<turns { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    static func spin(until condition: () -> Bool, _ message: @autoclosure () -> String) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        check(condition(), message())
    }
    static func find(_ view: NSView, _ tag: String) -> NSView? {
        if view.identifier?.rawValue == tag { return view }
        return view.subviews.lazy.compactMap { find($0, tag) }.first
    }
    static func split(in view: NSView) -> NSSplitViewController? {
        if let v = view as? NSSplitView, let c = v.delegate as? NSSplitViewController { return c }
        return view.subviews.lazy.compactMap { split(in: $0) }.first
    }
    static func fields(in view: NSView) -> [TitleRenameTextField] {
        ((view as? TitleRenameTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields(in:))
    }
    static func frame(_ view: NSView?) -> NSRect { view.map { $0.convert($0.bounds, to: nil) } ?? .zero }

    /// An owned window that is never ordered in, with the hosting
    /// controller sized as a `.contentMinSize` scene sizes it.
    static func window(_ root: some View, width: CGFloat, height: CGFloat = 700) -> (NSWindow, NSHostingController<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: width, height: height))
        return (window, host)
    }

    static func policyChecks() {
        let expected: [(Bool, CGFloat, CGFloat)] = [(true, 320, 600), (false, 320, 480), (true, 641, 921), (false, 641, 641), (true, 681, 961), (false, 681, 681)]
        for (reserves, detail, width) in expected {
            check(WorkspaceWindowMetrics.minimumWidth(detail: detail, reservesSidebar: reserves) == width, "minimum width for detail \(detail), sidebar \(reserves) is \(width)")
        }
        check(WorkspaceWindowMetrics.minimumHeight == 400, "minimum content height is 400pt")
        let automatic = WorkspaceSidebarState()
        check(automatic.isPinned && !automatic.reservesWidth, "before AppKit reports the sidebar, nothing is reserved for it")
        automatic.noteNativeSidebar(isCollapsed: false)
        check(automatic.reservesWidth, "a pinned sidebar AppKit has open is reserved")
        automatic.noteNativeSidebar(isCollapsed: true)
        automatic.reconcileNativeSidebar(isCollapsed: true, revision: automatic.pinRevision)
        check(!automatic.isPinned && !automatic.reservesWidth, "a restored hidden sidebar reserves nothing")
        automatic.noteNativeSidebar(isCollapsed: false)
        automatic.reconcileNativeSidebar(isCollapsed: false, revision: automatic.pinRevision)
        check(!automatic.reservesWidth, "a hover drawer open without pin intent reserves nothing")
        automatic.togglePin()
        check(automatic.isPinned && automatic.reservesWidth, "pinning the open drawer reserves it")
    }

    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        policyChecks()
        let item = AgentSummary(json: .object(["pane_id": .string("w1:p1"), "terminal_id": .string("terminal-1"), "label": .string("build")]), on: nil)!
        var measurements: [[String: Any]] = []

        // Each sidebar state and panel at exactly the window's minimum.
        for pinned in [true, false] {
            for panel in [Panel.none, .preview, .browser] {
                let probe = SizeProbe(); probe.panel = panel
                let state = WorkspaceSidebarState()
                let (window, host) = window(SizeRoot(probe: probe, sidebarState: state), width: 1200)
                defer { window.close() }
                spin(until: { split(in: host.view) != nil && state.nativeSidebarIsOpen }, "the native split mounts and reports its sidebar open")
                if !pinned {
                    state.togglePin()
                    spin(until: { split(in: host.view)!.splitViewItems.first!.isCollapsed && !state.nativeSidebarIsOpen }, "the sidebar hides")
                }
                let detail: CGFloat = panel == .none ? 320 : panel == .preview ? 641 : 681
                let width = max(480, detail + (pinned ? 280 : 0))
                spin(until: { window.contentMinSize.width == width }, "\(pinned ? "pinned" : "hidden") \(panel): the window's minimum width becomes \(width), is \(window.contentMinSize.width)")
                window.setContentSize(window.contentMinSize)
                spin()
                let layout = window.contentLayoutRect.size
                check(layout.width == width && layout.height == 400, "below the toolbar the minimum content is \(width) × 400, is \(layout)")
                let terminal = frame(find(host.view, "terminal")), panelFrame = frame(find(host.view, "panel"))
                let controller = split(in: host.view)!, sidebar = controller.splitViewItems.first!
                if pinned {
                    check(!sidebar.isCollapsed && sidebar.viewController.view.frame.width == WorkspaceSidebarMetrics.minimum, "the pinned sidebar keeps its 280pt minimum")
                    check(terminal.minX >= sidebar.viewController.view.frame.width, "the terminal is beside the pinned sidebar, not under it")
                }
                check(terminal.width == (panel == .none ? width - (pinned ? 280 : 0) : 320), "\(pinned) \(panel): the terminal keeps its 320pt minimum, is \(terminal.width)")
                if panel != .none {
                    check(panelFrame.width == (panel == .preview ? 320 : 360), "\(panel) keeps its minimum, is \(panelFrame.width)")
                    check(panelFrame.minX == terminal.maxX + 1, "past the detail split's 1pt divider")
                }
                check(terminal.height == 400 && terminal.height - 2 * 7 >= 240, "the terminal keeps at least 240pt of display height below the toolbar")
                check(window.toolbar != nil && host.view.safeAreaInsets.top >= 40, "the toolbar stays over the content")
                let shown = window.toolbar!.items.filter { $0.view?.window === window }.count
                // The title's place, as the field that is typed into it.
                probe.session = TitleRenameSession(item: .pane(item))
                spin(until: { window.toolbar!.items.contains { $0.itemIdentifier.rawValue == TitleRenameToolbar.itemID && $0.minSize.width == TitleRenameToolbar.minimumWidth } }, "the rename item gets its 120...280pt range")
                spin()
                let field = fields(in: window.contentView!.superview!).first { $0.window === window }
                let renameItems = window.toolbar!.items.filter { $0.view?.window === window }.count
                measurements.append(["pinned": pinned, "panel": "\(panel)", "width": width, "terminalWidth": terminal.width, "panelWidth": panelFrame.width,
                                     "terminalHeight": terminal.height, "toolbarItemsShown": shown, "toolbarItems": window.toolbar!.items.count - 1,
                                     "renameFieldWidth": field.map { frame($0).width } ?? 0, "toolbarItemsShownWhileRenaming": renameItems])
                if pinned {
                    check(field.map { frame($0).width >= TitleRenameToolbar.minimumWidth } == true, "with the sidebar pinned the rename field is in the toolbar at 120pt or more")
                }
                probe.session = nil
                spin(20)
                check(!window.isVisible, "the window is never shown")
            }
        }

        // Opening a panel grows the window to its minimum; closing it, or
        // hiding the sidebar, doesn't shrink it.
        do {
            let probe = SizeProbe(), state = WorkspaceSidebarState()
            let (window, host) = window(SizeRoot(probe: probe, sidebarState: state), width: 600, height: 400)
            defer { window.close() }
            spin(until: { split(in: host.view) != nil && state.reservesWidth && window.contentMinSize.width == 600 }, "pinned terminal: 600pt minimum")
            let origin = window.frame.origin
            probe.panel = .browser
            spin(until: { window.contentLayoutRect.width == 961 }, "opening the browser grows the window to 961pt, is \(window.contentLayoutRect.width)")
            check(window.frame.origin.x == origin.x, "growing keeps the window's leading edge")
            probe.panel = .none
            spin(until: { window.contentMinSize.width == 600 }, "closing the browser relaxes the minimum")
            spin()
            check(window.contentLayoutRect.width == 961, "closing the browser leaves the window as wide as it was")
            state.togglePin()
            spin(until: { window.contentMinSize.width == 480 }, "hiding the sidebar relaxes the minimum")
            spin()
            check(window.contentLayoutRect.width == 961, "hiding the sidebar leaves the window as wide as it was")
            window.setContentSize(NSSize(width: 480, height: 400))
            spin()
            state.togglePin()
            spin(until: { window.contentMinSize.width == 600 && window.contentLayoutRect.width >= 600 }, "pinning the sidebar at 480pt grows the window to at least 600pt, is \(window.contentLayoutRect.width)")
            check(!window.isVisible, "the window is never shown")
        }

        // A sidebar restored hidden never widens a narrow restored window,
        // even for the moment before AppKit reports it.
        do {
            let probe = SizeProbe(), state = WorkspaceSidebarState()
            let (window, host) = window(SizeRoot(probe: probe, sidebarState: state), width: 520, height: 400)
            defer { window.close() }
            host.view.layoutSubtreeIfNeeded()
            let controller = split(in: host.view)
            check(controller != nil, "the native split exists before the first run-loop turn")
            controller!.splitViewItems.first!.isCollapsed = true
            var widest = window.contentLayoutRect.width
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                widest = max(widest, window.contentLayoutRect.width)
            }
            check(!state.isPinned && !state.reservesWidth && window.contentMinSize.width == 480, "the restored hidden sidebar reserves nothing")
            check(widest == 520, "the 520pt restored window was never widened, widest \(widest)")
            check(!window.isVisible, "the window is never shown")
        }

        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS \(checks) main window minimum size policy/geometry/grow-not-shrink/restored-hidden checks; owned never-shown windows, no app or herdr")
    }
}
