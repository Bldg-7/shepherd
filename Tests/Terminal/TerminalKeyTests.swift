import AppKit
import SwiftUI
import SwiftTerm

@main @MainActor enum TerminalKeyTests {
    static var checks = 0
    static func check(_ b: Bool, _ why: String) { precondition(b, why); checks += 1 }

    /// The bytes a terminal view hands its delegate, and each of its writes.
    final class Sink {
        var bytes: [UInt8] = []
        var writes: [[UInt8]] = []
        lazy var coordinator = TerminalHostView.Coordinator(onInput: { [unowned self] in self.bytes += $0; self.writes.append(Array($0)) }, onResize: { _, _ in }, onOpenLink: nil)
    }

    /// A never-shown window; nothing here orders it front or makes it key.
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A key event; `ignoringModifiers` is its `charactersIgnoringModifiers`
    /// where they differ from `characters`, as for ⌃B: "\u{2}" and "b".
    static func event(_ characters: String, ignoringModifiers: String? = nil, code: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow, repeating: Bool = false, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: repeating, keyCode: code)!
    }

    /// AppKit's order for a key-down: the key window's views are offered it
    /// as a key equivalent first, and the first responder gets `keyDown`
    /// only if none of them took it. Every key-down is offered here, which
    /// is at least every one AppKit offers. Whether a key equivalent took it.
    static func deliver(_ event: NSEvent, to window: NSWindow) -> Bool {
        if window.performKeyEquivalent(with: event) { return true }
        window.firstResponder?.keyDown(with: event)
        return false
    }

    static let left = "\u{f702}", right = "\u{f703}", up = "\u{f700}", down = "\u{f701}"
    static let home = "\u{f729}", end = "\u{f72b}", forwardDelete = "\u{f728}", backspace = "\u{7f}"
    static let arrow: NSEvent.ModifierFlags = [.numericPad, .function]
    static let csi: [UInt8] = [0x1b, 0x5b]
    static func csi(_ s: String) -> [UInt8] { csi + Array(s.utf8) }

    /// Every key whose bytes must not change: ⌘ with ⇧, ⌃ or ⌥ on the
    /// arrows, the arrows without ⌘, ⌘ on the other arrows and on the
    /// delete keys, and a letter.
    static let otherKeys: [(name: String, characters: String, code: UInt16, flags: NSEvent.ModifierFlags)] = [
        ("⇧⌘←", left, 123, arrow.union([.shift, .command])), ("⇧⌘→", right, 124, arrow.union([.shift, .command])),
        ("⌥⌘←", left, 123, arrow.union([.option, .command])), ("⌃⌘→", right, 124, arrow.union([.control, .command])),
        ("⌥←", left, 123, arrow.union(.option)), ("⌥→", right, 124, arrow.union(.option)),
        ("⌃←", left, 123, arrow.union(.control)), ("⌃→", right, 124, arrow.union(.control)),
        ("←", left, 123, arrow), ("→", right, 124, arrow),
        ("⌘↑", up, 126, arrow.union(.command)), ("⌘↓", down, 125, arrow.union(.command)),
        ("⌘⌫", backspace, 51, .command), ("⇧⌘⌫", backspace, 51, [.shift, .command]), ("⌥⌫", backspace, 51, .option),
        ("⌫", backspace, 51, []), ("⌘⌦", forwardDelete, 117, [.function, .command]), ("a", "a", 0, []),
    ]

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = makeWindow()
        defer { window.close() }
        let view = FocusReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = view
        _ = window.makeFirstResponder(view)
        let sink = Sink()
        view.terminalDelegate = sink.coordinator
        // A real key-down in AppKit's order, through SwiftTerm's keyDown and
        // the system's key bindings (the runner's private HOME has no
        // DefaultKeyBinding.dict): whether a key equivalent took it, and
        // what was sent.
        func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false) -> (taken: Bool, bytes: [UInt8]) {
            sink.bytes = []
            let taken = deliver(event(characters, code: code, flags, in: window, repeating: repeating), to: window)
            return (taken, sink.bytes)
        }
        // The same key-down straight to SwiftTerm's keyDown: what every key
        // sent before, when nothing in the view took a key equivalent.
        func swiftTerm(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> [UInt8] {
            sink.bytes = []
            view.keyDown(with: event(characters, code: code, flags, in: window))
            return sink.bytes
        }
        let esc: UInt8 = 0x1b
        // Legacy keys, and the same with the kitty keyboard protocol pushed:
        // CSI > 1 u (disambiguate) and > 5 u, the ways Claude Code asks for
        // it, and > 7 u, as Pi does.
        for push in [nil, ">1u", ">5u", ">7u"] as [String?] {
            if let push { view.feed(text: "\u{1b}[" + push) }
            let kitty = push != nil
            let mode = push ?? "legacy"
            check(press(backspace, code: 51, .command) == (false, [0x15]), "\(mode): ⌘⌫ sends Ctrl-U")
            check(press(backspace, code: 51, [.command, .capsLock]) == (false, [0x15]), "\(mode): ⌘⌫ with Caps Lock sends Ctrl-U")
            check(press(backspace, code: 51, [.shift, .command]) == (false, [0x15]), "\(mode): ⇧⌘⌫, the same command to macOS, sends Ctrl-U")
            check(press(backspace, code: 51) == (false, [0x7f]), "\(mode): ⌫ still sends DEL")
            check(press(backspace, code: 51, .option) == (false, kitty ? csi("127;3u") : [esc, 0x7f]), "\(mode): ⌥⌫ is still SwiftTerm's")
            check(press("a", code: 0) == (false, Array("a".utf8)), "\(mode): a letter is still typed")
            let commandLeft = press(left, code: 123, arrow.union(.command)), commandRight = press(right, code: 124, arrow.union(.command))
            if kitty {
                // SwiftTerm alone sends super+← and super+→, which Pi binds
                // to nothing; the terminal sends the Home and End keys
                // instead, as SwiftTerm encodes them for this mode.
                check(swiftTerm(left, code: 123, arrow.union(.command)) == csi("1;9D"), "\(mode): SwiftTerm alone sends ⌘← as super+←")
                check(commandLeft == (true, csi("H")), "\(mode): ⌘← is taken as a key equivalent and sends Home")
                check(commandRight == (true, csi("F")), "\(mode): ⌘→ is taken as a key equivalent and sends End")
                check(commandLeft.bytes == press(home, code: 115, .function).bytes, "\(mode): ⌘← sends what the Home key sends")
                check(commandRight.bytes == press(end, code: 119, .function).bytes, "\(mode): ⌘→ sends what the End key sends")
                check(press(home, code: 115, .function).taken == false, "\(mode): the Home key itself is no key equivalent")
            } else {
                // macOS makes them moveToLeft/RightEndOfLine:, which
                // SwiftTerm's doCommand(by:) sends as ESC b and ESC f.
                check(commandLeft == (false, [esc, 0x62]), "\(mode): ⌘← is still SwiftTerm's ESC b")
                check(commandRight == (false, [esc, 0x66]), "\(mode): ⌘→ is still SwiftTerm's ESC f")
            }
            for key in otherKeys {
                let pressed = press(key.characters, code: key.code, key.flags)
                check(!pressed.taken, "\(mode): \(key.name) is no key equivalent")
                check(pressed.bytes == swiftTerm(key.characters, code: key.code, key.flags), "\(mode): \(key.name) sends what SwiftTerm sends for it")
            }
            if kitty {
                check(press(left, code: 123, arrow.union([.shift, .command])).bytes == csi("1;10D"), "\(mode): ⇧⌘← is still shift+super+←")
                check(press(left, code: 123, arrow.union(.option)).bytes == csi("1;3D"), "\(mode): ⌥← is still alt+←")
                check(press(right, code: 124, arrow.union(.control)).bytes == csi("1;5C"), "\(mode): ⌃→ is still ctrl+→")
                check(press(up, code: 126, arrow.union(.command)).bytes == csi("1;9A"), "\(mode): ⌘↑ is still super+↑")
                check(press(forwardDelete, code: 117, [.function, .command]).bytes == csi("3;9~"), "\(mode): ⌘⌦ is still super+Delete")
            }
            // Ctrl+B, which herdr's attach keeps as its prefix: the view
            // sends what SwiftTerm makes of it, unchanged, and the app writes
            // to the attach (HerdrAttachInput) each write that herdr takes as
            // the prefix twice and every other one as it is. A release is
            // sent at all only with event types (> 7 u), and a repeat is
            // reported as such only then; otherwise it is another press.
            let events = push == ">7u"
            let ctrlB: [(name: String, ignoring: String, flags: NSEvent.ModifierFlags, repeating: Bool, sent: [UInt8], twice: Bool)] = [
                ("⌃B", "b", .control, false, kitty ? csi("98;5u") : [0x02], true),
                ("⌃B with Caps Lock", "b", [.control, .capsLock], false, kitty ? csi("98;69u") : [0x02], true),
                ("⌃B repeated", "b", .control, true, kitty ? csi(events ? "98;5:2u" : "98;5u") : [0x02], !events),
                ("⌃⌥B", "b", [.control, .option], false, kitty ? csi("98;7u") : [esc, 0x62], false),
                // Legacy has no ⌃⇧B of its own; with alternates (> 5 u, > 7 u) the
                // shifted key is the ⌃⇧B event's characters, 0x02.
                ("⌃⇧B", "B", [.control, .shift], false, kitty ? csi(push == ">1u" ? "98;6u" : "98:2;6u") : [0x02], !kitty),
            ]
            for key in ctrlB {
                sink.bytes = []
                sink.writes = []
                let taken = deliver(event("\u{2}", ignoringModifiers: key.ignoring, code: 11, key.flags, in: window, repeating: key.repeating), to: window)
                check(!taken, "\(mode): \(key.name) is no key equivalent")
                check(sink.bytes == key.sent, "\(mode): \(key.name) sends what SwiftTerm makes of it")
                let written = sink.writes.flatMap { HerdrAttachInput.escaped($0[...]) }
                check(written == (key.twice ? key.sent + key.sent : key.sent), "\(mode): \(key.name) is written to the attach \(key.twice ? "twice" : "as it is")")
            }
            sink.bytes = []
            sink.writes = []
            window.firstResponder?.keyUp(with: event("\u{2}", ignoringModifiers: "b", code: 11, .control, in: window, type: .keyUp))
            check(sink.bytes == (events ? csi("98;5:3u") : []), "\(mode): letting go of ⌃B sends \(events ? "its release" : "nothing")")
            check(sink.writes.flatMap { HerdrAttachInput.escaped($0[...]) } == sink.bytes, "\(mode): ⌃B's release is written to the attach as it is")
            if let push {
                // Auto-repeat goes through as the Home or End key's repeat:
                // reported as such only where the program asked for event
                // types (flag 2, in > 7 u).
                let repeated = push == ">7u"
                check(press(left, code: 123, arrow.union(.command), repeating: true) == (true, csi(repeated ? "1;1:2H" : "H")), "\(mode): a repeated ⌘← is Home's repeat")
                check(press(right, code: 124, arrow.union(.command), repeating: true) == (true, csi(repeated ? "1;1:2F" : "F")), "\(mode): a repeated ⌘→ is End's repeat")
                check(press(left, code: 123, arrow.union(.command), repeating: true).bytes == press(home, code: 115, .function, repeating: true).bytes, "\(mode): a repeated ⌘← sends what a repeated Home sends")
                // Caps Lock stays on the key, as on a real Home or End key,
                // which SwiftTerm sends with the Caps Lock modifier (64) in
                // every kitty mode; Pi leaves lock modifiers out of matching.
                check(press(left, code: 123, arrow.union([.command, .capsLock])) == (true, csi("1;65H")), "\(mode): ⌘← with Caps Lock sends Home with Caps Lock")
                check(press(right, code: 124, arrow.union([.command, .capsLock])) == (true, csi("1;65F")), "\(mode): ⌘→ with Caps Lock sends End with Caps Lock")
                check(press(left, code: 123, arrow.union([.command, .capsLock])).bytes == press(home, code: 115, [.function, .capsLock]).bytes, "\(mode): ⌘← with Caps Lock sends what Home with Caps Lock sends")
                check(press(right, code: 124, arrow.union([.command, .capsLock])).bytes == press(end, code: 119, [.function, .capsLock]).bytes, "\(mode): ⌘→ with Caps Lock sends what End with Caps Lock sends")
                // Popped, the keys are SwiftTerm's again.
                view.feed(text: "\u{1b}[<u")
                check(press(left, code: 123, arrow.union(.command)) == (false, [esc, 0x62]), "\(mode) popped: ⌘← is ESC b again")
                check(press(right, code: 124, arrow.union(.command)) == (false, [esc, 0x66]), "\(mode) popped: ⌘→ is ESC f again")
            }
        }
        check(press(backspace, code: 51, .command) == (false, [0x15]), "⌘⌫ sends Ctrl-U again once the kitty keyboard is popped")

        twoTerminals()
        hostingView()
        print("PASS \(checks) real SwiftTerm key-down checks: ⌘⌫ sends Ctrl-U in legacy and kitty keyboard modes; ⌘←/⌘→ send Home/End with the kitty keyboard on (> 1 u, > 5 u, > 7 u; repeat and Caps Lock as Home/End) and ESC b/ESC f with it off or popped; other keys unchanged; ⌃B sent as SwiftTerm sends it and its presses written twice to herdr's attach, its repeats (with event types), release, ⌃⌥B and kitty ⌃⇧B as they are; only the terminal with the keyboard takes ⌘←/⌘→, in a plain window and in NSHostingView; no user terminal/GUI")
    }

    /// Two terminals in one window: only the one with the keyboard takes
    /// ⌘← or ⌘→, by its own mode, and with neither having it none does.
    static func twoTerminals() {
        let window = makeWindow()
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = container
        let first = FocusReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        let second = FocusReportingTerminalView(frame: NSRect(x: 320, y: 0, width: 320, height: 320))
        let firstSink = Sink(), secondSink = Sink()
        first.terminalDelegate = firstSink.coordinator
        second.terminalDelegate = secondSink.coordinator
        container.addSubview(first)
        container.addSubview(second)
        func commandLeft() -> Bool {
            firstSink.bytes = []
            secondSink.bytes = []
            return deliver(event(left, code: 123, arrow.union(.command), in: window), to: window)
        }
        // The second has the kitty keyboard on, the first doesn't.
        second.feed(text: "\u{1b}[>7u")
        _ = window.makeFirstResponder(first)
        check(commandLeft() == false && firstSink.bytes == [0x1b, 0x62] && secondSink.bytes.isEmpty, "two terminals: the one without the keyboard doesn't take ⌘←, though its kitty keyboard is on")
        _ = window.makeFirstResponder(second)
        check(commandLeft() == true && secondSink.bytes == csi("H") && firstSink.bytes.isEmpty, "two terminals: the one with the keyboard and the kitty keyboard on sends Home")
        first.feed(text: "\u{1b}[>7u")
        _ = window.makeFirstResponder(first)
        check(commandLeft() == true && firstSink.bytes == csi("H") && secondSink.bytes.isEmpty, "two terminals: with both on, only the one with the keyboard sends Home")
        _ = window.makeFirstResponder(nil)
        check(!(window.firstResponder is TerminalView), "two terminals: neither has the keyboard")
        let key = event(left, code: 123, arrow.union(.command), in: window)
        firstSink.bytes = []
        secondSink.bytes = []
        check(window.performKeyEquivalent(with: key) == false, "no terminal with the keyboard: the window's views take no ⌘←")
        check(first.performKeyEquivalent(with: key) == false && second.performKeyEquivalent(with: key) == false, "no terminal with the keyboard: neither terminal takes ⌘←")
        check(firstSink.bytes.isEmpty && secondSink.bytes.isEmpty, "no terminal with the keyboard: nothing is sent")
    }

    /// The production TerminalHostView in SwiftUI's NSHostingView, as the
    /// app has it: the key equivalent reaches the terminal through it.
    static func hostingView() {
        let window = makeWindow()
        defer { window.close() }
        let sink = Sink()
        var created: TerminalView?
        let host = NSHostingView(rootView: TerminalHostView(onCreate: { created = $0 }, onInput: { sink.bytes += $0 }, onResize: { _, _ in })
            .frame(width: 640, height: 320))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let view = created as? FocusReportingTerminalView else { preconditionFailure("NSHostingView: TerminalHostView made no FocusReportingTerminalView") }
        check(view.isDescendant(of: host), "NSHostingView: the terminal is inside the hosting view")
        _ = window.makeFirstResponder(view)
        check(window.firstResponder === view, "NSHostingView: the terminal has the keyboard")
        func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> (taken: Bool, bytes: [UInt8]) {
            sink.bytes = []
            let taken = deliver(event(characters, code: code, flags, in: window), to: window)
            return (taken, sink.bytes)
        }
        check(press(left, code: 123, arrow.union(.command)) == (false, [0x1b, 0x62]), "NSHostingView: ⌘← is ESC b with the kitty keyboard off")
        view.feed(text: "\u{1b}[>7u")
        check(press(left, code: 123, arrow.union(.command)) == (true, csi("H")), "NSHostingView: ⌘← sends Home with the kitty keyboard on")
        check(press(right, code: 124, arrow.union(.command)) == (true, csi("F")), "NSHostingView: ⌘→ sends End with the kitty keyboard on")
        check(press(left, code: 123, arrow.union([.shift, .command])) == (false, csi("1;10D")), "NSHostingView: ⇧⌘← is still shift+super+←")
        check(press(backspace, code: 51, .command) == (false, [0x15]), "NSHostingView: ⌘⌫ still sends Ctrl-U")
        view.feed(text: "\u{1b}[<u")
        check(press(right, code: 124, arrow.union(.command)) == (false, [0x1b, 0x66]), "NSHostingView: ⌘→ is ESC f again once popped")
    }
}
