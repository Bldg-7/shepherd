#if os(macOS)
import SwiftUI
import AppKit

/// A key the file preview takes for itself while it has the keyboard.
enum PreviewKeyCommand: Equatable, Sendable {
    /// ⌘F: shows the find bar, with the keyboard in it.
    case find
    /// ⌘G and ⇧⌘G: the find bar's next and previous match.
    case findNext, findPrevious
    /// ⌘R: reads the file again.
    case reload

    /// Each key the preview takes: its character, and exactly the
    /// modifiers, of ⇧, ⌃, ⌥ and ⌘, it is taken with.
    static let keys: [(character: String, modifiers: NSEvent.ModifierFlags, command: Self)] = [
        ("f", .command, .find),
        ("g", .command, .findNext),
        ("g", [.command, .shift], .findPrevious),
        ("r", .command, .reload),
    ]

    /// The command a key-down is, if it is one of `keys`.
    init?(_ event: NSEvent) {
        guard event.type == .keyDown, let character = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard let key = Self.keys.first(where: { $0.character == character && $0.modifiers == modifiers }) else { return nil }
        self = key.command
    }
}

/// Where a preview's keyboard goes: into its find field, or back to the
/// preview. Made with the panel; the find field and the key catcher tell it
/// about themselves as they come.
final class PreviewKeyboard {
    weak var catcher: PreviewKeyCatcherView?
    weak var field: NSTextField?
    /// Whether the find field is to take the keyboard as it comes into the
    /// window: it was asked to before it was there.
    var fieldWanted = false

    /// Puts the keyboard in the find field, with what is typed in it
    /// selected — once the field is there, if it is only coming.
    func focusFindField() {
        guard let field, let window = field.window else { fieldWanted = true; return }
        fieldWanted = false
        if window.makeFirstResponder(field) { field.currentEditor()?.selectAll(nil) }
    }

    /// Gives the keyboard to the preview, as a click in it does: from the
    /// find field too, which is going.
    func focusPreview() {
        catcher?.takeKeyboard()
    }

    /// Gives the keyboard back to what had it before a click in the preview
    /// took it, as an expanded preview restored to its size does.
    func giveBack() {
        catcher?.giveKeyboardBack()
    }
}

/// Behind the preview, in AppKit: takes the preview's keys (see
/// `PreviewKeyCommand`) and gives the preview the keyboard on a click in it.
///
/// The keys are taken while the keyboard is in the preview — the view of
/// the hosting controller the preview is in, or a view inside it such as the
/// find field — and only those the preview does something with: anywhere
/// else, a terminal or the sidebar, they go on as they did. SwiftUI's
/// `keyboardShortcut` can't be used for them, as it takes its key from a
/// terminal beside the preview that has the keyboard.
struct PreviewKeyCatcher: NSViewRepresentable {
    let keyboard: PreviewKeyboard
    /// Does what a key asks for. Whether it was done: a key that wasn't goes
    /// on to the menus.
    let perform: (PreviewKeyCommand) -> Bool
    /// Gives the preview SwiftUI's focus, as a click in it does: for Esc.
    let onTakeKeyboard: () -> Void

    func makeNSView(context: Context) -> PreviewKeyCatcherView {
        let view = PreviewKeyCatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PreviewKeyCatcherView, context: Context) {
        view.perform = perform
        view.onTakeKeyboard = onTakeKeyboard
        keyboard.catcher = view
    }
}

/// See `PreviewKeyCatcher`. Takes no clicks itself; it watches its window's
/// with a local event monitor, which sees each one before AppKit hands it
/// on, as `TitleDoubleClickView` does.
final class PreviewKeyCatcherView: NSView {
    var perform: (PreviewKeyCommand) -> Bool = { _ in false }
    var onTakeKeyboard: () -> Void = {}
    private var monitor: Any?
    /// What had the keyboard before a click in the preview took it: given
    /// it back when the preview goes.
    private weak var previousResponder: NSView?

    isolated deinit { stop() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The view of the hosting controller the preview is in: the keyboard is
    /// in the preview when it is in this view or in one inside it.
    var previewRoot: NSView? {
        var view: NSView? = self
        while let candidate = view {
            if let controller = candidate.nextResponder as? NSViewController, controller.view === candidate { return candidate }
            view = candidate.superview
        }
        return nil
    }

    /// Whether `responder`, a window's first responder, is in the preview
    /// whose root is `root`.
    static func isInPreview(_ responder: NSResponder?, root: NSView) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === root || view.isDescendant(of: root)
    }

    /// Whether the preview has the keyboard.
    var hasKeyboard: Bool {
        guard let window, let root = previewRoot else { return false }
        return Self.isInPreview(window.firstResponder, root: root)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let command = PreviewKeyCommand(event), hasKeyboard, perform(command) else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { giveKeyboardBack() }
        super.viewWillMove(toWindow: newWindow)
    }

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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Local monitors run on the main thread; only what the decision
            // needs is handed over to it, not the event.
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.windowNumber == windowNumber,
                      self.takesKeyboard(forClickAt: location) else { return }
                self.takeKeyboard()
            }
            return event
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Whether a click at `location`, in its window's coordinates, gives the
    /// preview the keyboard: it lands in the preview, not on a view there
    /// that takes the keyboard itself, as the find field does, while the
    /// keyboard is elsewhere, or in no view of the preview — or in the find
    /// field, and the click is off the find bar: the text clicked is then
    /// what ⌘C copies.
    func takesKeyboard(forClickAt location: NSPoint) -> Bool {
        guard let window, window.attachedSheet == nil, let root = previewRoot else { return false }
        var frame: NSView = root
        while let superview = frame.superview {
            frame = superview
        }
        guard let hit = frame.hitTest(location), Self.isInPreview(hit, root: root) else { return false }
        var view: NSView? = hit
        while let candidate = view, candidate !== root {
            if candidate.acceptsFirstResponder { return false }
            view = candidate.superview
        }
        let first = window.firstResponder
        if first === root || !Self.isInPreview(first, root: root) { return true }
        guard let editor = first as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView else { return false }
        // The find bar is as wide as the preview, and its capsule reaches
        // 15 points above and below its field.
        let bar = field.convert(field.bounds, to: nil).insetBy(dx: 0, dy: -16)
        return !(bar.minY...bar.maxY).contains(location.y)
    }

    /// Gives the preview the keyboard, as a click in it does: AppKit's,
    /// which a terminal beside it had, and SwiftUI's focus, which Esc needs.
    func takeKeyboard() {
        guard let window, let root = previewRoot else { return }
        let first = window.firstResponder
        if !Self.isInPreview(first, root: root) {
            if let view = first as? NSView, view.window === window { previousResponder = view }
            window.makeFirstResponder(root)
        } else if (first as? NSTextView)?.isFieldEditor == true {
            // Out of the find field.
            window.makeFirstResponder(root)
        }
        onTakeKeyboard()
    }

    /// Gives the keyboard back to what had it before a click in the preview
    /// took it, if that is still in the window and the keyboard is in the
    /// preview or left with nothing — the window, or a view hidden or gone:
    /// as the preview goes, and as it is restored from expanded, as it gave
    /// the keyboard back before a click in it took it. Once the update that
    /// asks for it is over: what is left with the keyboard is known only
    /// then.
    func giveKeyboardBack() {
        guard let window, let previous = previousResponder else { return }
        previousResponder = nil
        let root = previewRoot
        DispatchQueue.main.async { [weak window, weak previous, weak root] in
            guard let window, let previous, previous.window === window, !previous.isHiddenOrHasHiddenAncestor else { return }
            let first = window.firstResponder
            if let view = first as? NSView {
                let left = view.window !== window || view.isHiddenOrHasHiddenAncestor
                    || (root.map { Self.isInPreview(view, root: $0) } ?? false)
                guard left else { return }
            } else if first != nil && first !== window {
                return
            }
            window.makeFirstResponder(previous)
        }
    }
}
#endif
