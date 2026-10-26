#if os(macOS)
import SwiftUI
import AppKit

/// The field a pane's or a tab's name is typed into, in the window's title
/// (see `ContentView`), in AppKit for what SwiftUI's doesn't say: whether
/// the input method is still composing. In the middle of a Korean or
/// Japanese word, Return and Escape belong to the input method — Return
/// ends the composition, Escape takes it back — and acting on them here as
/// well would send the name without its last syllable. So they are only
/// acted on with nothing marked.
///
/// What is typed is never written back into the field, nor anything else
/// about it changed once it is up: every refresh of the board updates this
/// view, and setting a field's value while something is being composed in
/// it commits the composition, or loses it. The text goes to `session`
/// instead, which nothing on screen follows (see `TitleRenameSession`).
///
/// The field takes the keyboard once it is in its window — whichever window
/// that is: in full screen AppKit may host the toolbar in one of its own.
struct TitleRenameField: NSViewRepresentable {
    let session: TitleRenameSession
    /// Whether Return may send what has been typed.
    let canSubmit: (String) -> Bool
    /// Told how the rename ended: on Return and Escape at once, in the key
    /// event; when the keyboard goes elsewhere or the field goes away, on
    /// the next turn of the run loop, since AppKit can report those in the
    /// middle of SwiftUI's update that takes the field away.
    let onEnd: (TitleRenameSession, TitleRenameEnding) -> Void
    /// What a Return that can't send does: the alert sound, as a disabled
    /// default button would.
    var refuse: () -> Void = { NSSound.beep() }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleRenameField

        init(_ parent: TitleRenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.session.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let session = parent.session
            guard !session.isEnded, !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Read now, not from the last change reported: the syllable
                // Return has just committed may not have been.
                session.text = textView.string
                guard parent.canSubmit(session.text) else {
                    parent.refuse()
                    return true
                }
                parent.onEnd(session, .submit)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEnd(session, .cancel)
            default:
                return false
            }
            return true
        }

        /// The keyboard has gone elsewhere: AppKit has committed whatever
        /// was being composed by now, and the field has all of it.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, !parent.session.isEnded else { return }
            parent.session.text = field.stringValue
            endLater()
        }

        func endLater() {
            let session = parent.session, onEnd = parent.onEnd
            guard !session.isEnded else { return }
            DispatchQueue.main.async { onEnd(session, .left) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> TitleRenameTextField {
        // The only place the field's text is set.
        let field = TitleRenameTextField(string: session.startText)
        field.placeholderString = session.prompt
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.bezelStyle = .roundedBezel
        field.font = .titleBarFont(ofSize: 0)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if case .tab = session.item {
            field.setAccessibilityLabel(String(localized: "Rename Tab"))
        } else {
            field.setAccessibilityLabel(String(localized: "Rename Pane"))
            field.toolTip = String(localized: "Leave it empty to call the pane by its title again.")
        }
        field.delegate = context.coordinator
        field.session = session
        return field
    }

    func updateNSView(_ field: TitleRenameTextField, context: Context) {
        // Nothing about the field itself: see the type's comment.
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ field: TitleRenameTextField, coordinator: Coordinator) {
        field.delegate = nil
        coordinator.endLater()
    }
}

/// The AppKit identity and allowed width range of the replacement title item.
/// SwiftUI gives its hosted toolbar item its ideal width as both limits, so
/// AppKit must be told about the range after it has finished that update.
enum TitleRenameToolbar {
    static let itemID = "title-rename"
    static let minimumWidth: CGFloat = 120
    static let idealWidth: CGFloat = 280
}

/// A non-interactive detail-background anchor that gives the title rename
/// toolbar item its real AppKit width range. It deliberately changes only the
/// toolbar belonging to its own window; a SwiftUI toolbar rebuild can recreate
/// the item at any time, so updates and resize notifications are deferred past
/// layout and verify that this anchor is still current before changing it.
struct TitleRenameToolbarRoom: NSViewRepresentable {
    let active: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.coordinator = context.coordinator
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.update(active: active, anchor: view)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class AnchorView: NSView {
        weak var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.anchorWindowDidChange(self)
        }
    }

    final class Coordinator {
        weak var anchor: AnchorView?
        private weak var observedWindow: NSWindow?
        private var resizeObserver: NSObjectProtocol?
        private var active = false
        private var generation = 0

        func update(active: Bool, anchor: AnchorView) {
            self.active = active
            self.anchor = anchor
            guard active else {
                stopObserving()
                return
            }
            observe(anchor.window)
            scheduleUpdate(for: anchor.window)
        }

        func anchorWindowDidChange(_ anchor: AnchorView) {
            guard active, self.anchor === anchor else { return }
            observe(anchor.window)
            scheduleUpdate(for: anchor.window)
        }

        func stopObserving() {
            generation += 1
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
            observedWindow = nil
        }

        private func observe(_ window: NSWindow?) {
            guard observedWindow !== window else { return }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
            observedWindow = window
            guard let window else { return }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    self?.scheduleUpdate(for: window)
                }
            }
        }

        /// Waiting one main-queue turn keeps this out of SwiftUI's view update
        /// and AppKit's current layout pass. The generation/window checks make
        /// stale callbacks harmless after a rebuild or a move between windows.
        private func scheduleUpdate(for window: NSWindow?) {
            generation += 1
            let scheduledGeneration = generation
            DispatchQueue.main.async { [weak self, weak window] in
                self?.applyUpdate(generation: scheduledGeneration, in: window)
            }
        }

        private func applyUpdate(generation scheduledGeneration: Int, in window: NSWindow?) {
            guard active,
                  generation == scheduledGeneration,
                  let anchor,
                  let window,
                  anchor.window === window,
                  observedWindow === window,
                  let toolbar = window.toolbar,
                  let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == TitleRenameToolbar.itemID }),
                  item.view?.window === window else { return }
            item.minSize = NSSize(width: TitleRenameToolbar.minimumWidth, height: item.minSize.height)
            item.maxSize = NSSize(width: TitleRenameToolbar.idealWidth, height: item.maxSize.height)
        }
    }
}

/// The field itself, which takes the keyboard the first time it lands in a
/// window, with what it starts out with selected — on the next turn of the
/// run loop, as `TerminalHostView` does: it lands in the middle of
/// SwiftUI's update, and the window's own handling of that could still move
/// the keyboard on after it.
final class TitleRenameTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { TitleRenameFieldCell.self }
        set {}
    }

    weak var session: TitleRenameSession?
    private var takesKeyboardOnLanding = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard takesKeyboardOnLanding, window != nil else { return }
        takesKeyboardOnLanding = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let session = self.session, !session.isEnded else { return }
            session.keyboardBefore = Self.owner(of: window.firstResponder)
            if window.makeFirstResponder(self) {
                self.currentEditor()?.selectAll(nil)
            }
        }
    }

    /// The view that has the keyboard: for a text field being typed into,
    /// the field, not the editor AppKit lends it.
    private static func owner(of responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field
        }
        return responder
    }
}

/// The field's cell, which keeps what is typed further in from the ends of
/// the rounded bezel than AppKit does. AppKit leaves 4pt, and the editor 2pt
/// more, which puts the insertion point right up against the bezel's left
/// end. The placeholder and the editor are laid out in the same rect, so
/// they move in with the text.
final class TitleRenameFieldCell: NSTextFieldCell {
    /// How much further in, on either side.
    static let horizontalInset: CGFloat = 6

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let drawing = super.drawingRect(forBounds: rect)
        let inset = min(Self.horizontalInset, drawing.width / 2)
        return NSRect(x: drawing.minX + inset, y: drawing.minY, width: drawing.width - 2 * inset, height: drawing.height)
    }
}

extension TitleRenameSession {
    /// Gives the keyboard back to what had it before the field took it, if
    /// that is still in a window and will take it. False otherwise.
    func giveKeyboardBack() -> Bool {
        guard let view = keyboardBefore as? NSView, let window = view.window else { return false }
        return window.makeFirstResponder(view)
    }
}
#endif
