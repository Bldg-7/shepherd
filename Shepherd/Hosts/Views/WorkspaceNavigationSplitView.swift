import SwiftUI
#if os(macOS)
import Observation
import AppKit

enum WorkspaceSidebarMetrics {
    static let minimum: CGFloat = 280
    static let preferred: CGFloat = 360
    static let maximum: CGFloat = 480
}

/// The main window's smallest content (SHPHRD-141): the detail's own
/// minimum, beside the sidebar's while that is pinned and open, and never
/// under 400 × 400. The native sidebar divider lies over the detail's
/// leading edge, so it takes nothing from the detail. A hover drawer
/// overlays the detail and reserves nothing.
enum WorkspaceWindowMetrics {
    /// The narrowest width at which the toolbar, rename field included,
    /// fits without overflowing.
    static let minimumWidth: CGFloat = 480
    static let minimumHeight: CGFloat = 400

    static func minimumWidth(detail: CGFloat, reservesSidebar: Bool) -> CGFloat {
        max(minimumWidth, detail + (reservesSidebar ? WorkspaceSidebarMetrics.minimum : 0))
    }
}

/// Native expansion includes hover and never confers pin intent. Native
/// collapse (including a divider drag) releases it; only the button pins.
@MainActor @Observable final class WorkspaceSidebarState {
    var columnVisibility: NavigationSplitViewVisibility
    private(set) var isPinned: Bool
    /// .automatic is a request for native restoration, not proof that the
    /// restored sidebar is pinned. Track an initial native collapse until a
    /// collapse is seen or the person makes an explicit pin choice.
    private(set) var awaitsInitialNativeCollapse: Bool
    /// Whether AppKit last reported the sidebar open. Until it reports, a
    /// restored hidden sidebar must not widen the window's minimum.
    private(set) var nativeSidebarIsOpen = false
    @ObservationIgnored private(set) var pinRevision = 0
    @ObservationIgnored var nativeSidebarCollapsed: (() -> Bool?)?
    @ObservationIgnored private var awaitingNativeOpen: Bool

    init(initialVisibility: NavigationSplitViewVisibility = .automatic) {
        columnVisibility = initialVisibility
        isPinned = initialVisibility != .detailOnly
        awaitsInitialNativeCollapse = initialVisibility == .automatic
        awaitingNativeOpen = initialVisibility != .automatic && initialVisibility != .detailOnly
    }

    func reconcileInitialNativeSidebar(isCollapsed: Bool) {
        guard awaitsInitialNativeCollapse, isCollapsed else { return }
        awaitsInitialNativeCollapse = false
        isPinned = false
        // Leave native visibility alone: revealing/dismissing the drawer
        // belongs to AppKit, and restoring it must not trigger another toggle.
    }

    /// Pin intent with AppKit's sidebar actually open: what the window's
    /// minimum width keeps room for.
    var reservesWidth: Bool { isPinned && nativeSidebarIsOpen }

    /// Outside native layout only: this is observed UI state.
    func noteNativeSidebar(isCollapsed: Bool) {
        if nativeSidebarIsOpen == isCollapsed { nativeSidebarIsOpen = !isCollapsed }
    }

    func reconcileNativeSidebar(isCollapsed: Bool, revision: Int) {
        guard revision == pinRevision else { return }
        if !isCollapsed {
            awaitingNativeOpen = false
            return // also hover: never infer pin intent from expansion
        }
        guard !awaitingNativeOpen else { return }
        if awaitsInitialNativeCollapse {
            reconcileInitialNativeSidebar(isCollapsed: true)
        } else if isPinned {
            // Native user drag/close is authoritative. Keep declarative
            // visibility closed too, rather than re-opening it on this update.
            isPinned = false
            columnVisibility = .detailOnly
        }
    }

    func togglePin() {
        // A drag can close AppKit before its queued KVO/SwiftUI update reaches
        // us. Read the live item so the very next press opens in one click.
        let nativeCollapsed = nativeSidebarCollapsed?()
        if nativeCollapsed == true, !awaitingNativeOpen { isPinned = false }
        awaitsInitialNativeCollapse = false
        pinRevision &+= 1
        isPinned.toggle()
        // Pinning an already revealed hover drawer has no new native
        // expansion event to acknowledge. Don't wait for one that won't come.
        awaitingNativeOpen = isPinned && nativeCollapsed != false
        columnVisibility = isPinned ? .all : .detailOnly
    }
}

/// Observe native collapse for the whole window lifetime, not only startup.
/// The always-present detail still exists when the sidebar was dragged closed.
private struct WorkspaceNativeSidebarVisibility: NSViewRepresentable {
    let state: WorkspaceSidebarState

    func makeNSView(context: Context) -> ObserverView { ObserverView(state: state) }
    func updateNSView(_ view: ObserverView, context: Context) { view.state = state; view.scheduleObservation() }

    final class ObserverView: NSView {
        var state: WorkspaceSidebarState
        private weak var observedItem: NSSplitViewItem?
        private var observation: NSKeyValueObservation?
        private var scheduled = false
        private var minimumWidthConstraint: NSLayoutConstraint?

        init(state: WorkspaceSidebarState) {
            self.state = state
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        isolated deinit { minimumWidthConstraint?.isActive = false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleObservation() }
        override func layout() { super.layout(); scheduleObservation() }

        func scheduleObservation() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.window != nil else {
                    self.observation = nil
                    self.observedItem = nil
                    self.minimumWidthConstraint?.isActive = false
                    self.minimumWidthConstraint = nil
                    return
                }
                var ancestor = self.superview
                while let view = ancestor {
                    if let split = view as? NSSplitView,
                       let controller = split.delegate as? NSSplitViewController,
                       controller.splitViewItems.count >= 2,
                       let detail = controller.splitViewItems.last,
                       self.isDescendant(of: detail.viewController.view),
                       let sidebar = controller.splitViewItems.first {
                        if self.observedItem !== sidebar {
                            self.observedItem = sidebar
                            self.minimumWidthConstraint?.isActive = false
                            let constraint = sidebar.viewController.view.widthAnchor.constraint(greaterThanOrEqualToConstant: self.state.isPinned ? WorkspaceSidebarMetrics.minimum : WorkspaceSidebarMetrics.preferred)
                            constraint.priority = .defaultHigh
                            constraint.isActive = true
                            self.minimumWidthConstraint = constraint
                            // AppKit's standard sidebar fraction can shrink the
                            // fullscreen drawer. Automatic sizing prefers360pt;
                            // explicit user resizing still permits280...480pt.
                            sidebar.minimumThickness = WorkspaceSidebarMetrics.minimum
                            sidebar.maximumThickness = WorkspaceSidebarMetrics.maximum
                            sidebar.preferredThicknessFraction = 0.5
                            sidebar.automaticMaximumThickness = WorkspaceSidebarMetrics.preferred
                            self.state.nativeSidebarCollapsed = { [weak sidebar] in sidebar?.isCollapsed }
                            self.observation = sidebar.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
                                MainActor.assumeIsolated {
                                    guard let self, let item = self.observedItem else { return }
                                    let collapsed = item.isCollapsed, revision = self.state.pinRevision
                                    // A rapid drag can close it again before the
                                    // queued expansion callback runs. Record the
                                    // open acknowledgment synchronously (only
                                    // ignored command metadata, never UI state).
                                    if !collapsed { self.state.reconcileNativeSidebar(isCollapsed: false, revision: revision) }
                                    // Don't mutate SwiftUI during native layout.
                                    // Ignore stale commands and obsolete events.
                                    DispatchQueue.main.async { [weak self, weak item] in
                                        guard let self, let item, self.window != nil,
                                              self.observedItem === item, item.isCollapsed == collapsed else { return }
                                        self.state.noteNativeSidebar(isCollapsed: collapsed)
                                        self.state.reconcileNativeSidebar(isCollapsed: collapsed, revision: revision)
                                        self.scheduleObservation()
                                    }
                                }
                            }
                        }
                        let minimumWidth = self.state.isPinned ? WorkspaceSidebarMetrics.minimum : WorkspaceSidebarMetrics.preferred
                        if self.minimumWidthConstraint?.constant != minimumWidth { self.minimumWidthConstraint?.constant = minimumWidth }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var workspaceSidebarIsPinned = true
}

/// HSplitView creates new native hosting boundaries. Its children must apply
/// this policy too: ignoring the outer split's safe area alone is not inherited
/// by those hosts. Read explicit pin intent, never native hover visibility.
struct WorkspaceSidebarDetailLayout: ViewModifier {
    @Environment(\.workspaceSidebarIsPinned) private var isPinned
    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: isPinned ? [] : .leading)
    }
}
#endif

/// Keep one native sidebar and stable terminal/browser view identities.
/// Hover uses AppKit's own fullscreen drawer, but cannot reserve detail width.
/// The explicit sidebar toggle still pins/unpins the ordinary native layout.
struct WorkspaceNavigationSplitView<Sidebar: View, Detail: View>: View {
    private let sidebar: Sidebar
    private let detail: Detail
    /// The detail's smallest width, which the window's minimum keeps room
    /// for; nil for no window minimum.
    private let detailMinimumWidth: CGFloat?
    #if os(macOS)
    @State private var sidebarState: WorkspaceSidebarState
    #endif

    init(initialVisibility: NavigationSplitViewVisibility = .automatic, detailMinimumWidth: CGFloat? = nil,
         @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
        self.detailMinimumWidth = detailMinimumWidth
        #if os(macOS)
        _sidebarState = State(initialValue: WorkspaceSidebarState(initialVisibility: initialVisibility))
        #endif
    }

    #if os(macOS)
    init(sidebarState: WorkspaceSidebarState, detailMinimumWidth: CGFloat? = nil,
         @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar()
        self.detail = detail()
        self.detailMinimumWidth = detailMinimumWidth
        _sidebarState = State(initialValue: sidebarState)
    }
    #endif

    var body: some View {
        @Bindable var state = sidebarState
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: WorkspaceSidebarMetrics.minimum, ideal: WorkspaceSidebarMetrics.preferred, max: WorkspaceSidebarMetrics.maximum)
                // Remove the default action from the sidebar COLUMN: putting
                // this on the outer split leaves its native toggle in place.
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(id: "workspace-sidebar-toggle", placement: .navigation) {
                        Button(action: state.togglePin) {
                            Label(state.isPinned ? LocalizedStringKey("Hide Sidebar") : LocalizedStringKey("Show Sidebar"), systemImage: "sidebar.left")
                        }
                        .help(state.isPinned ? LocalizedStringKey("Hide Sidebar") : LocalizedStringKey("Show Sidebar"))
                        .accessibilityIdentifier("workspace-sidebar-toggle")
                    }
                }
        } detail: {
            detail.ignoresSafeArea(.container, edges: state.isPinned ? [] : .leading)
                .environment(\.workspaceSidebarIsPinned, state.isPinned)
                .background { WorkspaceNativeSidebarVisibility(state: state) }
        }
        // The window takes its minimum from this (`.contentMinSize`). It
        // grows to a larger one, but a smaller one leaves it as it is.
        .frame(minWidth: detailMinimumWidth.map { WorkspaceWindowMetrics.minimumWidth(detail: $0, reservesSidebar: state.reservesWidth) },
               minHeight: detailMinimumWidth.map { _ in WorkspaceWindowMetrics.minimumHeight })
    }
}
