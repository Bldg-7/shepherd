import Foundation
import AppKit
import SwiftTerm

@main @MainActor enum TerminalLinkTests {
    static func main() {
        // Owned, windowless NSViews only. No user application, GUI event
        // automation, terminal process, or personal terminal output.
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 400))
        view.feed(text: "Read README.md:42 and docs/guide.md\r\n한글 docs/wide.md\r\nhttps://example.invalid/a.md\r\n\u{1b}]8;;file:///owned/explicit.md\u{7}explicit\u{1b}]8;;\u{7}")
        let cell = view.caretFrame.size
        precondition(cell.width > 0 && cell.height > 0)
        func hit(_ row: Int, _ col: Int) -> String? {
            TerminalFileHit.link(in: view, point: CGPoint(x: (CGFloat(col) + 0.5) * cell.width, y: view.bounds.maxY - (CGFloat(row) + 0.5) * cell.height))
        }
        precondition(hit(0, 7) == "README.md:42")
        precondition(hit(0, 26) == "docs/guide.md")
        precondition(hit(0, 1) == nil, "not a file token")
        precondition(hit(1, 8) == "docs/wide.md", "wide Korean cells must not shift the click")
        precondition(hit(2, 8) == nil, "native web link detection owns URL clicks")
        precondition(hit(3, 2) == "file:///owned/explicit.md", "OSC8 file clicks must be claimed before TUI input")
        precondition(view.getTerminal().link(at: .screen(Position(col: 2, row: 3)), mode: .explicitOnly) == "file:///owned/explicit.md")
        precondition(TerminalFileHit.link(in: view, point: CGPoint(x: -1, y: 0)) == nil)
        let wrapped = TerminalView(frame: CGRect(x: 0, y: 0, width: 180, height: 400))
        wrapped.feed(text: "./directory/a-very-long-file-name.md")
        let wc = wrapped.caretFrame.size
        let point = CGPoint(x: 2.5 * wc.width, y: wrapped.bounds.maxY - 1.5 * wc.height)
        precondition(TerminalFileHit.link(in: wrapped, point: point) == "./directory/a-very-long-file-name.md", "soft-wrapped path")
        let rtl = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        rtl.feed(text: "אבג docs/a.md")
        let rc = rtl.caretFrame.size
        precondition(TerminalFileHit.link(in: rtl, point: CGPoint(x: 8.5 * rc.width, y: rtl.bounds.maxY - 0.5 * rc.height)) == nil, "unavailable bidi mapping must not guess")
        var clicked: String?
        let host = TerminalHostView(onCreate: { _ in }, onInput: { _ in }, onResize: { _,_ in }, onOpenLink: { clicked = $0 })
        let coordinator = host.makeCoordinator()
        coordinator.requestOpenLink(source: view, link: "file:///owned/explicit.md", params: [:])
        precondition(clicked == "file:///owned/explicit.md")
        coordinator.onOpenLink = { clicked = "fresh:" + $0 }
        coordinator.requestOpenLink(source: view, link: "./current.md", params: [:])
        precondition(clicked == "fresh:./current.md", "coordinator must use latest pane callback")
        print("PASS 13 actual SwiftTerm cell/link/wide/wrap/BiDi/OSC8/coordinator checks; owned windowless views, no GUI input")
    }
}
