import AppKit
import SwiftTerm
import Darwin
import NIOCore

// The app declares this in AgentTerminalView.swift, which needs the whole
// app to compile; run-selection-tests.py checks that the line is there.
extension FocusReportingTerminalView: SelectionKeepingTerminal {}

func connectionFailureDescription(_ error: any Error) -> String { "\(error)" }

/// A pane whose output the test sends, piece by piece, as herdr's frames.
actor FrameSession: TerminalSessionProviding {
    private var continuation: AsyncStream<ByteBuffer>.Continuation?
    private let first: String
    init(first: String) { self.first = first }
    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
            var buffer = ByteBuffer(); buffer.writeString(first)
            continuation.yield(buffer)
        }
    }
    func push(_ text: String) { var buffer = ByteBuffer(); buffer.writeString(text); continuation?.yield(buffer) }
    func write(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func stop() async { continuation?.finish(); continuation = nil }
}

/// A view drawn over part of the terminal, as a sheet or a panel would be.
final class Cover: NSView {}

/// Text selection on the production terminal view (SHPHRD-93), with real
/// AppKit mouse, key and wheel events, an owned kernel PTY standing in for
/// the attach, never-shown windows and the output herdr sends. Byte strings
/// are what the PTY received. No user GUI, herdr or SSH.
@main @MainActor enum TerminalSelectionTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: @autoclosure () -> String) { precondition(condition, why()); checks += 1 }

    static func main() async {
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 420))
        window.contentView = container
        let view = FocusReportingTerminalView(frame: container.bounds)
        container.addSubview(view)
        let cover = Cover(frame: NSRect(x: 880, y: 0, width: 80, height: 420))
        container.addSubview(cover)
        var sent: [UInt8] = [], opened: [String] = [], clicks: [TerminalLinkClick] = []
        let coordinator = TerminalHostView.Coordinator(onInput: { bytes in
            sent += bytes
            let copied = Array(bytes)
            copied.withUnsafeBytes { buffer in precondition(Darwin.write(master, buffer.baseAddress, buffer.count) == buffer.count) }
        }, onResize: { _, _ in }, onOpenLink: { link, _ in opened.append("delegate:" + link) })
        view.terminalDelegate = coordinator
        view.onOpenFileGesture = { link, click in opened.append(link); clicks.append(click) }

        func received() -> [UInt8] {
            var result: [UInt8] = [], bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(slave, &bytes, bytes.count)
                if n <= 0 { break }; result += bytes.prefix(n)
            }
            return result
        }
        func shown(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}", with: "⎋") }
        func output(_ text: String) { view.feedKeepingSelection(Array(text.utf8)[...]) }
        func selected() -> String { view.getSelection() ?? "" }
        func reset() { sent = []; opened = []; clicks = []; _ = received() }
        func nothingSent(_ label: String) {
            let pty = received()
            check(sent.isEmpty && pty.isEmpty, "\(label): nothing reaches the program, got \(shown(sent)) / \(shown(pty))")
            sent = []
        }
        func exactlySent(_ expected: [UInt8], _ label: String) {
            let pty = received()
            check(sent == expected && pty == expected, "\(label): expected \(shown(expected)), sent \(shown(sent)), PTY \(shown(pty))")
            sent = []
        }

        // The pane as herdr shows it: on the alternate screen, with the
        // mouse modes `herdr terminal attach` asks for when the pane's
        // program takes the mouse (crossterm's), or none.
        let rows = ["alpha beta gamma delta", "second line of plain text", "oscweblink tail text",
                    "https://example.invalid/plain more words", "fourth line words here", "explicit after", "seventh row text here"]
        let webLink = "https://example.invalid/osc", fileLink = "file://owned.invalid/remote/osc.md"
        let mouseOn = "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1015h\u{1b}[?1006h"
        let mouseOff = "\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l"
        func screen(reporting: Bool) {
            var text = "\u{1b}[>0s" + mouseOff + "\u{1b}[?1049h" + (reporting ? mouseOn : "") + "\u{1b}[2J\u{1b}[H"
            text += rows[0] + "\r\n" + rows[1] + "\r\n"
            text += "\u{1b}]8;;\(webLink)\u{7}oscweblink\u{1b}]8;;\u{7} tail text\r\n"
            text += rows[3] + "\r\n" + rows[4] + "\r\n"
            text += "\u{1b}]8;;\(fileLink)\u{7}explicit\u{1b}]8;;\u{7} after\r\n"
            text += rows[6] + "\u{1b}[H"
            output(text)
            view.selectNone()
            reset()
            check(view.getTerminal().mouseMode == (reporting ? .anyEvent : .off) && view.getTerminal().isCurrentBufferAlternate, "screen set up")
        }
        // A frame as herdr sends one, changing a cell the selections below
        // never cover; one that redraws the first row as it was; one that
        // writes over cells of the second row.
        let frame = "\u{1b}[?2026h\u{1b}[?25l\u{1b}[9;1Hx\u{1b}[1;1H\u{1b}[?25h\u{1b}[?2026l"
        let sameRow = "\u{1b}[?2026h\u{1b}[1;1H\(rows[0])\u{1b}[1;1H\u{1b}[?2026l"
        let overSecond = "\u{1b}[?2026h\u{1b}[2;1HXYZ\u{1b}[1;1H\u{1b}[?2026l"

        let cell = view.caretFrame.size
        check(cell.width > 0 && cell.height > 0, "cell size")
        func point(_ at: (Int, Int)) -> CGPoint {
            CGPoint(x: (CGFloat(at.1) + 0.5) * cell.width, y: view.bounds.maxY - (CGFloat(at.0) + 0.5) * cell.height)
        }
        var eventNumber = 0
        func mouse(_ type: NSEvent.EventType, _ at: CGPoint, _ flags: NSEvent.ModifierFlags, clicks: Int = 1) -> NSEvent {
            eventNumber += 1
            return NSEvent.mouseEvent(with: type, location: view.convert(at, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func button(_ flags: NSEvent.ModifierFlags) -> Int {
            (flags.contains(.shift) ? 4 : 0) + (flags.contains(.option) ? 8 : 0) + (flags.contains(.control) ? 16 : 0)
        }
        func sgr(_ button: Int, _ at: (Int, Int), _ final: String) -> [UInt8] { Array("\u{1b}[<\(button);\(at.1 + 1);\(at.0 + 1)\(final)".utf8) }
        /// A drag from cell to cell, as AppKit delivers one: the press, a
        /// drag event at each step (the first where it was pressed), the
        /// release. Returns what SwiftTerm reports for it with mouse
        /// reporting on.
        @discardableResult
        func drag(_ from: (Int, Int), _ to: (Int, Int), _ flags: NSEvent.ModifierFlags = [], during: ((Int) -> Void)? = nil) -> [UInt8] {
            let steps = 6
            var reported = sgr(button(flags), from, "M")
            view.mouseDown(with: mouse(.leftMouseDown, point(from), flags))
            for i in 0...steps {
                let at = (from.0 + (to.0 - from.0) * i / steps, from.1 + (to.1 - from.1) * i / steps)
                view.mouseDragged(with: mouse(.leftMouseDragged, point(at), flags))
                reported += sgr(button(flags) + 32, at, "M")
                during?(i)
            }
            view.mouseUp(with: mouse(.leftMouseUp, point(to), flags))
            return reported + sgr(button(flags), to, "m")
        }
        @discardableResult
        func click(_ at: (Int, Int), _ flags: NSEvent.ModifierFlags = [], count: Int = 1) -> [UInt8] {
            var reported: [UInt8] = []
            for n in 1...count {
                view.mouseDown(with: mouse(.leftMouseDown, point(at), flags, clicks: n))
                view.mouseUp(with: mouse(.leftMouseUp, point(at), flags, clicks: n))
                reported += sgr(button(flags), at, "M") + sgr(button(flags), at, "m")
            }
            return reported
        }
        let firstSpan = rows[0] + "\n" + "secon"   // (0,0) to (1,5)

        for reporting in [false, true] {
            let mode = reporting ? "mouse reporting on" : "mouse reporting off"

            // A plain drag: a selection where the program doesn't take the
            // mouse, the program's otherwise, with the bytes it got before.
            screen(reporting: reporting)
            let plain = drag((0, 0), (1, 5))
            if reporting {
                check(selected().isEmpty, "\(mode): a plain drag selects nothing")
                exactlySent(plain, "\(mode): a plain drag goes to the program as before")
            } else {
                check(selected() == firstSpan, "\(mode): a plain drag selects, got \(selected())")
                nothingSent("\(mode): plain drag")
                for _ in 0..<5 { output(frame) }
                output(sameRow)
                check(selected() == firstSpan, "\(mode): the selection outlives frames that leave its text as it was")
                output(overSecond)
                check(selected().isEmpty, "\(mode): a frame that changes selected text ends the selection")
            }
            check(view.allowMouseReporting, "\(mode): mouse reporting stays allowed after a plain drag")

            // ⇧-drag: a selection in every pane, nothing to the program,
            // mouse reporting off only for the drag.
            screen(reporting: reporting)
            view.mouseDown(with: mouse(.leftMouseDown, point((0, 0)), .shift))
            check(!view.allowMouseReporting, "\(mode): a ⇧ press turns mouse reporting off for the drag")
            for i in 0...6 {
                view.mouseDragged(with: mouse(.leftMouseDragged, point((i / 6, 5 * i / 6)), i < 3 ? .shift : []))
                check(!view.allowMouseReporting, "\(mode): still off while dragging, ⇧ let go or not")
            }
            view.mouseUp(with: mouse(.leftMouseUp, point((1, 5)), []))
            check(view.allowMouseReporting, "\(mode): back on at the release")
            check(selected() == firstSpan, "\(mode): ⇧-drag selects, got \(selected())")
            nothingSent("\(mode): ⇧-drag")
            for _ in 0..<5 { output(frame) }
            output(sameRow)
            check(selected() == firstSpan, "\(mode): the ⇧ selection outlives frames")
            // ⌘C copies what getSelection() returns (the pasteboard isn't touched here).
            check(view.getSelection() == firstSpan, "\(mode): ⌘C would copy the selection")
            output(overSecond)
            check(selected().isEmpty, "\(mode): changed text under the ⇧ selection ends it")

            // Output that changes selected cells while the selection is
            // being dragged out doesn't end it.
            screen(reporting: reporting)
            drag((0, 0), (1, 5), .shift, during: { i in if i == 3 { output(overSecond) } else { output(frame) } })
            check(selected() == rows[0] + "\nXYZon", "\(mode): changes during the drag are kept, got \(selected())")
            output(frame)
            check(selected() == rows[0] + "\nXYZon", "\(mode): and the selection stays after the release")
            output("\u{1b}[?2026h\u{1b}[2;1Habc\u{1b}[1;1H\u{1b}[?2026l")
            check(selected().isEmpty, "\(mode): a later change ends it")
            nothingSent("\(mode): ⇧-drag with output during it")
            if !reporting {
                screen(reporting: reporting)
                drag((0, 0), (1, 5), during: { i in if i == 3 { output(overSecond) } })
                check(selected() == rows[0] + "\nXYZon", "\(mode): a plain drag also keeps changes made during it")
                nothingSent("\(mode): plain drag with output during it")
            }

            // ⇧-drag from links: selected, nothing opened.
            for (row, label) in [(2, "web link"), (5, "file link")] {
                screen(reporting: reporting)
                drag((row, 1), (row + 1, 8), .shift)
                let expected = String(Array(row == 2 ? "oscweblink tail text" : rows[5]).dropFirst()) + "\n" + String(Array(rows[row + 1]).prefix(8))
                check(selected() == expected, "\(mode): ⇧-drag from a \(label) selects, got \(selected())")
                check(opened.isEmpty, "\(mode): ⇧-drag from a \(label) opens nothing, got \(opened)")
                nothingSent("\(mode): ⇧-drag from a \(label)")
                check(view.allowMouseReporting, "\(mode): restored after ⇧-drag from a \(label)")
            }
            screen(reporting: reporting)
            drag((4, 0), (3, 12), .shift)
            check(selected().hasPrefix(String(Array(rows[3]).dropFirst(12)) + "\n"), "\(mode): ⇧-drag ending on a URL selects, got \(selected())")
            check(opened.isEmpty, "\(mode): ⇧-drag ending on a URL opens nothing")

            // ⇧-click on a link: opens nothing; with a selection, extends it.
            for row in [2, 3, 5] {
                screen(reporting: reporting)
                click((row, 3), .shift)
                check(opened.isEmpty && selected().isEmpty, "\(mode): ⇧-click on the link in row \(row) opens nothing, got \(opened)")
                nothingSent("\(mode): ⇧-click on a link")
                check(view.allowMouseReporting, "\(mode): restored after ⇧-click")
                drag((0, 0), (0, 5), .shift)
                check(selected() == "alpha", "\(mode): a short ⇧ selection")
                click((row, 3), .shift)
                check(opened.isEmpty && selected().hasPrefix(rows[0] + "\n" + rows[1]) && selected().count > rows[0].count + rows[1].count,
                      "\(mode): ⇧-click on a link extends the selection to it, got \(selected())")
                nothingSent("\(mode): ⇧-click extending a selection")
            }
            // A ⇧ double click selects a word, on a link too.
            screen(reporting: reporting)
            click((4, 7), .shift, count: 2)
            check(selected() == "line" && opened.isEmpty, "\(mode): ⇧ double click selects a word, got \(selected())")
            nothingSent("\(mode): ⇧ double click")

            // Links' plain and ⌘ clicks: as before, and they end a selection.
            for (row, link) in [(2, webLink), (3, "https://example.invalid/plain"), (5, fileLink)] {
                for command in [false, true] {
                    screen(reporting: reporting)
                    drag((0, 0), (0, 5), .shift)
                    reset()
                    click((row, 3), command ? .command : [])
                    check(opened == [link] && clicks.map(\.commandHeld) == [command], "\(mode): a \(command ? "⌘" : "plain") click on \(link) opens it once, got \(opened)")
                    check(selected().isEmpty, "\(mode): and ends the selection")
                    nothingSent("\(mode): link click")
                }
            }

            // A plain drag from a link: a selection from the press once it
            // goes past 8pt, where the program doesn't take the mouse;
            // still the link's, opening nothing, where it does.
            for (row, link) in [(2, webLink), (5, fileLink)] {
                screen(reporting: reporting)
                let start = point((row, 2))
                view.mouseDown(with: mouse(.leftMouseDown, start, []))
                view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 5, y: start.y), []))
                check(selected().isEmpty, "\(mode): within 8pt it is still a click")
                for i in 1...4 { view.mouseDragged(with: mouse(.leftMouseDragged, point((row + (i > 2 ? 1 : 0), 2 + 2 * i)), [])) }
                view.mouseUp(with: mouse(.leftMouseUp, point((row + 1, 10)), []))
                check(opened.isEmpty, "\(mode): a drag from \(link) opens nothing, got \(opened)")
                nothingSent("\(mode): plain drag from a link")
                let fromPress = String(Array(row == 2 ? "oscweblink tail text" : rows[5]).dropFirst(2)) + "\n" + String(Array(rows[row + 1]).prefix(10))
                check(selected() == (reporting ? "" : fromPress), "\(mode): plain drag from \(link) selected \(selected())")
                check(view.allowMouseReporting, "\(mode): reporting untouched by a plain drag from a link")
                // A small wobble is still a click.
                screen(reporting: reporting)
                view.mouseDown(with: mouse(.leftMouseDown, start, []))
                view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 6, y: start.y + 3), []))
                view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: start.x + 6, y: start.y + 3), []))
                check(opened == [link] && selected().isEmpty, "\(mode): a press that moves within 8pt opens \(link)")
                nothingSent("\(mode): wobbling link click")
                // ⌘ and ⌥ drags from a link stay the link's, as before.
                for flags in [NSEvent.ModifierFlags.command, .option] {
                    screen(reporting: reporting)
                    drag((row, 2), (row + 1, 10), flags)
                    check(opened.isEmpty && selected().isEmpty, "\(mode): a \(flags == .command ? "⌘" : "⌥")-drag from a link selects and opens nothing")
                    nothingSent("\(mode): modified drag from a link")
                }
            }

            // ⌥ and ⌃, as before.
            screen(reporting: reporting)
            let optionDrag = drag((0, 0), (1, 5), .option)
            if reporting {
                check(selected().isEmpty, "\(mode): ⌥-drag selects nothing")
                exactlySent(optionDrag, "\(mode): ⌥-drag goes to the program as before")
            } else {
                check(selected() == firstSpan, "\(mode): ⌥-drag selects, as SwiftTerm did")
                nothingSent("\(mode): ⌥-drag")
            }
            screen(reporting: reporting)
            let controlClick = click((4, 3), .control)
            if reporting { exactlySent(controlClick, "\(mode): ⌃-click goes to the program as before") } else { nothingSent("\(mode): ⌃-click") }
            check(selected().isEmpty, "\(mode): ⌃-click selects nothing")
            screen(reporting: reporting)
            let doubleClick = click((4, 7), count: 2)
            if reporting {
                exactlySent(doubleClick, "\(mode): a double click goes to the program as before")
                check(selected().isEmpty, "\(mode): and selects nothing")
            } else {
                check(selected() == "line", "\(mode): a double click selects a word")
                for _ in 0..<3 { output(frame) }
                check(selected() == "line", "\(mode): and it outlives frames")
                nothingSent("\(mode): double click")
            }

            // What ends a selection: a press that doesn't select, a key, a
            // change of size, the other screen.
            for (flags, label) in [(NSEvent.ModifierFlags(), "plain"), (.option, "⌥"), (.command, "⌘")] {
                screen(reporting: reporting)
                drag((0, 0), (1, 5), .shift)
                reset()
                let reported = click((4, 3), flags)
                check(selected().isEmpty, "\(mode): a \(label) click ends the selection")
                if reporting { exactlySent(flags == .command ? sgr(0, (4, 3), "M") + sgr(0, (4, 3), "m") : reported, "\(mode): the \(label) click goes on to the program") }
                else { nothingSent("\(mode): \(label) click") }
            }
            screen(reporting: reporting)
            drag((0, 0), (1, 5), .shift)
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
            check(selected().isEmpty, "\(mode): a key ends the selection")
            exactlySent(Array("a".utf8), "\(mode): and is typed")
            screen(reporting: reporting)
            drag((0, 0), (1, 5), .shift)
            view.setFrameSize(NSSize(width: 700, height: 420))
            check(selected().isEmpty, "\(mode): a change of size ends the selection")
            view.setFrameSize(container.bounds.size)
            screen(reporting: reporting)
            drag((0, 0), (1, 5), .shift)
            output("\u{1b}[?1049l")
            check(selected().isEmpty && !view.getTerminal().isCurrentBufferAlternate, "\(mode): leaving the alternate screen ends the selection")
            output("\u{1b}[2J\u{1b}[H" + rows[0] + "\r\n" + rows[1] + "\u{1b}[H")
            reset()
            drag((0, 0), (1, 5), .shift)
            check(selected() == firstSpan, "\(mode): a selection on the normal screen, got \(selected())")
            output(frame)
            check(selected() == firstSpan, "\(mode): kept through output there too")
            output("\u{1b}[?1049h")
            check(selected().isEmpty, "\(mode): going to the alternate screen ends it")

            // A program that asked for ⇧ (XTSHIFTESCAPE) gets it.
            screen(reporting: reporting)
            output("\u{1b}[>1s")
            check(view.getTerminal().mouseShiftCapture, "XTSHIFTESCAPE on")
            view.mouseDown(with: mouse(.leftMouseDown, point((0, 0)), .shift))
            check(view.allowMouseReporting, "\(mode): a ⇧ press the program asked for leaves reporting on")
            view.mouseUp(with: mouse(.leftMouseUp, point((0, 0)), .shift))
            reset()
            let shifted = drag((0, 0), (1, 5), .shift)
            if reporting {
                check(selected().isEmpty, "\(mode): with XTSHIFTESCAPE ⇧-drag selects nothing")
                exactlySent(shifted, "\(mode): with XTSHIFTESCAPE ⇧-drag goes to the program")
            } else {
                check(selected() == firstSpan, "\(mode): with XTSHIFTESCAPE ⇧-drag is SwiftTerm's own selection, as before")
                nothingSent("\(mode): ⇧-drag with XTSHIFTESCAPE")
            }
            reset()
            click((2, 3), .shift)
            check(opened == [webLink], "\(mode): with XTSHIFTESCAPE a ⇧-click on a link is the link's, as before")
            nothingSent("\(mode): ⇧-click on a link with XTSHIFTESCAPE")

            // Mouse reporting comes back without a release: at the next
            // press, and when the view leaves its window.
            screen(reporting: reporting)
            view.mouseDown(with: mouse(.leftMouseDown, point((0, 0)), .shift))
            check(!view.allowMouseReporting, "\(mode): off for the ⇧ press")
            reset()
            view.mouseDown(with: mouse(.leftMouseDown, point((4, 3)), []))
            check(view.allowMouseReporting, "\(mode): back on at the next press")
            if reporting { exactlySent(sgr(0, (4, 3), "M"), "\(mode): which goes to the program") } else { nothingSent("\(mode): next press") }
            view.mouseUp(with: mouse(.leftMouseUp, point((4, 3)), []))
            view.mouseDown(with: mouse(.leftMouseDown, point((0, 0)), .shift))
            view.removeFromSuperview()
            check(view.allowMouseReporting && !view.followsWheel, "\(mode): back on, and the wheel let go, once out of the window")
            container.addSubview(view, positioned: .below, relativeTo: cover)
            check(view.followsWheel, "\(mode): the wheel followed again in the window")
            view.mouseUp(with: mouse(.leftMouseUp, point((0, 0)), .shift))
            check(view.allowMouseReporting, "\(mode): a late release leaves it on")
        }

        // The wheel. Events as the window server makes them: CG scroll
        // events carrying this window and a place in it, sent through
        // NSApp.sendEvent, which hands them to local event monitors.
        typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { preconditionFailure("CGEventSetWindowLocation") }
        let setWindowLocation = unsafeBitCast(symbol, to: SetWindowLocation.self)
        func wheel(_ amount: Int32, precise: Bool = false, at: CGPoint, flags: CGEventFlags = [], in target: NSWindow = window, from source: NSView = view) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)!
            event.flags = flags
            event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(target.windowNumber))
            let inWindow = source.convert(at, to: nil)
            setWindowLocation(event, CGPoint(x: inWindow.x, y: target.frame.height - inWindow.y))
            return NSEvent(cgEvent: event)!
        }
        let wheelAt = point((7, 12))
        let probe = wheel(2, at: wheelAt)
        check(probe.window === window && probe.type == .scrollWheel && abs(probe.locationInWindow.x - view.convert(wheelAt, to: nil).x) < 0.5, "a wheel event in this window, where it was made")
        let up = sgr(64, (7, 12), "M"), down = sgr(65, (7, 12), "M")
        screen(reporting: false)
        NSApp.sendEvent(wheel(2, at: wheelAt))
        exactlySent(up + up, "mouse reporting off: two notches up are two wheel reports where the pointer is")
        NSApp.sendEvent(wheel(-1, at: wheelAt))
        exactlySent(down, "mouse reporting off: one notch down")
        NSApp.sendEvent(wheel(1, at: wheelAt, flags: .maskAlternate))
        exactlySent(sgr(72, (7, 12), "M"), "⌥ goes with the report")
        NSApp.sendEvent(wheel(1, at: wheelAt, flags: .maskControl))
        exactlySent(sgr(80, (7, 12), "M"), "⌃ goes with the report")
        let edge = CGPoint(x: view.bounds.maxX - 100, y: 2)
        NSApp.sendEvent(wheel(1, at: edge))
        exactlySent(sgr(64, (view.getTerminal().rows - 1, Int(edge.x / cell.width)), "M"), "the bottom row")
        // A trackpad's points add up to lines.
        let half = Int32(cell.height * 0.6)
        check(view.reportWheel(wheel(half, precise: true, at: wheelAt)), "less than a line is taken")
        nothingSent("less than a line")
        check(view.reportWheel(wheel(half, precise: true, at: wheelAt)), "and more of it")
        exactlySent(up, "makes one line")
        // Left to SwiftTerm.
        let declined: [(NSEvent, String)] = [
            (wheel(1, at: wheelAt, flags: .maskShift), "⇧"),
            (wheel(1, at: CGPoint(x: 900, y: 200)), "over a view drawn over the terminal"),
        ]
        for (event, label) in declined {
            check(!view.reportWheel(event), "the wheel \(label) is left to SwiftTerm")
            NSApp.sendEvent(event)
            nothingSent("the wheel \(label)")
        }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        let otherContent = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 420))
        other.contentView = otherContent
        check(!view.reportWheel(wheel(1, at: wheelAt, in: other, from: otherContent)), "a wheel in another window is left alone")
        NSApp.sendEvent(wheel(1, at: wheelAt, in: other, from: otherContent))
        nothingSent("the wheel in another window")
        other.close()
        view.isHidden = true
        check(!view.reportWheel(wheel(1, at: wheelAt)), "a hidden terminal is left alone")
        view.isHidden = false
        // ⇧ is SwiftTerm's, as before, when the attach had mouse reporting
        // on (AppKit makes a ⇧ wheel a sideways one).
        let shiftWheel = wheel(1, at: wheelAt, flags: .maskShift)
        reset()
        view.scrollWheel(with: shiftWheel)
        let shiftOff = sent
        _ = received()
        // With mouse reporting on, SwiftTerm reports the wheel itself, as
        // before, counting the same lines as the monitor does.
        screen(reporting: true)
        view.scrollWheel(with: shiftWheel)
        check(sent == shiftOff, "⇧ wheel: SwiftTerm does what it did with mouse reporting on, \(shown(shiftOff)) / \(shown(sent))")
        reset()
        let sequence: [(Int32, Bool)] = [(3, false), (-2, false), (Int32(cell.height * 0.4), true), (Int32(cell.height * 0.4), true), (Int32(cell.height * 0.4), true), (Int32(-cell.height * 2.5), true), (1, false)]
        for (amount, precise) in sequence {
            check(!view.reportWheel(wheel(amount, precise: precise, at: wheelAt)), "mouse reporting on: the wheel is SwiftTerm's")
        }
        reset()
        for (amount, precise) in sequence { view.scrollWheel(with: wheel(amount, precise: precise, at: wheelAt)) }
        let swiftTerms = sent
        check(!swiftTerms.isEmpty, "SwiftTerm reports the wheel")
        _ = received()
        screen(reporting: false)
        for (amount, precise) in sequence { NSApp.sendEvent(wheel(amount, precise: precise, at: wheelAt)) }
        exactlySent(swiftTerms, "the monitor's reports are SwiftTerm's, line for line")
        // During a ⇧ press, which turns mouse reporting off to keep its
        // selection, the wheel goes where it went before, not as ↑ and ↓.
        view.mouseDown(with: mouse(.leftMouseDown, point((0, 0)), .shift))
        NSApp.sendEvent(wheel(1, at: wheelAt))
        exactlySent(up, "mouse reporting off: the wheel during a ⇧ press still goes to herdr")
        view.mouseUp(with: mouse(.leftMouseUp, point((0, 0)), .shift))
        screen(reporting: true)
        view.scrollWheel(with: wheel(2, at: wheelAt))
        let programs = sent
        reset()
        view.mouseDown(with: mouse(.leftMouseDown, point((0, 0)), .shift))
        check(!view.allowMouseReporting, "a ⇧ press")
        NSApp.sendEvent(wheel(2, at: wheelAt))
        check(programs == up + up, "SwiftTerm reports two notches, got \(shown(programs))")
        exactlySent(programs, "mouse reporting on: the wheel during a ⇧ press is reported to the program as SwiftTerm reports it")
        view.mouseUp(with: mouse(.leftMouseUp, point((0, 0)), .shift))
        nothingSent("the ⇧ release")
        screen(reporting: false)
        // The normal screen keeps SwiftTerm's own scrollback.
        output("\u{1b}[?1049l")
        check(!view.reportWheel(wheel(1, at: wheelAt)), "the normal screen's wheel is SwiftTerm's")
        NSApp.sendEvent(wheel(1, at: wheelAt))
        nothingSent("the wheel on the normal screen")
        output("\u{1b}[?1049h")
        // Out of the window, no monitor.
        view.removeFromSuperview()
        NSApp.sendEvent(wheel(1, at: wheelAt))
        nothingSent("the wheel with the terminal out of the window")
        container.addSubview(view, positioned: .below, relativeTo: cover)
        NSApp.sendEvent(wheel(1, at: wheelAt))
        exactlySent(up, "the wheel once it is back")

        // The attach's output reaches the view through the view model,
        // which keeps the selection.
        let pane = FocusReportingTerminalView(frame: container.bounds)
        pane.terminalDelegate = coordinator
        view.removeFromSuperview()
        container.addSubview(pane, positioned: .below, relativeTo: cover)
        let session = FrameSession(first: "\u{1b}[?1049h\u{1b}[2J\u{1b}[H" + rows[0] + "\r\n" + rows[1] + "\u{1b}[H")
        let model = AgentTerminalViewModel(makeSession: { session })
        model.attach(terminalView: pane)
        await model.start()
        check(model.connectionState == .connected, "the session is attached")
        func paneMouse(_ type: NSEvent.EventType, _ at: (Int, Int), _ flags: NSEvent.ModifierFlags) -> NSEvent {
            eventNumber += 1
            return NSEvent.mouseEvent(with: type, location: pane.convert(point(at), to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: 1, pressure: 1)!
        }
        pane.mouseDown(with: paneMouse(.leftMouseDown, (0, 0), []))
        for i in 0...6 { pane.mouseDragged(with: paneMouse(.leftMouseDragged, (i / 6, 5 * i / 6), [])) }
        pane.mouseUp(with: paneMouse(.leftMouseUp, (1, 5), []))
        check(pane.getSelection() == firstSpan, "a selection in the attached pane")
        func until(_ marker: String) async {
            for _ in 0..<500 {
                if let line = pane.getTerminal().getLine(row: 8), line.translateToString(trimRight: true) == marker { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("output \(marker) never arrived")
        }
        for n in 0..<5 { await session.push("\u{1b}[?2026h\u{1b}[9;1Hframe\(n)\u{1b}[1;1H\u{1b}[?2026l") }
        await until("frame4")
        check(pane.getSelection() == firstSpan, "the selection outlives the session's frames")
        await session.push(overSecond + "\u{1b}[9;1H\u{1b}[2Klast\u{1b}[1;1H")
        await until("last")
        check((pane.getSelection() ?? "").isEmpty, "and ends when they change its text")
        model.stop()
        nothingSent("the view model's pane")
        print("PASS \(checks) selection checks: plain, ⇧, ⌥, ⌃ and ⌘ presses and drags with mouse reporting on and off, links, XTSHIFTESCAPE, selections through output and what ends them, mouse reporting restored, wheel reports from the event monitor; real SwiftTerm, owned PTY, never-shown windows; no user GUI, herdr or SSH")
    }
}
