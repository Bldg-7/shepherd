import Foundation
import AppKit
import SwiftTerm

@main @MainActor enum TerminalLinkTests {
    static func main() {
        // Owned, windowless NSViews only. No user application, GUI event
        // automation, terminal process, or personal terminal output.
        _ = NSApplication.shared
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 400))
        view.feed(text: "Read README.md:42 and docs/guide.md\r\n한글 https://example.invalid/wide\r\nhttps://example.invalid/a.md\r\n\u{1b}]8;;file:///owned/explicit.md\u{7}explicit\u{1b}]8;;\u{7}")
        let cell = view.caretFrame.size
        precondition(cell.width > 0 && cell.height > 0)
        func hit(_ row: Int, _ col: Int) -> String? {
            TerminalFileHit.link(in: view, point: CGPoint(x: (CGFloat(col) + 0.5) * cell.width, y: view.bounds.maxY - (CGFloat(row) + 0.5) * cell.height))
        }
        // Only OSC8 makes text a file link. A plain path is TUI text.
        precondition((0..<view.getTerminal().cols).allSatisfy { hit(0, $0) == nil }, "plain paths are not links")
        precondition(hit(1, 8) == "https://example.invalid/wide" && hit(1, 1) == nil, "wide Korean cells must not shift the click")
        precondition(hit(2, 8) == "https://example.invalid/a.md", "web links must be claimed before TUI input")
        precondition(hit(3, 2) == "file:///owned/explicit.md", "OSC8 file clicks must be claimed before TUI input")
        precondition(view.getTerminal().link(at: .screen(Position(col: 2, row: 3)), mode: .explicitOnly) == "file:///owned/explicit.md")
        precondition(TerminalFileHit.link(in: view, point: CGPoint(x: -1, y: 0)) == nil)
        let wrapped = TerminalView(frame: CGRect(x: 0, y: 0, width: 180, height: 400))
        wrapped.feed(text: "https://example.invalid/a-long/name1\r\n./directory/a-very-long-file-name.md")
        let wc = wrapped.caretFrame.size
        precondition(wrapped.getTerminal().getLine(row: 1)?.isWrapped == true && wrapped.getTerminal().getLine(row: 3)?.isWrapped == true, "fixtures must soft-wrap")
        let point = CGPoint(x: 2.5 * wc.width, y: wrapped.bounds.maxY - 1.5 * wc.height)
        precondition(TerminalFileHit.link(in: wrapped, point: point) == "https://example.invalid/a-long/name1", "soft-wrapped URL")
        let wrappedPath = CGPoint(x: 2.5 * wc.width, y: wrapped.bounds.maxY - 3.5 * wc.height)
        precondition(TerminalFileHit.link(in: wrapped, point: wrappedPath) == nil, "soft-wrapped plain path is not a link")
        let rtl = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        rtl.feed(text: "אבג https://example.invalid/a")
        let rc = rtl.caretFrame.size
        precondition(TerminalFileHit.link(in: rtl, point: CGPoint(x: 8.5 * rc.width, y: rtl.bounds.maxY - 0.5 * rc.height)) == nil, "unavailable bidi mapping must not guess")
        // SwiftTerm's implicit matcher runs a path or URL on into the Korean
        // after it. A plain path opens nothing; an OSC8 path or a URL opens,
        // and a click on the prose after it opens nothing.
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
            "file:///owned/plain/uri.md#L3 /owned/abs.md ~/notes.md",
            "\u{1b}]8;;src/board.ts:42\u{7}src/board.ts:42\u{1b}]8;;\u{7}에서 확인",
        ].joined(separator: "\r\n"))
        let pc = prose.caretFrame.size
        func proseHit(_ row: Int, _ col: Int) -> String? {
            TerminalFileHit.link(in: prose, point: CGPoint(x: (CGFloat(col) + 0.5) * pc.width, y: prose.bounds.maxY - (CGFloat(row) + 0.5) * pc.height))
        }
        let opened = (0..<prose.getTerminal().cols).compactMap { c in proseHit(0, c).map { "col \(c): \($0)" } }
        precondition(opened.isEmpty, "reported line must open nothing, got \(opened)")
        precondition(proseHit(1, 25) == "file:///owned/Projects/tf-post" && (40..<prose.getTerminal().cols).allSatisfy { proseHit(1, $0) == nil }, "OSC8 path opens, the prose glued to it does not")
        for row in [2, 3, 4, 5, 6, 7, 8, 11] {
            let opened = (0..<prose.getTerminal().cols).compactMap { c in proseHit(row, c).map { "col \(c): \($0)" } }
            precondition(opened.isEmpty, "plain path, source location or file URI must open nothing, row \(row) got \(opened)")
        }
        precondition(proseHit(12, 2) == "src/board.ts:42" && proseHit(12, 15) == nil && proseHit(12, 18) == nil, "OSC8 source location opens, the prose glued to it does not")
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
        print("PASS 26 actual SwiftTerm cell/link/wide/wrap/BiDi/OSC8/plain-path/prose/coordinator checks; owned windowless views, no GUI input")
    }
}
