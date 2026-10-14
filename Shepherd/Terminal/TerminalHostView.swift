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
    var onOpenLink: ((String) -> Void)? = nil
    /// Told the files dropped from Finder on the terminal. While this is
    /// nil the terminal takes no drops at all, and a drag over it goes back
    /// where it came from, as it always did.
    var onDropFiles: (([URL]) -> Void)? = nil

    final class Coordinator: NSObject, TerminalViewDelegate {
        let onInput: (ArraySlice<UInt8>) -> Void
        let onResize: (Int, Int) -> Void
        var onOpenLink: ((String) -> Void)?

        init(onInput: @escaping (ArraySlice<UInt8>) -> Void, onResize: @escaping (Int, Int) -> Void, onOpenLink: ((String) -> Void)?) {
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
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { onOpenLink?(link) }
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
    var onOpenFileGesture: ((String) -> Void)?
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
    private var capturedFileHandler: ((String) -> Void)?

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
                handler?(link)
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
