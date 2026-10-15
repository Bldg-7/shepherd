import AppKit
import SwiftTerm

@main @MainActor enum TerminalKeyTests {
    static var checks = 0
    static func check(_ b: Bool, _ why: String) { precondition(b, why); checks += 1 }
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FocusReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = view
        _ = window.makeFirstResponder(view)
        var sent: [UInt8] = []
        let coordinator = TerminalHostView.Coordinator(onInput: { sent += $0 }, onResize: { _, _ in }, onOpenLink: nil)
        view.terminalDelegate = coordinator
        // A real key-down, through SwiftTerm's keyDown and the system's key
        // bindings (the runner's private HOME has no DefaultKeyBinding.dict).
        func press(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> [UInt8] {
            sent = []
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
            return sent
        }
        let backspace = "\u{7f}", left = "\u{f702}", right = "\u{f703}"
        let esc: UInt8 = 0x1b, csi: [UInt8] = [0x1b, 0x5b]
        // Legacy keys, and the same with the kitty keyboard protocol pushed
        // (CSI > 1 u, disambiguate), as Claude Code asks for it.
        for kitty in [false, true] {
            if kitty { view.feed(text: "\u{1b}[>1u") }
            let mode = kitty ? "kitty" : "legacy"
            check(press(backspace, code: 51, .command) == [0x15], "\(mode): ⌘⌫ sends Ctrl-U")
            check(press(backspace, code: 51, [.command, .capsLock]) == [0x15], "\(mode): ⌘⌫ with Caps Lock sends Ctrl-U")
            check(press(backspace, code: 51, [.shift, .command]) == [0x15], "\(mode): ⇧⌘⌫, the same command to macOS, sends Ctrl-U")
            // Everything else is SwiftTerm's, as before: ⌫ and legacy ⌘← and
            // ⌘→ reach its doCommand(by:) as deleteBackward: and
            // moveToLeft/RightEndOfLine:.
            check(press(backspace, code: 51) == [0x7f], "\(mode): ⌫ still sends DEL")
            check(press(backspace, code: 51, .option) == (kitty ? csi + Array("127;3u".utf8) : [esc, 0x7f]), "\(mode): ⌥⌫ is still SwiftTerm's")
            check(press("a", code: 0) == Array("a".utf8), "\(mode): a letter is still typed")
            check(press(left, code: 123, [.command, .numericPad, .function]) == (kitty ? csi + Array("1;9D".utf8) : [esc, 0x62]), "\(mode): ⌘← is still SwiftTerm's")
            check(press(right, code: 124, [.command, .numericPad, .function]) == (kitty ? csi + Array("1;9C".utf8) : [esc, 0x66]), "\(mode): ⌘→ is still SwiftTerm's")
        }
        view.feed(text: "\u{1b}[<u")
        check(press(backspace, code: 51, .command) == [0x15], "⌘⌫ sends Ctrl-U again once the kitty keyboard is popped")
        print("PASS \(checks) real SwiftTerm key-down checks: ⌘⌫ sends Ctrl-U in legacy and kitty keyboard modes, other keys unchanged; no user terminal/GUI")
    }
}
