import SwiftUI
import SwiftTerm

/// Thin SwiftUI wrapper around SwiftTerm's `TerminalView`. Feeding bytes in
/// is deliberately NOT done through SwiftUI's declarative update cycle —
/// terminal output is a stream, not diffable state — so this just hands the
/// live `TerminalView` instance out once via `onCreate` and lets the caller
/// (`AgentTerminalViewModel`) feed it directly as data arrives.
struct TerminalHostView {
    var onCreate: (TerminalView) -> Void
    var onInput: (ArraySlice<UInt8>) -> Void
    var onResize: (Int, Int) -> Void
    /// Told true when the terminal gets the keyboard, false when it loses it.
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Whether the terminal takes the keyboard as soon as it is on screen.
    /// macOS only: on iOS that would also bring the on-screen keyboard up
    /// over it unasked.
    var focusesWhenShown = false
    /// Told a link clicked in the terminal, with how it was clicked.
    var onOpenLink: ((String, TerminalLinkClick) -> Void)? = nil
    /// Told the files dropped from Finder on the terminal. While this is
    /// nil the terminal takes no drops at all, and a drag over it goes back
    /// where it came from, as it always did.
    var onDropFiles: (([URL]) -> Void)? = nil

    final class Coordinator: NSObject, TerminalViewDelegate {
        let onInput: (ArraySlice<UInt8>) -> Void
        let onResize: (Int, Int) -> Void
        var onOpenLink: ((String, TerminalLinkClick) -> Void)?

        init(onInput: @escaping (ArraySlice<UInt8>) -> Void, onResize: @escaping (Int, Int) -> Void, onOpenLink: ((String, TerminalLinkClick) -> Void)?) {
            self.onInput = onInput
            self.onResize = onResize
            self.onOpenLink = onOpenLink
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { onOpenLink?(link, .unknown) }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize, onOpenLink: onOpenLink)
    }
}

/// SwiftTerm's terminal, telling its owner when it gets and loses the
/// keyboard, and able to take it once it is in a window.
///
/// SwiftTerm sets `hasFocus` in its `becomeFirstResponder` and
/// `resignFirstResponder`, which on macOS it doesn't let a subclass
/// override; `hasFocus` it does.
///
/// The owner is told on the next turn of the run loop, not from inside the
/// change: the keyboard also leaves a terminal when SwiftUI takes the
/// terminal's view away in an update — another tab selected, the window
/// closed — and the owner's state must not change in the middle of one.
final class FocusReportingTerminalView: TerminalView {
    var onFocusChange: ((Bool) -> Void)?
    var focusesWhenShown = false
    var onOpenFileGesture: ((String, TerminalLinkClick) -> Void)?
    /// See `TerminalHostView.onDropFiles`. Setting it registers the view
    /// for file drags, or stops it taking them.
    var onDropFiles: (([URL]) -> Void)? {
        didSet {
            if onDropFiles == nil {
                if !registeredDraggedTypes.isEmpty { unregisterDraggedTypes() }
            } else if !registeredDraggedTypes.contains(.fileURL) {
                registerForDraggedTypes([.fileURL])
            }
        }
    }
    private var fileGesture = TerminalFileGesture()
    private var capturedFileHandler: ((String, TerminalLinkClick) -> Void)?
    private(set) var drawGate = TerminalDrawGate()

    // While the window can't be seen, SwiftTerm still takes every byte and
    // keeps its screen up to date, but what it asks to redraw is only noted
    // (TerminalDrawGate). The view is never hidden, so it keeps the keyboard.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard drawGate.request() else { return }
        super.setNeedsDisplay(invalidRect)
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue, !drawGate.request() { return }
            super.needsDisplay = newValue
        }
    }

    /// Draws the whole terminal once when it becomes visible with redraws
    /// held back.
    func updateDrawing(visible: Bool) {
        if drawGate.update(visible: visible) { super.setNeedsDisplay(bounds) }
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        updateDrawing(visible: TerminalDrawGate.isVisible(inWindow: window != nil,
            occlusionVisible: window?.occlusionState.contains(.visible) == true,
            miniaturized: window?.isMiniaturized == true, applicationHidden: NSApp?.isHidden == true))
    }

    /// Follows the window the view is in now. The center drops these
    /// selector observers by itself when the view goes away.
    private func observeWindowVisibility() {
        let center = NotificationCenter.default
        let windowNames = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        let applicationNames = [NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        for name in windowNames + applicationNames { center.removeObserver(self, name: name, object: nil) }
        if let window {
            for name in windowNames { center.addObserver(self, selector: #selector(windowVisibilityChanged(_:)), name: name, object: window) }
            for name in applicationNames { center.addObserver(self, selector: #selector(windowVisibilityChanged(_:)), name: name, object: nil) }
        }
        windowVisibilityChanged(Notification(name: NSWindow.didChangeOcclusionStateNotification))
    }

    /// Sends `text` to the program as a paste, the way other terminals send
    /// a drop: in one piece, and between the bracketed-paste markers when
    /// the program has asked for them (mode 2004), so that it knows the
    /// text for a paste rather than typing — Claude Code only looks for
    /// image paths in a paste.
    func sendPaste(_ text: String) {
        var bytes = Array(text.utf8)
        if getTerminal().bracketedPasteMode {
            bytes = Self.pasteStart + bytes + Self.pasteEnd
        }
        send(data: bytes[...])
    }

    /// SwiftTerm's `EscapeSequences.bracketedPasteStart`/`End`, which it
    /// declares as mutable statics.
    private static let pasteStart = Array("\u{1b}[200~".utf8)
    private static let pasteEnd = Array("\u{1b}[201~".utf8)

    /// ⌘⌫ goes to the program as Ctrl-U, which deletes back to the start of
    /// the line in a shell and in Claude Code's prompt: what Ghostty
    /// (`super+backspace=text:\x15`) and iTerm2's Natural Text Editing send.
    /// macOS makes the key, with or without Shift, `deleteToBeginningOfLine:`,
    /// which SwiftTerm 1.20.0's `doCommand(by:)` drops, and that method isn't
    /// open to a subclass. Its `keyDown` hands the key here first, with the
    /// kitty keyboard on or off.
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if eventArray.count == 1, let event = eventArray.first,
           event.charactersIgnoringModifiers == "\u{7f}",
           event.modifierFlags.intersection([.control, .option, .command]) == .command {
            send(data: [0x15])
            return
        }
        super.interpretKeyEvents(eventArray)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedFiles(in: sender)
        guard let onDropFiles, !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }

    private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && !droppedFiles(in: sender).isEmpty ? .copy : []
    }

    private func droppedFiles(in sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func mouseDown(with event: NSEvent) {
        fileGesture.cancel()
        capturedFileHandler = nil
        let point = convert(event.locationInWindow, from: nil)
        if fileGesture.begin(link: TerminalFileHit.link(in: self, point: point), at: point) {
            capturedFileHandler = onOpenFileGesture // owner at press, not release
            return // no remote press, including explicit OSC8/file URI targets
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if fileGesture.ownsPointer {
            fileGesture.move(to: convert(event.locationInWindow, from: nil))
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if fileGesture.ownsPointer {
            let handler = capturedFileHandler
            capturedFileHandler = nil
            if let link = fileGesture.end(at: convert(event.locationInWindow, from: nil)) {
                // ⌘ is read at release, like the link: it is the one
                // modifier the xterm mouse protocol doesn't carry to the
                // program, so the claimed click is the only thing it means
                // anything to (see `LinkDestinationPolicy`).
                handler?(link, TerminalLinkClick(commandHeld: event.modifierFlags.contains(.command),
                                                 windowPoint: topLeftWindowPoint(event.locationInWindow)))
            }
            return // failure/drag never replays this gesture to the remote TUI
        }
        // An unclaimed NON-file click belongs to the TUI, not BOTH the TUI
        // on press and Shepherd on release. Keep reporting/selection enabled.
        // linkReporting controls hover discovery, NOT OSC8 activation in
        // SwiftTerm. Gate activation explicitly for this one release. The
        // Command is not an SGR mouse modifier; recognized file links above
        // are already claimed regardless of the modifier.
        let release: NSEvent
        if event.modifierFlags.contains(.command) {
            guard let copy = NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: event.modifierFlags.subtracting(.command), timestamp: event.timestamp,
                windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                clickCount: event.clickCount, pressure: event.pressure) else { return }
            release = copy
        } else { release = event }
        let highlighting = linkHighlightMode
        linkHighlightMode = .alwaysWithModifier
        defer { linkHighlightMode = highlighting }
        super.mouseUp(with: release)
    }

    /// `point`, given in the window's coordinates with the origin at the
    /// bottom left as AppKit has it, with the origin at the top left of the
    /// window's content as SwiftUI's global coordinate space has it. Nil
    /// while the view isn't in a window.
    private func topLeftWindowPoint(_ point: NSPoint) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        return CGPoint(x: point.x, y: content.bounds.height - point.y)
    }

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            guard let onFocusChange else { return }
            DispatchQueue.main.async { onFocusChange(newValue) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowVisibility()
        guard focusesWhenShown, window != nil else { return }
        focusesWhenShown = false
        // On the next turn of the run loop: the view lands in its window in
        // the middle of SwiftUI's update, and the window's own handling of
        // that update could still move the keyboard on after this.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Whether a terminal draws what it is asked to redraw. A window that can't
/// be seen — covered, on another Space, minimized, or its app hidden — gets
/// no drawing; its redraw requests are remembered, and the first time it can
/// be seen again the whole terminal is drawn once.
nonisolated struct TerminalDrawGate: Equatable {
    private(set) var visible = true
    private(set) var pending = false

    /// Outside a window AppKit draws nothing anyway; it then draws what the
    /// view marked when the view lands in one.
    static func isVisible(inWindow: Bool, occlusionVisible: Bool, miniaturized: Bool, applicationHidden: Bool) -> Bool {
        !inWindow || (occlusionVisible && !miniaturized && !applicationHidden)
    }

    /// Whether a redraw request goes through now.
    mutating func request() -> Bool {
        if visible { return true }
        pending = true
        return false
    }

    /// Whether to redraw the whole terminal now.
    mutating func update(visible: Bool) -> Bool {
        self.visible = visible
        guard visible, pending else { return false }
        pending = false
        return true
    }
}

extension TerminalHostView: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        let view = FocusReportingTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.onFocusChange = onFocusChange
        view.focusesWhenShown = focusesWhenShown
        view.onOpenFileGesture = onOpenLink
        view.onDropFiles = onDropFiles
        onCreate(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        (nsView as? FocusReportingTerminalView)?.onOpenFileGesture = onOpenLink
        (nsView as? FocusReportingTerminalView)?.onDropFiles = onDropFiles
    }
}

#Preview {
    TerminalHostView(
        onCreate: { view in
            view.feed(text: "Shepherd\r\n$ echo hello\r\nhello\r\n$ ")
        },
        onInput: { _ in },
        onResize: { _, _ in }
    )
    .frame(minWidth: 320, minHeight: 240)
}
