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
        var sent: [UInt8] = [], opened: [String] = [], clicks: [TerminalLinkClick] = [], failures = 0
        let coordinator = TerminalHostView.Coordinator(onInput: { bytes in
            sent += bytes
            let copied = Array(bytes)
            copied.withUnsafeBytes { buffer in precondition(Darwin.write(master, buffer.baseAddress, buffer.count) == buffer.count) }
        }, onResize: { _,_ in }, onOpenLink: { link, _ in opened.append("delegate:" + link) })
        view.terminalDelegate = coordinator
        view.onOpenFileGesture = { link, click in opened.append(link); clicks.append(click) }
        func populate() {
            view.feed(text: "\u{1b}[2J\u{1b}[HREADME.md:42\r\ndocs/guide.md\r\nfile:///remote/uri.md#L9\r\n\u{1b}]8;;file://owned.invalid/remote/osc.md\u{7}explicit\u{1b}]8;;\u{7}\r\n\u{1b}]8;;/remote/no-extension\u{7}relative\u{1b}]8;;\u{7}\r\n\u{1b}]8;;https://example.invalid/index\u{7}web\u{1b}]8;;\u{7}\r\nnormal control\r\n\u{1b}]8;;file://foreign.invalid/remote/wrong.md\u{7}wrong-host\u{1b}]8;;\u{7}\r\nhttps://example.invalid/query?q=one%20two#fragment\r\n\u{1b}]8;;https://user:synthetic@example.invalid/\u{7}invalid-web\u{1b}]8;;\u{7}\r\n\u{1b}]8;;ssh://example.invalid/\u{7}unsupported\u{1b}]8;;\u{7}\r\n\u{1b}]8;;README.md:42\u{7}source\u{1b}]8;;\u{7}\r\n\u{1b}]8;;file:///remote/uri.md#L9\u{7}uri\u{1b}]8;;\u{7}\r\n/remote/plain.md\r\n~/Projects/tf-post\r\n\u{1b}[?1003h\u{1b}[?1006h")
        }
        populate()
        let cell = view.caretFrame.size
        func point(_ row: Int, _ col: Int = 2) -> CGPoint {
            CGPoint(x: (CGFloat(col) + 0.5) * cell.width, y: view.bounds.maxY - (CGFloat(row) + 0.5) * cell.height)
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, command: Bool, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: command ? [.command] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
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
        let expected = [3: "file://owned.invalid/remote/osc.md", 4: "/remote/no-extension", 5: "https://example.invalid/index", 11: "README.md:42", 12: "file:///remote/uri.md#L9"]
        for command in [false, true] {
            for (row, link) in expected.sorted(by: { $0.key < $1.key }) {
                sent = []; opened = []; _ = received()
                let p = point(row)
                view.mouseDown(with: event(.leftMouseDown, p, command: command))
                check(opened.isEmpty && sent.isEmpty && received().isEmpty, "file press must be claimed before any remote input, with or without Cmd")
                view.mouseUp(with: event(.leftMouseUp, p, command: command))
                check(opened == [link], "plain/Cmd OSC8 file click opens exactly one app preview")
                check(sent.isEmpty && received().isEmpty, "file gesture must send zero input bytes to actual owned PTY")
                check(view.linkReporting == .implicit, "routing must preserve native link reporting")
            }
        }
        // Ordinary NON-file clicks still reach the remote mouse TUI. Their
        // releases must not ALSO open a local file preview. Text that only
        // looks like a path, source location or file URI is not a link: with
        // or without Cmd its click is the same TUI input as any other text.
        for command in [false, true] {
            for row in [6, 10, 0, 1, 2, 13, 14] {
                sent = []; opened = []; _ = received()
                click(row, command: command)
                check(!sent.isEmpty && received() == sent, "normal press/release must still reach the owned PTY")
                check(opened.isEmpty, "ordinary TUI click must not also open preview on release")
                check(String(decoding: sent, as: UTF8.self).hasSuffix("m"), "normal TUI gesture must include release")
            }
        }
        for command in [false, true] {
            sent = []; opened = []; _ = received(); click(8, command: command)
            check(opened == ["https://example.invalid/query?q=one%20two#fragment"] && sent.isEmpty && received().isEmpty, "implicit HTTP(S) link opens locally once with zero PTY input")
        }
        // How the link was clicked goes with it: ⌘ as held at release.
        for command in [false, true] {
            view.onOpenFileGesture = { link, click in opened.append(link); clicks.append(click) }
            sent = []; opened = []; clicks = []; _ = received(); click(11, command: command)
            check(opened.count == 1 && clicks.count == 1 && clicks[0].commandHeld == command && sent.isEmpty && received().isEmpty, "⌘ at release is reported with the link")
        }
        let start = point(11), moved = CGPoint(x: start.x + 40, y: start.y)
        for command in [false, true] {
            // Drag-out/modifier changes never replay a claimed file gesture.
            view.onOpenFileGesture = { link, click in opened.append(link); clicks.append(click) }
            sent = []; opened = []; _ = received()
            view.mouseDown(with: event(.leftMouseDown, start, command: command))
            view.mouseDragged(with: event(.leftMouseDragged, moved, command: !command))
            view.mouseUp(with: event(.leftMouseUp, moved, command: !command))
            check(sent.isEmpty && received().isEmpty && opened.isEmpty, "plain/Cmd claimed drag-out must neither replay to TUI nor open a file")
            // Capture the callback at press, not the replacement pane's callback.
            sent = []; opened = []; _ = received()
            view.onOpenFileGesture = { link, _ in opened.append("old:" + link) }
            view.mouseDown(with: event(.leftMouseDown, start, command: command))
            view.onOpenFileGesture = { link, _ in opened.append("new:" + link) }
            view.mouseUp(with: event(.leftMouseUp, start, command: !command))
            check(opened == ["old:README.md:42"] && sent.isEmpty && received().isEmpty, "owner at plain/Cmd press must be preserved through release")
            view.onOpenFileGesture = { _, _ in failures += 1 }
            let before = failures
            sent = []; opened = []; _ = received(); click(7, command: command)
            check(failures == before + 1 && sent.isEmpty && received().isEmpty && opened.isEmpty, "preview/host-validation failure must not fall back to remote file opener")
            sent = []; opened = []; _ = received(); click(9, command: command)
            check(failures == before + 2 && sent.isEmpty && received().isEmpty, "invalid web URL failure stays local, never invokes remote opener")
            // Even no preview callback must not cause a remote-file fallback.
            view.onOpenFileGesture = nil
            sent = []; opened = []; _ = received(); click(11, command: command); click(5, command: command)
            check(sent.isEmpty && received().isEmpty && opened.isEmpty, "missing callback must still consume file and web gestures")
        }
        // A double or triple click on a link opens it once: the presses after
        // the first are claimed too, and open nothing, even where the first
        // click has moved the link away from under the pointer. Other double
        // clicks are as they were: SwiftTerm selects a word with mouse
        // reporting off, and the program gets them with it on.
        view.onOpenFileGesture = { link, click in opened.append(link); clicks.append(click) }
        func press(_ p: CGPoint, clicks n: Int, command: Bool = false) {
            view.mouseDown(with: event(.leftMouseDown, p, command: command, clicks: n))
            view.mouseUp(with: event(.leftMouseUp, p, command: command, clicks: n))
        }
        func selection() -> String { view.getSelection() ?? "" }
        let web = "https://example.invalid/query?q=one%20two#fragment"
        for reporting in [false, true] {
            populate()
            if !reporting { view.feed(text: "\u{1b}[?1003l\u{1b}[?1006l") }
            let mode = reporting ? "mouse reporting on" : "mouse reporting off"
            for (row, link) in [(8, web), (5, "https://example.invalid/index"), (11, "README.md:42")] {
                for count in [2, 3] {
                    for command in [false, true] {
                        sent = []; opened = []; clicks = []; _ = received(); view.selectNone()
                        for n in 1...count { press(point(row), clicks: n, command: command) }
                        check(opened == [link] && clicks.map(\.commandHeld) == [command], "\(mode): a \(count)-click on \(link) opens it once")
                        check(sent.isEmpty && received().isEmpty && selection().isEmpty, "\(mode): a \(count)-click on a link sends nothing to the PTY and selects nothing")
                    }
                }
            }
            // The first click put something else under the pointer: the
            // presses after it are still the link's.
            sent = []; opened = []; _ = received(); view.selectNone()
            press(point(8), clicks: 1); press(point(6), clicks: 2); press(point(6), clicks: 3)
            check(opened == [web] && sent.isEmpty && received().isEmpty && selection().isEmpty, "\(mode): presses continuing a link click are claimed off the link too, and open nothing")
            // A new click after that is the program's again.
            sent = []; opened = []; _ = received()
            press(point(6), clicks: 1)
            check(opened.isEmpty && (reporting ? !sent.isEmpty && received() == sent : sent.isEmpty), "\(mode): the next new click is not claimed")
            // A double click on a word.
            sent = []; opened = []; _ = received(); view.selectNone()
            press(point(6), clicks: 1); press(point(6), clicks: 2)
            if reporting {
                check(opened.isEmpty && !sent.isEmpty && received() == sent && selection().isEmpty, "mouse reporting on: a double click on a word is the program's")
                check(String(decoding: sent, as: UTF8.self).components(separatedBy: "\u{1b}[<").count - 1 == 4, "mouse reporting on: both presses and releases reach the program")
            } else {
                check(opened.isEmpty && sent.isEmpty && received().isEmpty && selection() == "normal", "mouse reporting off: a double click on a word selects it")
            }
            view.selectNone()
            // A double click whose first press was the program's, onto a
            // link: opened once, and a third press opens nothing more.
            sent = []; opened = []; _ = received()
            press(point(6), clicks: 1)
            let first = sent
            press(point(8), clicks: 2); press(point(8), clicks: 3)
            check(opened == [web] && sent == first && received() == first && selection().isEmpty, "\(mode): a link pressed second in a run opens once")
        }
        // The same rules without a view.
        var run = TerminalFileGesture()
        check(run.begin(link: web, at: .zero, clickCount: 1) && run.end(at: .zero) == web, "a click on a link opens it")
        check(run.begin(link: web, at: .zero, clickCount: 2) && run.ownsPointer && run.end(at: .zero) == nil, "the second press of its double click is claimed and opens nothing")
        check(run.begin(link: nil, at: CGPoint(x: 50, y: 0), clickCount: 3) && run.ownsPointer && run.end(at: CGPoint(x: 50, y: 0)) == nil, "the third press is claimed off the link too")
        check(!run.begin(link: nil, at: .zero, clickCount: 1) && !run.ownsPointer, "a new click off a link starts over, unclaimed")
        check(!run.begin(link: nil, at: .zero, clickCount: 2) && !run.ownsPointer, "and so is the double click it starts")
        check(run.begin(link: "owned.md", at: .zero, clickCount: 2) && run.end(at: .zero) == "owned.md", "a link pressed second in a run opens")
        check(run.begin(link: "owned.md", at: .zero, clickCount: 3) && run.end(at: .zero) == nil, "and the press after it opens nothing")
        check(run.begin(link: "owned.md", at: .zero) && run.end(at: .zero) == "owned.md" && run.begin(link: "owned.md", at: .zero) && run.end(at: .zero) == "owned.md", "presses without a count, as iOS's touches, each open")
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
        print("PASS \(checks) real SwiftTerm mouse press/drag/release, OSC8 file link, plain path to TUI, owned PTY zero-byte, normal-input, failure and captured-owner policy and double/triple click checks; no user terminal/GUI/SSH")
    }
}
