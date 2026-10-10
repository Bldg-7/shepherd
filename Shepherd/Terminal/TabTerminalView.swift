import SwiftUI

/// The detail column for one selected tab: every one of its panes at once,
/// each a live terminal of its own, laid out the way herdr has the tab —
/// the same splits in the same proportions, scaled to the room there is.
///
/// Each pane is attached on its own (`PaneTerminalView`), and keyed by its
/// pane, so when a refresh brings a changed layout the panes that are still
/// there only move: their attaches carry on, and only a pane that is new to
/// the tab attaches, and only one that left it detaches.
struct TabTerminalView: View {
    let machine: Machine
    let tab: TabSummary
    let machineStore: MachineStore
    /// Called with a pane's ID each time it gets the keyboard — and only
    /// then, not when it loses it: the window's browser column shows the
    /// browser of the pane last used, which clicking into the browser itself
    /// mustn't change (plan item A2 in docs/agent-browser-plan.md).
    var onPaneActivated: ((String) -> Void)?
    var onOpenFile: ((FilePreviewRequest) -> Void)? = nil

    /// The pane the keyboard is in, which its border marks. On macOS that
    /// starts as the pane herdr has focused in the tab, which is given the
    /// keyboard as the tab comes up; clicking another pane moves it there.
    @State private var focusedPaneID: String?

    var body: some View {
        TabPaneLayout {
            ForEach(tab.panes) { pane in
                if let placement = tab.placement(of: pane.paneID) {
                    TerminalPaneFrame(isFocused: focusedPaneID == pane.paneID) {
                        PaneTerminalView(
                            machine: machine,
                            pane: pane,
                            machineStore: machineStore,
                            focusesWhenShown: pane.paneID == tab.focusedPaneID,
                            onFocusChange: { focused in
                                if focused {
                                    focusedPaneID = pane.paneID
                                    onPaneActivated?(pane.paneID)
                                } else if focusedPaneID == pane.paneID {
                                    focusedPaneID = nil
                                }
                            },
                            onOpenFile: onOpenFile
                        )
                    }
                    #if os(macOS)
                    .overlay(alignment: .topTrailing) {
                        // Which panes have a browser, since the column shows
                        // only one of them at a time.
                        if BrowserStore.shared.hasBrowser(for: BrowserKey(machine: machine, pane: pane)) {
                            Image(systemName: "globe")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .background(.regularMaterial, in: Circle())
                                .padding(6)
                                .allowsHitTesting(false)
                                .help("This pane has a browser")
                        }
                    }
                    #endif
                    .layoutValue(key: PanePlacementKey.self, value: placement)
                }
            }
        }
        .background(Color(white: 0.3))
        .navigationTitle(tab.title)
    }
}

private nonisolated struct PanePlacementKey: LayoutValueKey {
    static let defaultValue: PanePlacement? = nil
}

/// Places each pane at its share of the room the tab is given (see
/// `PanePlacement`), each proposed exactly the size it is placed at, so a
/// terminal's rows and columns follow from its share of the tab.
private struct TabPaneLayout: Layout {
    /// Between two panes, the line the background shows through.
    private static let gap: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let placement = subview[PanePlacementKey.self] else { continue }
            let frame = Self.frame(of: placement, in: bounds)
            subview.place(
                at: frame.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    /// Where a pane goes: its share of the tab, drawn in by half the gap on
    /// each side it shares with another pane. The tab's own edges are left
    /// alone, so the outer panes reach them.
    private static func frame(of placement: PanePlacement, in bounds: CGRect) -> CGRect {
        // herdr's rects are whole cells, but a fraction worked out from them
        // is not always exactly 0 or 1 at the tab's edges.
        let edgeTolerance = 0.001
        let left = placement.x > edgeTolerance ? gap / 2 : 0
        let top = placement.y > edgeTolerance ? gap / 2 : 0
        let right = placement.x + placement.width < 1 - edgeTolerance ? gap / 2 : 0
        let bottom = placement.y + placement.height < 1 - edgeTolerance ? gap / 2 : 0
        return CGRect(
            x: bounds.minX + placement.x * bounds.width + left,
            y: bounds.minY + placement.y * bounds.height + top,
            width: max(0, placement.width * bounds.width - left - right),
            height: max(0, placement.height * bounds.height - top - bottom)
        )
    }
}
