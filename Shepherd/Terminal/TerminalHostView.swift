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

    final class Coordinator: NSObject, TerminalViewDelegate {
        let onInput: (ArraySlice<UInt8>) -> Void
        let onResize: (Int, Int) -> Void

        init(onInput: @escaping (ArraySlice<UInt8>) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
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
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
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
        onCreate(view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
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
