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
    private var fileGesture = TerminalFileGesture()
    private var capturedFileHandler: ((String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        fileGesture.cancel()
        capturedFileHandler = nil
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command),
           fileGesture.begin(link: TerminalFileHit.link(in: self, point: point), at: point) {
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
        // An ordinary click belongs to the TUI, not BOTH the TUI on press
        // and Shepherd on release. Keep mouse reporting/selection enabled.
        // linkReporting controls hover discovery, NOT OSC8 activation in
        // SwiftTerm. Gate activation explicitly for this one release. The
        // Command bit is local link intent (not an SGR mouse modifier).
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
        onCreate(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        (nsView as? FocusReportingTerminalView)?.onOpenFileGesture = onOpenLink
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
