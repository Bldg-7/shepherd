import SwiftUI
import AppKit

// Runtime launch/authentication is not exercised by the window's title.
public nonisolated enum AgentKind: String, Sendable {
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
    var refresh = 0
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
    let sidebarState: WorkspaceSidebarState
    /// The legacy fixture omits this production seam to prove the native
    /// fixed-width regression it replaces.
    var appliesToolbarRoom = true
    var body: some View {
        WorkspaceNavigationSplitView(sidebarState: sidebarState) { Text(verbatim: "board \(probe.refresh)") } detail: {
            WorkspaceDetailSplitView(showsPanel: false, panelMinimum: 320, panelIdeal: 560) {
                Color.black.navigationTitle("pane title")
            } panel: { EmptyView() }
                .navigationTitle("pane title")
                .background {
                    ZStack {
                        TitleDoubleClick(rename: probe.renameFromTitle)
                        if appliesToolbarRoom {
                            TitleRenameToolbarRoom(active: probe.session != nil)
                        }
                    }
                }
                .toolbar(removing: probe.session == nil ? nil : .title)
                .toolbar {
                    if let session = probe.session {
                        ToolbarItem(id: TitleRenameToolbar.itemID, placement: .navigation) {
                            TitleRenameField(session: session, canSubmit: { TitleRename.canSubmit($0, for: session.item) }, onEnd: probe.end)
                                .id(session.id)
                                .frame(minWidth: TitleRenameToolbar.minimumWidth, idealWidth: TitleRenameToolbar.idealWidth, maxWidth: TitleRenameToolbar.idealWidth)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.flexible, placement: .navigation)
                    }
                    ToolbarItem(placement: .primaryAction) { Button("Browser") {} }
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
    static func spin(until condition: () -> Bool, _ message: @autoclosure () -> String) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        check(condition(), message())
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

        // The unchanged SwiftUI frame reaches AppKit as a fixed 280pt item.
        // Keep this legacy fixture without the room seam as a native negative
        // control: it is the range that made the title field overflow instead
        // of shrink in a narrow toolbar.
        let legacyProbe = ToolbarProbe()
        let legacy = window(ToolbarRoot(probe: legacyProbe, sidebarState: WorkspaceSidebarState(initialVisibility: .all), appliesToolbarRoom: false), width: 700)
        spin(until: { legacy.toolbar != nil }, "the legacy fixture has a toolbar")
        let legacyItemSource = AgentSummary(json: .object(["pane_id": .string("legacy:pane"), "terminal_id": .string("legacy-terminal"), "label": .string("build")]), on: nil)!
        legacyProbe.session = TitleRenameSession(item: .pane(legacyItemSource))
        spin(until: {
            legacy.toolbar?.items.first { $0.itemIdentifier.rawValue == TitleRenameToolbar.itemID }.map {
                $0.minSize.width == 280 && $0.maxSize.width == 280
            } == true
        }, "without the AppKit seam, SwiftUI exposes the original fixed 280pt native range")
        legacy.close()

        // The field in the toolbar, in the title's place.
        let probe = ToolbarProbe()
        let sidebarState = WorkspaceSidebarState(initialVisibility: .all)
        let toolbar = window(ToolbarRoot(probe: probe, sidebarState: sidebarState), width: 1000)
        spin(until: { toolbar.toolbar != nil && toolbar.title == "pane title" }, "the detail's title is the window's")
        let item = AgentSummary(json: .object(["pane_id": .string("w1:p1"), "terminal_id": .string("terminal-1"), "label": .string("build")]), on: nil)!
        /// The detail's last item, the Preview button, where it is in the window.
        func previewFrame() -> NSRect? {
            toolbar.contentView!.superview!.layoutSubtreeIfNeeded()
            guard let view = toolbar.toolbar!.items.last?.view, view.window === toolbar else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        func renameItem(in window: NSWindow = toolbar) -> NSToolbarItem? {
            window.toolbar?.items.first { $0.itemIdentifier.rawValue == TitleRenameToolbar.itemID }
        }
        /// The production sidebar reservation finds this exact native split:
        /// it is the only split whose delegate is an `NSSplitViewController`
        /// with sidebar and detail items. Do not use the first nested split —
        /// `WorkspaceDetailSplitView` has its own unrelated terminal/panel
        /// split.
        func nativeSidebar() -> (split: NSSplitView, controller: NSSplitViewController, sidebar: NSSplitViewItem) {
            func splitViews(in view: NSView) -> [NSSplitView] {
                ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews(in:))
            }
            let candidates = splitViews(in: toolbar.contentView!)
            guard let split = candidates.first(where: {
                guard let controller = $0.delegate as? NSSplitViewController else { return false }
                return $0.isVertical && controller.splitViewItems.count >= 2
            }), let controller = split.delegate as? NSSplitViewController else {
                let descriptions = candidates.map { "vertical=\($0.isVertical),subviews=\($0.subviews.count),delegate=\(String(describing: type(of: $0.delegate)))" }.joined(separator: ";")
                preconditionFailure("the fixture has no native sidebar split; candidates: \(descriptions)")
            }
            return (split, controller, controller.splitViewItems[0])
        }
        struct SidebarGeometry: CustomStringConvertible {
            let split: ObjectIdentifier
            let controller: ObjectIdentifier
            let sidebar: ObjectIdentifier
            let column: ObjectIdentifier
            let splitBounds: NSRect
            let columnFrame: NSRect
            let itemFrame: NSRect
            let itemFrameInSplit: NSRect

            var contentWidth: CGFloat { itemFrameInSplit.width }
            var columnToContentDelta: CGFloat { columnFrame.width - itemFrameInSplit.width }
            var description: String {
                "split=\(split),controller=\(controller),sidebar=\(sidebar),column=\(column),splitBounds=\(splitBounds),columnFrame=\(columnFrame),itemFrame=\(itemFrame),itemInSplit=\(itemFrameInSplit),delta=\(columnToContentDelta)"
            }
        }
        /// The public `subviews` list also holds titlebar/shadow/divider
        /// decoration views, so it is not the logical split-item order. Walk
        /// the selected item's public ancestry to its direct child of this
        /// split instead of indexing or classifying those decorations.
        func sidebarColumn(in native: (split: NSSplitView, controller: NSSplitViewController, sidebar: NSSplitViewItem)) -> NSView {
            let itemView = native.sidebar.viewController.view
            var column = itemView
            while let parent = column.superview, parent !== native.split {
                column = parent
            }
            guard column.superview === native.split else {
                preconditionFailure("the selected sidebar item has no direct-child ancestor in its native split")
            }
            return column
        }
        /// `NSSplitView.setPosition` takes the direct child wrapper's divider
        /// coordinate. The sidebar assertion is about its actual content
        /// width, so measure both coordinate systems rather than treating them
        /// as interchangeable.
        func sidebarGeometry(_ native: (split: NSSplitView, controller: NSSplitViewController, sidebar: NSSplitViewItem)? = nil) -> SidebarGeometry {
            let native = native ?? nativeSidebar()
            let itemView = native.sidebar.viewController.view
            let column = sidebarColumn(in: native)
            return SidebarGeometry(
                split: ObjectIdentifier(native.split),
                controller: ObjectIdentifier(native.controller),
                sidebar: ObjectIdentifier(native.sidebar),
                column: ObjectIdentifier(column),
                splitBounds: native.split.bounds,
                columnFrame: column.frame,
                itemFrame: itemView.frame,
                itemFrameInSplit: itemView.convert(itemView.bounds, to: native.split)
            )
        }
        func sidebarWidth() -> CGFloat { sidebarGeometry().contentWidth }
        @discardableResult
        func resizeSidebar(_ requestedContentWidth: CGFloat) -> CGFloat {
            let native = nativeSidebar()
            let before = sidebarGeometry(native)
            // Project the requested content width through the measured
            // arranged-column/content delta. This derives the native divider
            // coordinate without assuming a particular inset.
            let requestedDividerPosition = before.columnFrame.maxX + (requestedContentWidth - before.contentWidth)
            native.split.setPosition(requestedDividerPosition, ofDividerAt: 0)
            toolbar.contentView!.superview!.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(4)
            while abs(sidebarWidth() - requestedContentWidth) >= 1 && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            let after = sidebarGeometry(native)
            check(abs(after.contentWidth - requestedContentWidth) < 1,
                  "the fixture's native sidebar requested content \(requestedContentWidth)pt via divider \(requestedDividerPosition)pt, measured \(after.contentWidth)pt; before {\(before)}; after {\(after)}; min \(native.sidebar.minimumThickness), max \(native.sidebar.maximumThickness), collapsed \(native.sidebar.isCollapsed)")
            return after.contentWidth
        }
        let previewBefore = previewFrame()
        check(previewBefore != nil, "the Preview button is in the window's toolbar")
        let session = TitleRenameSession(item: .pane(item))
        probe.session = session
        func frameView() -> NSView { toolbar.contentView!.superview! }
        spin(until: { fields(in: frameView()).count == 1 && fields(in: frameView())[0].window === toolbar }, "the field is in the window's toolbar")
        let field = fields(in: frameView())[0]
        spin(until: {
            guard let item = renameItem() else { return false }
            return item.minSize.width == TitleRenameToolbar.minimumWidth && item.maxSize.width == TitleRenameToolbar.idealWidth
        }, "the native title item has the 120...280pt range after SwiftUI layout")

        // Seam regression, not synthetic OS dispatch: `windowDidResize` is
        // the production observer entry point. B deliberately has no room of
        // its own, so only the rehosted coordinator can repair its item.
        let oldWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        oldWindow.isReleasedWhenClosed = false
        let rehostProbe = ToolbarProbe()
        let rehostWindow = window(ToolbarRoot(probe: rehostProbe, sidebarState: WorkspaceSidebarState(initialVisibility: .all), appliesToolbarRoom: false), width: 1000)
        spin(until: { rehostWindow.toolbar != nil && rehostWindow.title == "pane title" }, "isolated B has its own toolbar without an independent room writer")
        rehostProbe.session = TitleRenameSession(item: .pane(item))
        func rehostFrameView() -> NSView { rehostWindow.contentView!.superview! }
        spin(until: { fields(in: rehostFrameView()).count == 1 && fields(in: rehostFrameView())[0].window === rehostWindow }, "isolated B has an attached title field")
        let rehostedItem = rehostWindow.toolbar!.items.first { $0.itemIdentifier.rawValue == TitleRenameToolbar.itemID }!
        let rehostCoordinator = TitleRenameToolbarRoom.Coordinator()
        let rehostAnchor = TitleRenameToolbarRoom.AnchorView(frame: .zero)
        rehostAnchor.coordinator = rehostCoordinator
        func rehostDiagnostics() -> String {
            let member = rehostWindow.toolbar?.items.contains { $0 === rehostedItem } == true
            let itemWindow = rehostedItem.view?.window === rehostWindow ? "B" : rehostedItem.view?.window == nil ? "nil" : "other"
            return "member=\(member),itemWindow=\(itemWindow),min=\(rehostedItem.minSize.width),max=\(rehostedItem.maxSize.width),anchorWindow=\(rehostAnchor.window === rehostWindow ? "B" : rehostAnchor.window === oldWindow ? "A" : "other"),generation=\(rehostCoordinator.generation)"
        }
        check(rehostedItem.view?.window === rehostWindow, "isolated B's target item is attached before the rehost seam; \(rehostDiagnostics())")
        oldWindow.contentView!.addSubview(rehostAnchor)
        rehostCoordinator.update(active: true, anchor: rehostAnchor)
        // 200pt is an attached in-range sentinel at B's wide width, unlike an
        // overflow-sized 777pt item whose view may be detached before apply.
        rehostedItem.minSize.width = 200
        rehostedItem.maxSize.width = 200
        let beforeRehost = rehostDiagnostics()
        rehostWindow.contentView!.superview!.layoutSubtreeIfNeeded()
        rehostWindow.contentView!.addSubview(rehostAnchor)
        spin(until: { rehostAnchor.window === rehostWindow }, "the production room anchor rehosts from old A into isolated B")
        check(rehostedItem.view?.window === rehostWindow && rehostWindow.toolbar!.items.contains { $0 === rehostedItem },
              "isolated B's target remains attached after rehost; before {\(beforeRehost)} after {\(rehostDiagnostics())}")
        rehostCoordinator.windowDidResize(oldWindow)
        let deadline = Date().addingTimeInterval(4)
        while !(rehostedItem.minSize.width == 120 && rehostedItem.maxSize.width == 280) && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        check(rehostedItem.minSize.width == 120 && rehostedItem.maxSize.width == 280,
              "an old A resize callback cannot cancel isolated B's 120...280pt update; before {\(beforeRehost)} after {\(rehostDiagnostics())}")
        rehostCoordinator.stopObserving()
        rehostAnchor.removeFromSuperview()
        oldWindow.close()
        rehostWindow.close()

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
        check(fieldFrame.width == TitleRenameToolbar.idealWidth, "at 1000pt the actual native field remains 280pt wide")

        // Exercise the real split at both supported sidebar widths, then make
        // the window narrow enough that the native toolbar must use the
        // item's range rather than put it straight into its overflow menu.
        spin(until: {
            let sidebar = nativeSidebar().sidebar
            return sidebar.minimumThickness == WorkspaceSidebarMetrics.minimum && sidebar.maximumThickness == WorkspaceSidebarMetrics.maximum
        }, "the production sidebar reservation owns the native sidebar split")
        _ = resizeSidebar(280)
        toolbar.setContentSize(NSSize(width: 1000, height: 500))
        spin(until: { renameItem()?.minSize.width == 120 && renameItem()?.maxSize.width == 280 }, "a 280pt sidebar leaves the native range installed")
        spin(until: { fields(in: frameView()).first.map { $0.convert($0.bounds, to: nil).width == 280 } == true }, "a 280pt sidebar starts with an actual 280pt field")
        toolbar.setContentSize(NSSize(width: 620, height: 500))
        spin(until: { fields(in: frameView()).first?.window === toolbar }, "the field stays attached while a 280pt sidebar narrows")
        let narrow280Frame = fields(in: frameView())[0].convert(fields(in: frameView())[0].bounds, to: nil)
        check(narrow280Frame.width >= TitleRenameToolbar.minimumWidth && narrow280Frame.width < TitleRenameToolbar.idealWidth,
              "the actual field with a 280pt sidebar shrinks within 120...280pt before toolbar overflow")
        toolbar.setContentSize(NSSize(width: 1000, height: 500))
        spin(until: { fields(in: frameView()).first.map { $0.convert($0.bounds, to: nil).width == 280 } == true }, "the field expands back to 280pt after the 280pt-sidebar narrow path")
        _ = resizeSidebar(360)
        toolbar.setContentSize(NSSize(width: 700, height: 500))
        spin(until: { fields(in: frameView()).first?.window === toolbar }, "the field stays in the toolbar after width shrinks")
        let narrowFrame = fields(in: frameView())[0].convert(fields(in: frameView())[0].bounds, to: nil)
        check(narrowFrame.width >= TitleRenameToolbar.minimumWidth && narrowFrame.width < TitleRenameToolbar.idealWidth,
              "the actual native field shrinks within 120...280pt before toolbar overflow")
        toolbar.setContentSize(NSSize(width: 1000, height: 500))
        spin(until: { fields(in: frameView()).first.map { $0.convert($0.bounds, to: nil).width == 280 } == true }, "the actual native field expands back to 280pt")
        probe.refresh += 1
        spin(until: { renameItem()?.minSize.width == 120 && renameItem()?.maxSize.width == 280 }, "a SwiftUI layout rebuild retains the native range")

        let text = toolbar.firstResponder as! NSTextView
        check(text.string == "build" && text.selectedRange() == NSRange(location: 0, length: 5), "starting from the name, selected")
        text.insertText("server", replacementRange: NSRange(location: NSNotFound, length: 0))
        text.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let coordinator = field.delegate as! TitleRenameField.Coordinator
        check(!coordinator.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return remains with a synthetic input-method composition")
        text.insertText("한", replacementRange: text.markedRange())
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check(probe.endings.count == 1 && probe.endings[0].0 == .submit && probe.endings[0].1 == "server한", "Return in the toolbar sends the committed input-method text")
        spin(until: { fields(in: frameView()).isEmpty && toolbar.titleVisibility == .visible && renameItem() == nil }, "the field, its toolbar item, and its state go away")
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

        // A second window has its sidebar hidden. Drive its actual field from
        // wide to narrow before using it for window isolation below.
        let narrowProbe = ToolbarProbe()
        let hiddenSidebar = WorkspaceSidebarState(initialVisibility: .detailOnly)
        let narrow = window(ToolbarRoot(probe: narrowProbe, sidebarState: hiddenSidebar), width: 1000)
        spin(until: { narrow.toolbar != nil && narrow.title == "pane title" }, "the hidden-sidebar fixture has its own toolbar")
        narrowProbe.session = TitleRenameSession(item: .pane(item))
        func narrowFrameView() -> NSView { narrow.contentView!.superview! }
        spin(until: { fields(in: narrowFrameView()).count == 1 && fields(in: narrowFrameView())[0].window === narrow }, "the hidden-sidebar field is in its own toolbar")
        let narrowField = fields(in: narrowFrameView())[0]
        spin(until: {
            narrow.toolbar?.items.first { $0.itemIdentifier.rawValue == TitleRenameToolbar.itemID }.map {
                $0.minSize.width == 120 && $0.maxSize.width == 280
            } == true
        }, "the hidden-sidebar window gets the native range")
        check(narrowField.convert(narrowField.bounds, to: nil).width == 280, "a hidden sidebar starts with an actual 280pt field")
        narrow.setContentSize(NSSize(width: 450, height: 500))
        spin(until: { fields(in: narrowFrameView()).first?.window === narrow }, "the hidden-sidebar field stays attached while narrowing")
        let hiddenNarrowFrame = fields(in: narrowFrameView())[0].convert(fields(in: narrowFrameView())[0].bounds, to: nil)
        check(hiddenNarrowFrame.width >= TitleRenameToolbar.minimumWidth && hiddenNarrowFrame.width < TitleRenameToolbar.idealWidth,
              "the actual field with the sidebar hidden shrinks within 120...280pt before toolbar overflow")
        check((narrow.firstResponder as? NSTextView)?.delegate === narrowField && (narrow.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 5),
              "a hidden-sidebar rename retains native focus and selection while narrowing")

        probe.session = TitleRenameSession(item: .pane(item))
        spin(until: { fields(in: frameView()).count == 1 }, "the first window can rebuild its title item")
        let narrowItem = narrow.toolbar!.items.first { $0.itemIdentifier.rawValue == TitleRenameToolbar.itemID }!
        narrowItem.minSize.width = 777
        narrowItem.maxSize.width = 777
        toolbar.setContentSize(NSSize(width: 980, height: 500))
        spin(until: { renameItem()?.minSize.width == 120 && renameItem()?.maxSize.width == 280 }, "a resize repairs the first window's rebuilt item")
        check(narrowItem.minSize.width == 777 && narrowItem.maxSize.width == 777, "the first window never changes another window's toolbar item")
        (toolbar.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        (narrow.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        spin(until: { fields(in: frameView()).isEmpty && fields(in: narrowFrameView()).isEmpty }, "both independent rename states clean up")

        // Keep the separate start-narrow case: no wide field is required for
        // this window before the rename begins.
        let startNarrowProbe = ToolbarProbe()
        let startNarrow = window(ToolbarRoot(probe: startNarrowProbe, sidebarState: WorkspaceSidebarState(initialVisibility: .detailOnly)), width: 450)
        spin(until: { startNarrow.toolbar != nil }, "the start-narrow hidden-sidebar fixture has a toolbar")
        startNarrowProbe.session = TitleRenameSession(item: .pane(item))
        func startNarrowFrameView() -> NSView { startNarrow.contentView!.superview! }
        spin(until: { fields(in: startNarrowFrameView()).count == 1 && fields(in: startNarrowFrameView())[0].window === startNarrow }, "a rename starting narrow stays in its hidden-sidebar toolbar")
        let startNarrowField = fields(in: startNarrowFrameView())[0]
        let startNarrowFrame = startNarrowField.convert(startNarrowField.bounds, to: nil)
        check(startNarrowFrame.width >= TitleRenameToolbar.minimumWidth && startNarrowFrame.width < TitleRenameToolbar.idealWidth,
              "a hidden-sidebar rename that starts narrow has actual 120...280pt geometry")
        func startNarrowFocusMetadata() -> String {
            let editor = startNarrow.firstResponder as? NSTextView
            let responder = startNarrow.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let delegate = editor?.delegate.map { String(describing: type(of: $0)) } ?? "nil"
            let range = editor.map { String(describing: $0.selectedRange()) } ?? "nil"
            let ended = startNarrowProbe.session.map { String($0.isEnded) } ?? "nil"
            return "firstResponder=\(responder),editorDelegate=\(delegate),selectedRange=\(range),sessionEnded=\(ended)"
        }
        spin(until: {
            (startNarrow.firstResponder as? NSTextView)?.delegate === startNarrowField && (startNarrow.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: 0, length: 5)
        }, "a start-narrow rename retains native focus and selection; \(startNarrowFocusMetadata())")
        (startNarrow.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        spin(until: { fields(in: startNarrowFrameView()).isEmpty }, "the start-narrow rename cleans up")

        check(!toolbar.isVisible && !narrow.isVisible && !startNarrow.isVisible, "none of the toolbar fixtures showed a window")
        startNarrow.close()
        narrow.close()
        toolbar.close()

        print("PASS \(checks) title rename window title/terminal title precedence/preview/title removal/toolbar width/layout/two-window isolation/title double-click checks; owned never-shown windows, no app or herdr")
    }
}
