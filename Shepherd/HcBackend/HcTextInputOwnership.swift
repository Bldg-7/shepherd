#if os(macOS)
import AppKit
import SwiftUI

/// Passive ownership metadata from controls in this app's own window. No key
/// contents, global event monitor, activation or replacement input field.
struct HcTextInputOwnership: NSViewRepresentable {
    let presentation: HcWorkspacePresentation
    func makeNSView(context: Context) -> Anchor { Anchor(presentation:presentation) }
    func updateNSView(_ view: Anchor, context: Context) { view.presentation = presentation }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }

    final class Anchor: NSView {
        var presentation: HcWorkspacePresentation
        private weak var editing: NSControl?
        private var observing = false
        private var ownsEditing = false
        init(presentation: HcWorkspacePresentation) { self.presentation = presentation; super.init(frame:.zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        isolated deinit { stop() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            observing = true
            NotificationCenter.default.addObserver(self,selector:#selector(began(_:)),name:NSControl.textDidBeginEditingNotification,object:nil)
            NotificationCenter.default.addObserver(self,selector:#selector(ended(_:)),name:NSControl.textDidEndEditingNotification,object:nil)
            NotificationCenter.default.addObserver(self,selector:#selector(changed(_:)),name:NSControl.textDidChangeNotification,object:nil)
        }
        func stop() {
            if observing { NotificationCenter.default.removeObserver(self); observing = false }
            if ownsEditing { editing = nil; ownsEditing = false; presentation.textEditingEnded() }
        }
        // AppKit control editing notifications are main-thread UI callbacks.
        // Only @ObservationIgnored metadata changes here, including in layout.
        @objc private func began(_ note: Notification) {
            precondition(Thread.isMainThread)
            guard let control = note.object as? NSControl, let window, control.window === window else { return }
            editing = control; ownsEditing = true; presentation.textEditingBegan()
        }
        @objc private func changed(_ note: Notification) {
            precondition(Thread.isMainThread)
            guard let control = note.object as? NSControl, let window, control.window === window,
                  let editor = control.currentEditor(), window.firstResponder === editor else { return }
            // Typing into an already active field is a newer input intent too.
            editing = control; ownsEditing = true; presentation.textEditingBegan()
        }
        @objc private func ended(_ note: Notification) {
            precondition(Thread.isMainThread)
            guard let control = note.object as? NSControl, editing === control else { return }
            editing = nil; ownsEditing = false; presentation.textEditingEnded()
        }
    }
}
#endif
