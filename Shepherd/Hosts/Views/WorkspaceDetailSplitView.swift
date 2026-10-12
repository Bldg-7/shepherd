#if os(macOS)
import SwiftUI
import AppKit

struct WorkspaceInheritedContent<Content: View>: View {
    let content: Content
    let values: EnvironmentValues
    var body: some View { content.environment(\.self, values) }
}

/// An ordinary native draggable split whose hosting controllers consume the
/// SwiftUI-proposed detail rectangle, not the outer sidebar's inherited inset.
/// SwiftUI's HSplitView redistributes its panes when that inset animates even
/// if its children ignore it. Keep the terminal host in place across updates.
struct WorkspaceDetailSplitView<Terminal: View, Panel: View>: NSViewControllerRepresentable {
    let showsPanel: Bool
    let panelMinimum: CGFloat
    let panelIdeal: CGFloat
    let panelCoversTerminal: Bool
    private let terminal: Terminal
    private let panel: Panel

    init(showsPanel: Bool, panelMinimum: CGFloat, panelIdeal: CGFloat, panelCoversTerminal: Bool = false,
         @ViewBuilder terminal: () -> Terminal, @ViewBuilder panel: () -> Panel) {
        self.showsPanel = showsPanel
        self.panelMinimum = panelMinimum
        self.panelIdeal = panelIdeal
        self.panelCoversTerminal = panelCoversTerminal
        self.terminal = terminal()
        self.panel = panel()
    }

    func makeNSViewController(context: Context) -> Controller {
        Controller(terminal: terminal, panel: panel, environment: context.environment)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.terminalHost.rootView = WorkspaceInheritedContent(content: terminal, values: context.environment)
        controller.panelHost.rootView = WorkspaceInheritedContent(content: panel, values: context.environment)
        controller.panelMinimum = panelMinimum
        controller.panelIdeal = panelIdeal
        controller.showPanel(showsPanel)
        controller.presentPanelAsModal(panelCoversTerminal)
    }

    final class Controller: NSViewController, NSSplitViewDelegate {
        let terminalHost: NSHostingController<WorkspaceInheritedContent<Terminal>>
        let panelHost: NSHostingController<WorkspaceInheritedContent<Panel>>
        private let split = NSSplitView()
        private let panelPlaceholder = NSView()
        private let panelSurface = NSView()
        var nativeSplit: NSSplitView { split }
        var panelSurfaceView: NSView { panelSurface }
        var panelMinimum: CGFloat = 320
        var panelIdeal: CGFloat = 560
        private var showsPanel = false
        private var fraction: CGFloat?
        private var layingOut = false
        private var panelIsModal = false
        private weak var previousResponder: NSResponder?

        init(terminal: Terminal, panel: Panel, environment: EnvironmentValues) {
            terminalHost = NSHostingController(rootView: WorkspaceInheritedContent(content: terminal, values: environment))
            panelHost = NSHostingController(rootView: WorkspaceInheritedContent(content: panel, values: environment))
            super.init(nibName: nil, bundle: nil)
            terminalHost.sizingOptions = []
            panelHost.sizingOptions = []
            // The parent already positions/sizes this representable relative
            // to the titlebar and pinned sidebar. Do not apply those twice.
            terminalHost.safeAreaRegions = []
            panelHost.safeAreaRegions = []
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            split.isVertical = true
            split.dividerStyle = .thin
            split.delegate = self
            view = NSView()
            split.autoresizingMask = [.width, .height]
            view.addSubview(split)
            addChild(terminalHost)
            addChild(panelHost)
            split.addArrangedSubview(terminalHost.view)
            // Keep one panel permanently above the split, normal side-panel
            // or modal. The placeholder reserves its normal divider slot.
            // NSSplitView's own hit testing must not choose the covered pane.
            view.addSubview(panelSurface)
            panelSurface.addSubview(panelHost.view)
            panelHost.view.autoresizingMask = [.width, .height]
            panelSurface.isHidden = true
        }

        func showPanel(_ visible: Bool) {
            _ = view
            guard visible != showsPanel else { return }
            showsPanel = visible
            if visible { split.addArrangedSubview(panelPlaceholder) }
            else { panelPlaceholder.removeFromSuperview() }
            panelSurface.isHidden = !visible
            layoutPanes()
        }

        /// The very same panel/hosting controller covers the detail region.
        /// Keep both arranged children and the terminal rectangle unchanged;
        /// no second preview reader, terminal reparent, or attach replacement.
        func presentPanelAsModal(_ requested: Bool) {
            let next = requested && showsPanel
            guard next != panelIsModal else { return }
            if next { previousResponder = split.window?.firstResponder }
            panelIsModal = next
            layoutPanes()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.split.window, self.panelIsModal == next else { return }
                if next {
                    // Respect a SwiftUI-focused control already inside the
                    // modal; otherwise remove focus from the live terminal.
                    if let focused = window.firstResponder as? NSView,
                       focused.isDescendant(of: self.panelHost.view) { return }
                    if !window.makeFirstResponder(self.panelHost.view) { window.makeFirstResponder(nil) }
                } else {
                    if let prior = self.previousResponder as? NSView,
                       prior.window === window, prior.isDescendant(of: self.terminalHost.view) {
                        window.makeFirstResponder(prior)
                    }
                    self.previousResponder = nil
                }
            }
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            split.frame = view.bounds
            layoutPanes()
        }

        private func layoutPanes() {
            guard !layingOut else { return }
            layingOut = true
            defer { layingOut = false }
            let bounds = split.bounds
            guard showsPanel else { terminalHost.view.frame = bounds; return }
            let available = max(0, bounds.width - split.dividerThickness)
            let lower = min(320, available)
            let upper = max(lower, available - min(panelMinimum, available))
            let desired = fraction.map { available * $0 } ?? available - panelIdeal
            let width = min(upper, max(lower, desired))
            terminalHost.view.frame = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
            panelPlaceholder.frame = NSRect(x: bounds.minX + width + split.dividerThickness,
                                         y: bounds.minY, width: max(0, available - width), height: bounds.height)
            panelSurface.frame = panelIsModal ? bounds : panelPlaceholder.frame
            panelHost.view.frame = panelSurface.bounds
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(320, max(0, split.bounds.width - split.dividerThickness)) }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(min(320, split.bounds.width), split.bounds.width - split.dividerThickness - panelMinimum) }
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard showsPanel, !layingOut, !panelIsModal else { return }
            let available = split.bounds.width - split.dividerThickness
            if available > 0 { fraction = min(1, max(0, terminalHost.view.frame.width / available)) }
            panelSurface.frame = panelPlaceholder.frame
            panelHost.view.frame = panelSurface.bounds
        }
    }
}
#endif
