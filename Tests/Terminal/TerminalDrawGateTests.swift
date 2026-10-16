import AppKit
import ObjectiveC
import SwiftTerm

@main @MainActor enum TerminalDrawGateTests {
    static var checks = 0
    nonisolated(unsafe) static var draws = 0

    /// Counts SwiftTerm's own draw(_:), which the production view inherits.
    static func countDraws() {
        let selector = #selector(NSView.draw(_:))
        guard let method = class_getInstanceMethod(TerminalView.self, selector) else { preconditionFailure("TerminalView.draw") }
        typealias Draw = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Draw.self)
        let counted: @convention(block) (AnyObject, NSRect) -> Void = { view, rect in draws += 1; original(view, selector, rect) }
        method_setImplementation(method, imp_implementationWithBlock(counted))
    }
    static func check(_ b: Bool, _ why: String) { precondition(b, why); checks += 1 }
    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    static func main() {
        // The decision alone.
        var gate = TerminalDrawGate()
        check(gate.request(), "a visible terminal draws")
        check(!gate.update(visible: false), "hiding draws nothing")
        check(!gate.request() && !gate.request() && gate.pending, "redraws while hidden are noted, not drawn")
        check(!gate.update(visible: false), "still hidden, still nothing")
        check(gate.update(visible: true), "visible again: one whole redraw")
        check(!gate.pending && gate.request(), "then draws as before")
        check(!gate.update(visible: true), "no second whole redraw")
        _ = gate.update(visible: false)
        check(!gate.update(visible: true), "nothing asked while hidden, nothing redrawn")
        typealias Gate = TerminalDrawGate
        check(Gate.isVisible(inWindow: true, occlusionVisible: true, miniaturized: false, applicationHidden: false), "a window on screen draws")
        check(!Gate.isVisible(inWindow: true, occlusionVisible: false, miniaturized: false, applicationHidden: false), "covered or on another Space")
        check(!Gate.isVisible(inWindow: true, occlusionVisible: true, miniaturized: true, applicationHidden: false), "minimized")
        check(!Gate.isVisible(inWindow: true, occlusionVisible: true, miniaturized: false, applicationHidden: true), "app hidden")
        check(Gate.isVisible(inWindow: false, occlusionVisible: false, miniaturized: false, applicationHidden: false), "outside a window nothing is held")

        // The production view in a never-shown window, which can't be seen,
        // counting SwiftTerm's actual draws.
        countDraws()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = FocusReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        check(view.drawGate.visible, "outside a window redraws are not held")
        window.contentView = view
        _ = window.makeFirstResponder(view)
        check(!window.occlusionState.contains(.visible) && !view.drawGate.visible, "a window that can't be seen holds redraws back")
        settle()
        let before = draws
        for line in 0..<5 { view.feed(text: "while hidden \(line)\r\n"); settle() }
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
        settle()
        check(draws == before && view.drawGate.pending, "output while hidden is noted, not drawn (\(draws - before) draws)")
        let line = view.getTerminal().getLine(row: 4)?.translateToString(trimRight: true) ?? ""
        check(line == "while hidden 4", "the bytes still reach SwiftTerm (\(line))")
        check(window.firstResponder === view && !view.isHidden, "never hidden: keeps the keyboard")
        view.updateDrawing(visible: true)
        settle()
        check(draws == before + 1 && !view.drawGate.pending, "visible again: drawn once (\(draws - before) draws)")
        view.feed(text: "visible\r\n")
        settle()
        check(draws == before + 2, "a visible terminal draws output as before")
        view.updateDrawing(visible: false)
        view.feed(text: "hidden again\r\n")
        settle()
        check(draws == before + 2 && view.drawGate.pending, "hidden again, held again")
        check(window.firstResponder === view, "keyboard kept throughout")
        print("PASS TerminalDrawGateTests: \(checks) checks")
    }
}
