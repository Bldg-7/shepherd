#if os(macOS)
import SwiftUI
import AppKit

/// A double-click on the window's title has a new name typed into it, as
/// the selected row's Rename item does (see `TitleRenameField`).
///
/// SwiftUI has nothing to put a gesture on there: the title is AppKit's own
/// label in the toolbar, outside the content. So the clicks in the window
/// this is in are watched with a local event monitor, which sees each one
/// before AppKit hands it on. Only a double-click on the title's text
/// counts — the label is only as wide as its text — and it goes no further,
/// nor does the mouse-up after it: the window would be zoomed or minimized
/// under the field otherwise. A double-click anywhere else in the title bar
/// is left to the system, which does with it what System Settings says.
///
/// In full screen AppKit may host the toolbar in a window of its own; a
/// double-click on the title there counts as well.
struct TitleDoubleClick: NSViewRepresentable {
    /// Starts the rename, if one can start now. False if not: the
    /// double-click is then the system's.
    let rename: () -> Bool

    func makeNSView(context: Context) -> TitleDoubleClickView {
        let view = TitleDoubleClickView()
        view.rename = rename
        return view
    }

    func updateNSView(_ view: TitleDoubleClickView, context: Context) {
        view.rename = rename
    }
}

/// Watches the clicks in its window while it is in one (see
/// `TitleDoubleClick`). Takes none itself.
final class TitleDoubleClickView: NSView {
    var rename: () -> Bool = { false }
    private var monitor: Any?
    /// Set once a double-click has started a rename, for the mouse-up that
    /// follows it.
    private var swallowsMouseUp = false

    isolated deinit { stop() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            // Local monitors run on the main thread; only what the decision
            // needs is handed over to it, not the event.
            let isDown = event.type == .leftMouseDown
            let clickCount = event.clickCount
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            let swallows = MainActor.assumeIsolated {
                self?.swallows(isDown: isDown, clickCount: clickCount, windowNumber: windowNumber, location: location) ?? false
            }
            return swallows ? nil : event
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        swallowsMouseUp = false
    }

    /// Whether a click goes no further: the second press of a double-click
    /// on the title's text that has started a rename, and the mouse-up
    /// after it. Not while a sheet is over the window.
    private func swallows(isDown: Bool, clickCount: Int, windowNumber: Int, location: NSPoint) -> Bool {
        guard isDown else {
            defer { swallowsMouseUp = false }
            return swallowsMouseUp
        }
        swallowsMouseUp = false
        guard clickCount == 2, let window, window.attachedSheet == nil,
              let clicked = NSApp.window(withWindowNumber: windowNumber),
              Self.isTitleText(at: location, in: clicked, of: window),
              rename() else { return false }
        swallowsMouseUp = true
        return true
    }

    /// Whether `location` in `clicked` is on the text of `window`'s title:
    /// on a label that shows the title, outside the window's content and
    /// outside every toolbar item — in `window` itself, or in the window
    /// AppKit hosts its toolbar in.
    static func isTitleText(at location: NSPoint, in clicked: NSWindow, of window: NSWindow) -> Bool {
        guard !window.title.isEmpty else { return false }
        let itemViews = window.toolbar?.items.compactMap(\.view) ?? []
        guard clicked === window || itemViews.contains(where: { $0.window === clicked }),
              var root = clicked.contentView else { return false }
        while let superview = root.superview {
            root = superview
        }
        var view = root.hitTest(location)
        while let candidate = view {
            if let label = candidate as? NSTextField, !label.isEditable, label.stringValue == window.title,
               !(window.contentView.map { label.isDescendant(of: $0) } ?? false),
               !itemViews.contains(where: { label.isDescendant(of: $0) }) {
                return true
            }
            view = candidate.superview
        }
        return false
    }
}
#endif
