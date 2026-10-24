import SwiftUI

extension View {
    /// Selection is navigation state, not keyboard ownership. Keep AppKit's
    /// native focused selection appearance while input belongs to the terminal.
    func boardSelectionEmphasized(_ selected: Bool) -> some View {
        #if os(macOS)
        background {
            BoardSelectionEmphasis(selected: selected)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
import AppKit

private struct BoardSelectionEmphasis: NSViewRepresentable {
    let selected: Bool
    func makeNSView(context: Context) -> BoardSelectionAnchor {
        let view = BoardSelectionAnchor()
        view.setSelected(selected)
        return view
    }
    func updateNSView(_ view: BoardSelectionAnchor, context: Context) {
        view.setSelected(selected)
    }
    static func dismantleNSView(_ view: BoardSelectionAnchor, coordinator: ()) {
        view.setSelected(false)
    }
}

/// Scoped to the containing native row. No delegate replacement, method
/// swizzling, fake window activity, first-responder changes or custom colors.
/// AppKit also propagates the emphasized background style to its cell contents,
/// keeping the native selected text contrast in light/dark appearances.
final class BoardSelectionAnchor: NSView {
    private var selected = false
    private weak var row: NSTableRowView?
    private var observation: NSKeyValueObservation?
    private var naturalEmphasis = false
    private var applying = false

    isolated deinit { detach() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refresh() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func layout() { super.layout(); refresh() }

    func setSelected(_ value: Bool) {
        selected = value
        refresh()
    }

    private func refresh() {
        guard selected, window != nil else { detach(); return }
        var ancestor = superview
        while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
        guard let current = ancestor as? NSTableRowView else { detach(); return }
        if row !== current {
            detach()
            row = current
            naturalEmphasis = current.isEmphasized
            observation = current.observe(\.isEmphasized, options: [.new]) { [weak self] observed, change in
                MainActor.assumeIsolated {
                    guard let self, self.row === observed, !self.applying else { return }
                    self.naturalEmphasis = change.newValue ?? observed.isEmphasized
                    self.emphasize()
                }
            }
        }
        emphasize()
    }

    private func emphasize() {
        guard let row, !row.isEmphasized else { return }
        applying = true
        row.isEmphasized = true
        row.needsDisplay = true
        applying = false
    }

    private func detach() {
        observation?.invalidate()
        observation = nil
        let previous = row
        row = nil
        if let previous, previous.isEmphasized != naturalEmphasis {
            previous.isEmphasized = naturalEmphasis
            previous.needsDisplay = true
        }
    }
}
#endif
