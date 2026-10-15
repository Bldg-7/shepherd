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
        precondition(hit(2, 8) == "https://example.invalid/a.md", "web links must be claimed before TUI input")
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
        // SwiftTerm's implicit matcher runs a path or URL on into the Korean
        // after it. Only the link opens; a click on the prose opens nothing.
        let prose = TerminalView(frame: CGRect(x: 0, y: 0, width: 1600, height: 400))
        prose.feed(text: [
            "● tfpost 에이전트를 종료하고 제가 만든 pane(wE:p1C)도 닫았습니다. tf-post 수정 파일은 \u{1b}[38;2;177;185;249m~/Projects/tf-post\u{1b}[39m에 그대로 남아 있습니다.",
            "● tf-post 수정 파일은 \u{1b}]8;;file:///owned/Projects/tf-post\u{7}~/Projects/tf-post\u{1b}]8;;\u{7}에 그대로 남아 있습니다.",
            "- docs/README.md를 수정했습니다.",
            "- test/board.test.ts에 4개 케이스 추가",
            "src/board.ts:42에서 확인",
            "경로는 /tmp/foo 입니다",
            "/owned/my dir/notes.md",
            "열기: docs/회의록.md 참고",
            "docs/2024년_회의록.md를 보세요",
            "PR은 https://example.invalid/pull/16048에서 확인",
            "https://example.invalid/wiki/서울",
        ].joined(separator: "\r\n"))
        let pc = prose.caretFrame.size
        func proseHit(_ row: Int, _ col: Int) -> String? {
            TerminalFileHit.link(in: prose, point: CGPoint(x: (CGFloat(col) + 0.5) * pc.width, y: prose.bounds.maxY - (CGFloat(row) + 0.5) * pc.height))
        }
        let opened = (0..<prose.getTerminal().cols).compactMap { c in proseHit(0, c).map { "col \(c): \($0)" } }
        precondition(opened.isEmpty, "reported line must open nothing, got \(opened)")
        precondition(proseHit(1, 25) == "file:///owned/Projects/tf-post" && (40..<prose.getTerminal().cols).allSatisfy { proseHit(1, $0) == nil }, "OSC8 path opens, the prose glued to it does not")
        precondition(proseHit(2, 5) == "docs/README.md" && proseHit(2, 16) == nil && proseHit(2, 22) == nil, "dotted path ends at its particle")
        precondition(proseHit(3, 10) == "test/board.test.ts" && proseHit(3, 20) == nil, "path glued to a particle")
        precondition(proseHit(4, 2) == "src/board.ts:42" && proseHit(4, 16) == nil, "source location glued to a particle")
        precondition(proseHit(5, 8) == nil && proseHit(5, 16) == nil, "path then spaced Korean prose")
        precondition(proseHit(6, 12) == "/owned/my dir/notes.md", "spaced path ending in a file name")
        precondition(proseHit(7, 8) == "docs/회의록.md", "Korean file name")
        precondition(proseHit(8, 3) == "docs/2024년_회의록.md" && proseHit(8, 21) == nil, "Korean file name with a digit before Hangul")
        precondition(proseHit(9, 10) == "https://example.invalid/pull/16048" && proseHit(9, 39) == nil && proseHit(9, 41) == nil, "URL ends at its particle")
        precondition(proseHit(10, 3) == "https://example.invalid/wiki/서울", "Hangul after a slash stays in the URL")
        var clicked: String?
        let host = TerminalHostView(onCreate: { _ in }, onInput: { _ in }, onResize: { _,_ in }, onOpenLink: { clicked = $0 })
        let coordinator = host.makeCoordinator()
        coordinator.requestOpenLink(source: view, link: "file:///owned/explicit.md", params: [:])
        precondition(clicked == "file:///owned/explicit.md")
        coordinator.onOpenLink = { clicked = "fresh:" + $0 }
        coordinator.requestOpenLink(source: view, link: "./current.md", params: [:])
        precondition(clicked == "fresh:./current.md", "coordinator must use latest pane callback")
        print("PASS 24 actual SwiftTerm cell/link/wide/wrap/BiDi/OSC8/prose/coordinator checks; owned windowless views, no GUI input")
    }
}
