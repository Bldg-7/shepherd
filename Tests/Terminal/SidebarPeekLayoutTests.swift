import SwiftUI
import AppKit
import SwiftTerm
import Observation
import Darwin

@MainActor @Observable final class SidebarProbe {
    @ObservationIgnored var terminal: TerminalView?
    @ObservationIgnored var creations = 0
    @ObservationIgnored var sizes: [(Int, Int)] = []
    @ObservationIgnored let ownedPTY: Int32
    @ObservationIgnored let sidebarState: WorkspaceSidebarState
    init(ownedPTY: Int32, startsHidden: Bool, restoredHidden: Bool) {
        self.ownedPTY = ownedPTY
        sidebarState = WorkspaceSidebarState(initialVisibility: startsHidden && !restoredHidden ? .detailOnly : .automatic)
    }
}
private struct TerminalDetail: View {
    let probe: SidebarProbe
    let legacy: Bool
    var body: some View {
        // Exactly the native hosting boundary present in ContentView.
        if legacy {
            HSplitView { terminal.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity) }
        } else {
            WorkspaceDetailSplitView(showsPanel: false, panelMinimum: 320, panelIdeal: 560) {
                terminal.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(WorkspaceSidebarDetailLayout())
            } panel: { EmptyView() }
        }
    }
    private var terminal: some View {
        TerminalPaneFrame(isFocused: false) {
            TerminalHostView(onCreate: { probe.terminal = $0; probe.creations += 1 },
                onInput: { _ in }, onResize: { cols, rows in
                    probe.sizes.append((cols, rows))
                    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
                    precondition(ioctl(probe.ownedPTY, TIOCSWINSZ, &size) == 0)
                })
        }
    }
}
private struct Fixture: View {
    let probe: SidebarProbe
    let visibility: NavigationSplitViewVisibility
    let legacy: Bool
    var sidebar: some View { Color.gray.navigationSplitViewColumnWidth(min: WorkspaceSidebarMetrics.minimum, ideal: WorkspaceSidebarMetrics.preferred, max: WorkspaceSidebarMetrics.maximum) }
    var body: some View {
        WorkspaceNavigationSplitView(sidebarState: probe.sidebarState) { sidebar } detail: {
            TerminalDetail(probe: probe, legacy: legacy)
        }
    }
}
@main @MainActor enum SidebarPeekLayoutTests {
    static var checks = 0
    static func check(_ v: Bool, _ message: String) { precondition(v, message); checks += 1 }
    static func settle(_ host: NSView, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            if condition() { return true }
        } while Date() < deadline
        return false
    }
    static func split(in view: NSView) -> NSSplitViewController? {
        if let v = view as? NSSplitView, let c = v.delegate as? NSSplitViewController { return c }
        return view.subviews.lazy.compactMap { split(in: $0) }.first
    }
    static func detailSplitChecks() {
        let controller = WorkspaceDetailSplitView<SwiftUI.Color, SwiftUI.Color>.Controller(terminal: .black, panel: .gray, environment: EnvironmentValues())
        let split = controller.nativeSplit
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        controller.viewDidLayout()
        let terminal = controller.terminalHost.view
        check(controller.terminalHost.safeAreaRegions.isEmpty && controller.panelHost.safeAreaRegions.isEmpty, "native hosts must not reapply inherited sidebar/titlebar safe areas")
        controller.showPanel(false)
        controller.viewDidLayout()
        check(terminal.frame == split.bounds && split.arrangedSubviews.count == 1, "no panel fills the proposed detail rectangle")
        controller.showPanel(true)
        controller.viewDidLayout()
        check(split.arrangedSubviews.count == 2 && terminal.frame.minX == 0, "panel adds only the second native pane")
        split.setPosition(620, ofDividerAt: 0)
        check(abs(terminal.frame.width - 620) < 1, "public native divider still resizes panes")
        let ratio = terminal.frame.width / (split.bounds.width - split.dividerThickness)
        controller.view.frame.size.width = 1500
        controller.viewDidLayout()
        check(abs(terminal.frame.width / (split.bounds.width - split.dividerThickness) - ratio) < 0.01, "window resize preserves user divider proportion")
        check(controller.splitView(split, constrainMinCoordinate: 0, ofSubviewAt: 0) == 320, "terminal drag minimum remains320")
        check(controller.splitView(split, constrainMaxCoordinate: 2000, ofSubviewAt: 0) == 1500 - split.dividerThickness - 320, "panel drag minimum remains320")
        controller.showPanel(false)
        controller.viewDidLayout()
        check(controller.terminalHost.view === terminal && terminal.frame == split.bounds, "panel close retains terminal host and fills viewport")
        controller.showPanel(true)
        controller.viewDidLayout()
        check(controller.terminalHost.view === terminal && abs(terminal.frame.width / (split.bounds.width - split.dividerThickness) - ratio) < 0.01, "panel reopen retains terminal and divider proportion")
    }
    static func initialStateChecks() {
        let automatic = WorkspaceSidebarState()
        automatic.reconcileInitialNativeSidebar(isCollapsed: false)
        check(automatic.isPinned && automatic.awaitsInitialNativeCollapse, "automatic expanded startup retains normal pinned layout while restoration is pending")
        automatic.reconcileInitialNativeSidebar(isCollapsed: true)
        check(!automatic.isPinned && !automatic.awaitsInitialNativeCollapse && automatic.columnVisibility == .automatic, "initial native collapse unpins without writing native visibility")
        automatic.columnVisibility = .all
        automatic.reconcileInitialNativeSidebar(isCollapsed: false)
        check(!automatic.isPinned, "first native hover does not pin restored hidden sidebar")
        automatic.togglePin()
        automatic.reconcileInitialNativeSidebar(isCollapsed: true)
        check(automatic.isPinned && automatic.columnVisibility == .all, "late bootstrap callback cannot override explicit pin choice")
        automatic.togglePin()
        check(!automatic.isPinned && automatic.columnVisibility == .detailOnly, "explicit unpin remains authoritative")
        let earlyChoice = WorkspaceSidebarState()
        earlyChoice.togglePin(); earlyChoice.togglePin()
        earlyChoice.reconcileInitialNativeSidebar(isCollapsed: true)
        check(earlyChoice.isPinned, "explicit choice before restoration observation wins")
        let explicit = WorkspaceSidebarState(initialVisibility: .all)
        explicit.reconcileInitialNativeSidebar(isCollapsed: true)
        check(explicit.isPinned && !explicit.awaitsInitialNativeCollapse, "explicit initial visibility is not automatic restoration")
    }
    static func collapseStateChecks() {
        var nativeCollapsed = true
        let state = WorkspaceSidebarState(initialVisibility: .detailOnly)
        state.nativeSidebarCollapsed = { nativeCollapsed }
        state.togglePin()
        let openRevision = state.pinRevision
        state.reconcileNativeSidebar(isCollapsed: true, revision: openRevision)
        check(state.isPinned, "initial collapsed callback cannot cancel pending explicit open")
        nativeCollapsed = false
        state.reconcileNativeSidebar(isCollapsed: false, revision: openRevision)
        nativeCollapsed = true
        state.reconcileNativeSidebar(isCollapsed: true, revision: openRevision)
        check(!state.isPinned && state.columnVisibility == .detailOnly, "user divider collapse releases pin and closes declarative visibility")
        state.togglePin()
        check(state.isPinned && state.columnVisibility == .all, "one press after native collapse opens, not a redundant hide")
        state.reconcileNativeSidebar(isCollapsed: true, revision: openRevision)
        check(state.isPinned, "late collapse from old command cannot undo new pin")
        nativeCollapsed = false
        state.reconcileNativeSidebar(isCollapsed: false, revision: state.pinRevision)
        nativeCollapsed = true // KVO close is queued, user presses first
        state.togglePin()
        check(state.isPinned && state.columnVisibility == .all, "live collapsed item makes immediate next press open even before queued reconciliation")
        nativeCollapsed = false
        state.reconcileNativeSidebar(isCollapsed: false, revision: state.pinRevision)
        state.togglePin()
        state.reconcileNativeSidebar(isCollapsed: true, revision: state.pinRevision)
        check(!state.isPinned, "explicit hide + native close remains hidden")
        state.columnVisibility = .all
        state.reconcileNativeSidebar(isCollapsed: false, revision: state.pinRevision)
        check(!state.isPinned, "hover after dragged close must not pin")
        nativeCollapsed = false
        state.togglePin() // native drawer already revealed by hover
        nativeCollapsed = true
        state.reconcileNativeSidebar(isCollapsed: true, revision: state.pinRevision)
        check(!state.isPinned, "pinning an already revealed hover drawer must not wait for a nonexistent expansion event before later drag-close")
    }

    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let legacy = CommandLine.arguments.contains("--legacy")
        if !legacy { detailSplitChecks(); initialStateChecks(); collapseStateChecks() }
        var measurements: [[String: Double]] = []
        let restorationRed = CommandLine.arguments.contains("--restoration-red")
        for mode in restorationRed ? [2] : [0, 1, 2] {
            let startsHidden = mode != 0, restoredHidden = mode == 2
            var master: Int32 = -1, slave: Int32 = -1
            precondition(openpty(&master, &slave, nil, nil, nil) == 0)
            defer { close(master); close(slave) }
            _ = fcntl(master, F_SETFD, FD_CLOEXEC); _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
            let probe = SidebarProbe(ownedPTY: slave, startsHidden: startsHidden, restoredHidden: restoredHidden)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; defer { window.close() }
            let host = NSHostingController(rootView: Fixture(probe: probe, visibility: startsHidden ? .detailOnly : .automatic, legacy: legacy))
            host.sizingOptions = []; window.contentViewController = host; window.setContentSize(NSSize(width: 1200, height: 700))
            check(settle(host.view) { probe.terminal != nil && split(in: host.view) != nil }, "native NavigationSplitView and terminal must mount")
            let controller = split(in: host.view)!, sidebar = controller.splitViewItems.first!, detail = controller.splitViewItems.last!
            let terminal = probe.terminal!
            if !restorationRed {
                let sizingApplied = settle(host.view) { sidebar.minimumThickness == WorkspaceSidebarMetrics.minimum && sidebar.maximumThickness == WorkspaceSidebarMetrics.maximum && sidebar.automaticMaximumThickness == WorkspaceSidebarMetrics.preferred }
                if !sizingApplied { print("SIZING DIAGNOSTIC", sidebar.minimumThickness, sidebar.maximumThickness, sidebar.preferredThicknessFraction, sidebar.automaticMaximumThickness); fflush(stdout) }
                check(sizingApplied, "native fullscreen sidebar must use the wider280/360/480pt sizing policy")
            }
            if restoredHidden {
                // Public AppKit initial native collapse, with automatic SwiftUI
                // visibility. Do NOT call togglePin/the toolbar before hover.
                sidebar.isCollapsed = true
                check(settle(host.view) { sidebar.isCollapsed && !probe.sidebarState.isPinned && !probe.sidebarState.awaitsInitialNativeCollapse }, "restored native collapse must unpin before first hover without toolbar toggles")
            } else if !sidebar.isCollapsed { probe.sidebarState.togglePin() }
            check(settle(host.view) { sidebar.isCollapsed && abs(terminal.bounds.width - 1186) < 1 }, "native initial hide must retain terminal and fill viewport")
            for size in [NSSize(width: 1200, height: 700), NSSize(width: 900, height: 600)] {
                window.setContentSize(size)
                check(settle(host.view) { abs(terminal.bounds.width - size.width + 14) < 1 }, "hidden terminal must fill detail minus only 7pt gutters")
                // Native toggleSidebar animates and reports its final grid on
                // a later run-loop turn. Drain that transition before measuring
                // peek itself; don't count the preceding explicit toggle as peek.
                for _ in 0..<60 { host.view.layoutSubtreeIfNeeded(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
                let before = terminal.convert(terminal.bounds, to: host.view), grid = (terminal.getTerminal().cols, terminal.getTerminal().rows), resizeCount = probe.sizes.count
                // Reproduce the actual fullscreen hover path: native reveal
                // changes visibility to .all, without an explicit pin action.
                // The original safe-area-only simulation missed this transition.
                controller.toggleSidebar(nil)
                let revealed = settle(host.view) { !sidebar.isCollapsed && probe.sidebarState.columnVisibility == .all && detail.viewController.view.safeAreaInsets.left > 0 }
                if !revealed { print("REVEAL DIAGNOSTIC", "collapsed", sidebar.isCollapsed, "visibility", probe.sidebarState.columnVisibility, "safe", detail.viewController.view.safeAreaInsets, "frame", detail.viewController.view.frame); fflush(stdout) }
                check(revealed, "native reveal must actually change visibility to all and apply sidebar inset")
                let wide = settle(host.view) { sidebar.viewController.view.bounds.width >= WorkspaceSidebarMetrics.preferred }
                if !wide {
                    print("ACTUAL WIDTH DIAGNOSTIC", "split", controller.splitView.frame, controller.splitView.bounds, "arranged", controller.splitView.arrangedSubviews.map(\.frame), "sidebar", sidebar.viewController.view.frame, sidebar.viewController.view.bounds, "preferred", sidebar.viewController.preferredContentSize, "constraints", sidebar.viewController.view.constraints, "splitConstraints", controller.splitView.constraints)
                    fflush(stdout)
                }
                check(wide, "actual revealed sidebar width must not remain a cached half-minimum drawer")
                let revealedWidth = sidebar.viewController.view.bounds.width
                check(!probe.sidebarState.isPinned, "native hover visibility change must not confer pin intent")
                for _ in 0..<25 { host.view.layoutSubtreeIfNeeded(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
                check(terminal.convert(terminal.bounds, to: host.view) == before, "hover preview must overlay, not steal terminal width")
                check(probe.terminal === terminal && probe.creations == 1, "peek must not recreate terminal/session")
                check(terminal.getTerminal().cols == grid.0 && terminal.getTerminal().rows == grid.1 && probe.sizes.count == resizeCount, "peek must not resize terminal/PTY")
                var kernel = winsize(); check(ioctl(slave, TIOCGWINSZ, &kernel) == 0 && Int(kernel.ws_col) == grid.0 && Int(kernel.ws_row) == grid.1, "kernel PTY grid remains stable during peek")
                // Pin even while the hover drawer is already visible/.all.
                probe.sidebarState.togglePin()
                check(settle(host.view) { !sidebar.isCollapsed && abs(terminal.convert(terminal.bounds, to: host.view).minX - detail.viewController.view.safeAreaInsets.left - 7) < 1 && detail.viewController.view.safeAreaInsets.left > 0 && terminal.bounds.width < before.width }, "explicit toggle must still dock sidebar and shrink detail normally")
                let pinned = terminal.convert(terminal.bounds, to: host.view)
                check(abs(pinned.width - (size.width - pinned.minX - 7)) < 2, "pinned sidebar keeps its normal native leading inset")
                check(probe.terminal === terminal && probe.creations == 1, "toggle must not recreate terminal/session")
                // Shrink the actual native sidebar before closing it via
                // public item collapse (the same KVO transition as drag-close).
                controller.splitView.setPosition(WorkspaceSidebarMetrics.minimum, ofDividerAt: 0)
                sidebar.isCollapsed = true
                check(settle(host.view) { sidebar.isCollapsed && !probe.sidebarState.isPinned && probe.sidebarState.columnVisibility == .detailOnly }, "native divider collapse after explicit pin must release pin intent")
                probe.sidebarState.togglePin()
                check(settle(host.view) { !sidebar.isCollapsed && probe.sidebarState.isPinned }, "single toggle after divider collapse must reopen sidebar")
                measurements.append(["startsHidden": startsHidden ? 1 : 0, "restoredHiddenWithoutToolbar": restoredHidden ? 1 : 0, "width": size.width, "peekWidth": before.width, "peekX": before.minX, "pinnedWidth": pinned.width, "pinnedX": pinned.minX, "actualSidebarWidth": sidebar.viewController.view.bounds.width, "revealedSidebarWidth": revealedWidth])
                probe.sidebarState.togglePin()
                check(settle(host.view) { sidebar.isCollapsed && abs(terminal.bounds.width - size.width + 14) < 1 }, "toggle hides pinned sidebar normally")
                let hideFrame = terminal.convert(terminal.bounds, to: host.view)
                for _ in 0..<60 { host.view.layoutSubtreeIfNeeded(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
                let hideCount = probe.sizes.count
                controller.toggleSidebar(nil)
                check(settle(host.view) { probe.sidebarState.columnVisibility == .all }, "repeated hover reveals through native visibility")
                for _ in 0..<35 { host.view.layoutSubtreeIfNeeded(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
                controller.toggleSidebar(nil)
                check(settle(host.view) { sidebar.isCollapsed && probe.sidebarState.columnVisibility == .detailOnly }, "native hover dismissal restores detailOnly")
                for _ in 0..<35 { host.view.layoutSubtreeIfNeeded(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
                check(terminal.convert(terminal.bounds, to: host.view) == hideFrame && probe.sizes.count == hideCount, "closing repeated peek must not shift or resize terminal")
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS \(checks) actual native NavigationSplitView/native visibility reveal/pin intent/SwiftTerm/owned-kernel-PTY layout checks; no real fullscreen/hover/user GUI/SSH")
    }
}
