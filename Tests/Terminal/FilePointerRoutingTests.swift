import AppKit
import SwiftTerm
import Darwin

@main @MainActor enum FilePointerRoutingTests {
    static var checks = 0
    static func check(_ b: Bool, _ why: String) { precondition(b, why); checks += 1 }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var master: Int32 = -1, slave: Int32 = -1
        precondition(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        var settings = termios(); precondition(tcgetattr(slave, &settings) == 0)
        cfmakeraw(&settings); precondition(tcsetattr(slave, TCSANOW, &settings) == 0)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC); _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFL, O_NONBLOCK)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FocusReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 420))
        window.contentView = view
        view.linkHighlightMode = .always
        var sent: [UInt8] = [], opened: [String] = [], failures = 0
        let coordinator = TerminalHostView.Coordinator(onInput: { bytes in
            sent += bytes
            let copied = Array(bytes)
            copied.withUnsafeBytes { buffer in precondition(Darwin.write(master, buffer.baseAddress, buffer.count) == buffer.count) }
        }, onResize: { _,_ in }, onOpenLink: { opened.append("delegate:" + $0) })
        view.terminalDelegate = coordinator
        view.onOpenFileGesture = { opened.append($0) }
        func populate() {
            view.feed(text: "\u{1b}[2J\u{1b}[HREADME.md:42\r\ndocs/guide.md\r\nfile:///remote/uri.md#L9\r\n\u{1b}]8;;file://owned.invalid/remote/osc.md\u{7}explicit\u{1b}]8;;\u{7}\r\n\u{1b}]8;;/remote/no-extension\u{7}relative\u{1b}]8;;\u{7}\r\n\u{1b}]8;;https://example.invalid/index\u{7}web\u{1b}]8;;\u{7}\r\nnormal control\r\nfile://foreign.invalid/remote/wrong.md\r\n\u{1b}[?1003h\u{1b}[?1006h")
        }
        populate()
        let cell = view.caretFrame.size
        func point(_ row: Int, _ col: Int = 2) -> CGPoint {
            CGPoint(x: (CGFloat(col) + 0.5) * cell.width, y: view.bounds.maxY - (CGFloat(row) + 0.5) * cell.height)
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, command: Bool) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: command ? [.command] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func received() -> [UInt8] {
            var result: [UInt8] = [], bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(slave, &bytes, bytes.count)
                if n <= 0 { break }; result += bytes.prefix(n)
            }
            return result
        }
        func click(_ row: Int, command: Bool) {
            let p = point(row)
            view.mouseDown(with: event(.leftMouseDown, p, command: command))
            view.mouseUp(with: event(.leftMouseUp, p, command: command))
        }
        let expected = ["README.md:42", "docs/guide.md", "file:///remote/uri.md#L9", "file://owned.invalid/remote/osc.md", "/remote/no-extension"]
        for row in 0..<expected.count {
            sent = []; opened = []; _ = received()
            click(row, command: true)
            check(opened == [expected[row]], "Cmd-click opens exactly one app preview")
            check(sent.isEmpty && received().isEmpty, "file gesture must send zero input bytes to actual owned PTY")
            check(view.linkReporting == .implicit, "temporary routing must restore native link reporting")
        }
        // An ordinary click still reaches the remote mouse TUI, including an
        // OSC8 cell. Its release must not ALSO open a local preview.
        for row in [1, 3, 6] {
            sent = []; opened = []; _ = received()
            click(row, command: false)
            check(!sent.isEmpty && received() == sent, "normal press/release must still reach the owned PTY")
            check(opened.isEmpty, "ordinary TUI click must not also open preview on release")
            check(String(decoding: sent, as: UTF8.self).hasSuffix("m"), "normal TUI gesture must include release")
        }
        sent = []; opened = []; _ = received()
        click(5, command: true)
        check(!sent.isEmpty && received() == sent && opened.isEmpty, "unclaimed web Cmd-click keeps complete TUI input without file preview")
        // Drag-out and modifier release don't turn a claimed file gesture
        // back into a remote motion/release or open the wrong target.
        sent = []; opened = []; _ = received()
        let start = point(0), moved = CGPoint(x: start.x + 40, y: start.y)
        view.mouseDown(with: event(.leftMouseDown, start, command: true))
        view.mouseDragged(with: event(.leftMouseDragged, moved, command: false))
        view.mouseUp(with: event(.leftMouseUp, moved, command: false))
        check(sent.isEmpty && received().isEmpty && opened.isEmpty, "claimed drag-out must neither replay to TUI nor open a file")
        // Capture the owner callback at press, even if a pane/context changes
        // before release; production's old callback rejects retired ownership.
        sent = []; opened = []; _ = received()
        view.onOpenFileGesture = { opened.append("old:" + $0) }
        view.mouseDown(with: event(.leftMouseDown, start, command: true))
        view.onOpenFileGesture = { opened.append("new:" + $0) }
        view.mouseUp(with: event(.leftMouseUp, start, command: false))
        check(opened == ["old:README.md:42"] && sent.isEmpty && received().isEmpty, "owner at press must be preserved through release")
        view.onOpenFileGesture = { _ in failures += 1 } // simulate read/host-validation failure
        sent = []; _ = received(); click(7, command: true)
        check(failures == 1 && sent.isEmpty && received().isEmpty, "preview failure must not fall back to remote file opener")
        // Shared iOS gesture state: begins ownership immediately, cancel/move
        // remains owned until end, and never substitutes a moved-to link.
        var gesture = TerminalFileGesture()
        check(!gesture.begin(link: nil, at: .zero) && !gesture.ownsPointer, "non-file gesture unclaimed")
        check(gesture.begin(link: "file:///owned/a.md", at: .zero) && gesture.ownsPointer, "touch claims at beginning, not at tap end")
        gesture.move(to: CGPoint(x: 20, y: 0))
        check(gesture.ownsPointer && gesture.end(at: CGPoint(x: 20, y: 0)) == nil && !gesture.ownsPointer, "drag stays local and cancels activation")
        _ = gesture.begin(link: "owned.md", at: .zero); gesture.cancel()
        check(!gesture.ownsPointer && gesture.end(at: .zero) == nil, "cancel never activates a file")
        _ = gesture.begin(link: "owned.md", at: .zero)
        check(gesture.end(at: CGPoint(x: 1, y: 1)) == "owned.md", "small pointer motion keeps original target")
        check(FilePreviewLink.isFileGestureLink("file://other/a.md") && !FilePreviewLink.isFileGestureLink("https://example.invalid/a.md"), "intent classification must not route to URI host or claim web schemes")
        print("PASS \(checks) real SwiftTerm mouse press/drag/release, OSC8/file URI, owned PTY zero-byte, normal-input, failure and captured-owner policy checks; no user terminal/GUI/SSH")
    }
}
