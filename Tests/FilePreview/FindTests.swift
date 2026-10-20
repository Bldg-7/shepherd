import SwiftUI
import AppKit

/// The preview's find: what it looks in, how it matches, where it goes
/// next, how its matches are marked, and the keys the preview takes for it.
@main @MainActor enum FindTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static func main() {
        matching()
        rendered()
        going()
        marking()
        keys()
        print("PASS \(checks) find checks: case and NFC/NFD matching by Unicode scalars, the rendered Markdown's text, code, tables and frontmatter against the source's lines, the next and previous match going round, 120,000 characters, marks on their backgrounds, and the preview's keys")
    }

    static func matching() {
        check(PreviewFind.ranges(of: "deploy", in: "Deploy, then DEPLOY; redeploy.") == [0..<6, 13..<19, 23..<29], "case is ignored, every match in order")
        check(PreviewFind.ranges(of: "", in: "anything").isEmpty && PreviewFind.ranges(of: "x", in: "").isEmpty, "an empty query finds nothing")
        check(PreviewFind.ranges(of: "aa", in: "aaaa") == [0..<2, 2..<4], "matches don't overlap")
        // Korean typed composed (NFC) finds text stored decomposed (NFD), as
        // a file from a Mac file system may be, and the other way round.
        let nfd = "배포 " + "한글".decomposedStringWithCanonicalMapping + " 끝"
        check(nfd.unicodeScalars.count == 11, "the owned fixture: 배포 and a space, 한글 in six jamo, a space and 끝")
        check(PreviewFind.ranges(of: "한글", in: nfd) == [3..<9], "an NFC query finds NFD text, by its six scalars")
        check(PreviewFind.ranges(of: "한글".decomposedStringWithCanonicalMapping, in: "배포 한글 끝") == [3..<5], "an NFD query finds NFC text")
        check(PreviewFind.ranges(of: "café", in: "CAFE\u{301} cafe") == [0..<5], "é composed finds E and a combining accent, case ignored; not a bare e")
        check(PreviewFind.ranges(of: "글", in: nfd) == [6..<9], "a syllable inside a decomposed word")
        check(PreviewFind.ranges(of: "👍🏽", in: "a👍🏽b👍🏽") == [1..<3, 4..<6], "offsets count scalars, not UTF-16")
        // The preview renders at most 120,000 characters, and finds in that.
        let long = String(repeating: "abcdefghij", count: 11_999) + "needle1234"
        check(long.count == 120_000, "a text of the render limit")
        check(PreviewFind.ranges(of: "NEEDLE", in: long) == [119_990..<119_996], "a match at the end of 120,000 characters")
        let texts = PreviewFind.sourceTexts(String(repeating: "x needle y\n", count: 12_000))
        let started = Date()
        let found = PreviewFind.matches(of: "needle", in: texts)
        check(found.count == 12_000 && found.last?.row == 12_000 && Date().timeIntervalSince(started) < 2, "12,000 matches in 132,000 characters, by line")
    }

    /// What is looked in: the source view's lines, and what the rendering
    /// shows, without its Markdown.
    static func rendered() {
        let markdown = "---\ntitle: Deploy guide\nowner: ops\n---\n# **Deploy** it\n\nRun [the deploy notes](deploy.md) and `deploy`.\n\n"
            + "- [ ] deploy twice\n> quoted deploy\n\n| Stage | Deploy |\n| --- | --- |\n| one | **deploy** |\n\n```sh\n./deploy.sh\nDEPLOY=1\n```\n\n---\n"
        let document = PreviewMarkdownDocument(markdown)
        let texts = PreviewFind.renderedTexts(document)
        check(texts.map(\.text) == ["title", "Deploy guide", "owner", "ops", "Deploy it", "Run the deploy notes and deploy.", "deploy twice",
                                    "quoted deploy", "Stage", "Deploy", "one", "deploy", "./deploy.sh\nDEPLOY=1"],
              "the rendering's text: frontmatter keys and values, inline Markdown rendered, link targets out, task box out, table cells, code")
        check(texts.map(\.row) == [0, 0, 0, 0, 1, 2, 3, 4, 5, 5, 5, 5, 6] && texts.map(\.part) == [0, 1, 2, 3, 0, 0, 0, 0, 0, 1, 2, 3, 0],
              "by block id and part: field n's key 2n and value 2n + 1, cells row by row")
        let matches = PreviewFind.matches(of: "deploy", in: texts)
        check(matches.count == 10, "rendered: guide, heading, notes, code span, task, quote, header cell, cell, code twice")
        check(!matches.contains { $0.row == 2 && $0.range == 16..<22 } && matches.filter { $0.row == 2 }.map(\.range) == [8..<14, 25..<31],
              "the link's target deploy.md is not shown, so not found")
        let source = PreviewFind.matches(of: "deploy", in: PreviewFind.sourceTexts(markdown))
        check(source.map(\.row) == [2, 5, 7, 7, 7, 9, 10, 12, 14, 17, 18], "source: every line it is on, ** and the link target included")
        check(source.first { $0.row == 5 }?.range == 4..<10, "inside ** in the source")
        // The rows the rendering has for the blocks find looks in.
        check(document.blocks.count == 8, "frontmatter, heading, paragraph, task, quote, table, code, rule")
        check(PreviewFind.sourceTexts("a\r\nb\rc\u{2028}d\n\ne").map(\.row) == [1, 2, 3, 4, 6], "source rows are the source view's line numbers")

        // Roughly where a match is in a row too tall to be shown whole.
        let code = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let codeMatch = PreviewFind.matches(of: "line 75", in: PreviewFind.renderedTexts(PreviewMarkdownDocument("```\n" + code + "\n```")))
        check(codeMatch.count == 1 && abs(codeMatch[0].place - 0.74) < 0.011, "a match three quarters down a long code block")
        let short = PreviewFind.matches(of: "line 7", in: PreviewFind.renderedTexts(PreviewMarkdownDocument("```\n" + code.prefix(70) + "\n```")))
        check(!short.isEmpty && short.allSatisfy { $0.place == 0 }, "a short block is brought to its top")
        let table = "| A | B |\n| --- | --- |\n" + (1...50).map { "| r\($0) | x |" }.joined(separator: "\n")
        let row = PreviewFind.matches(of: "r40", in: PreviewFind.renderedTexts(PreviewMarkdownDocument(table)))
        check(row.count == 1 && abs(row[0].place - 40.0 / 51.0) < 0.001 && row[0].part == 40 * 2, "a table's row 40 of 51 lines; cell 0 of row 40")
        let wrapped = PreviewFind.matches(of: "end", in: PreviewFind.sourceTexts(String(repeating: "m", count: 7_920) + "end"))
        check(wrapped.count == 1 && abs(wrapped[0].place - 99.0 / 100.0) < 0.001, "a long source line, as lines 80 characters wide")
    }

    static func going() {
        let matches = [3, 3, 8, 20].enumerated().map { PreviewFindMatch(row: $0.element, part: 0, range: $0.offset..<($0.offset + 1), place: 0) }
        check(PreviewFind.first(matches, atOrAfter: nil) == 0 && PreviewFind.first(matches, atOrAfter: 3) == 0, "from the top, the first")
        check(PreviewFind.first(matches, atOrAfter: 4) == 2 && PreviewFind.first(matches, atOrAfter: 20) == 3, "the first from the row shown")
        check(PreviewFind.first(matches, atOrAfter: 21) == 0, "past the last, round to the first")
        check(PreviewFind.last(matches, before: 8) == 1 && PreviewFind.last(matches, before: 3) == 3 && PreviewFind.last(matches, before: nil) == 3,
              "the last before the row shown, or round to the last")
        check(PreviewFind.first([], atOrAfter: 1) == nil && PreviewFind.last([], before: 1) == nil, "none")
        check(PreviewFind.step(from: 3, by: 1, count: 4) == 0 && PreviewFind.step(from: 0, by: -1, count: 4) == 3 && PreviewFind.step(from: 1, by: 1, count: 4) == 2,
              "next and previous go round at either end")
        check(PreviewFind.current(nil, count: 4) == nil && PreviewFind.current(2, count: 4) == 2 && PreviewFind.current(9, count: 4) == 3
              && PreviewFind.current(1, count: 0) == nil, "the match the bar is at, the last when there are fewer now")
    }

    static func marking() {
        let matches = [PreviewFindMatch(row: 2, part: 0, range: 0..<6, place: 0), PreviewFindMatch(row: 2, part: 1, range: 1..<2, place: 0),
                       PreviewFindMatch(row: 2, part: 0, range: 8..<10, place: 0), PreviewFindMatch(row: 5, part: 0, range: 0..<1, place: 0)]
        let marks = PreviewFind.marks(matches, current: 2)
        check(marks(row: 2) == [PreviewFindMark(range: 0..<6, isCurrent: false), PreviewFindMark(range: 8..<10, isCurrent: true)]
              && marks(row: 2, part: 1).count == 1 && marks(row: 5).count == 1 && marks(row: 9).isEmpty && PreviewFindMarks.none(row: 2).isEmpty,
              "marks by row and part, the current one told apart")
        func backgrounds(_ text: AttributedString) -> [(String, Color?)] {
            text.runs.map { (String(text[$0.range].characters), $0.backgroundColor) }
        }
        let plain = PreviewSyntaxRendering.marked(AttributedString("Deploy it, deploy"), [PreviewFindMark(range: 0..<6, isCurrent: true), PreviewFindMark(range: 11..<17, isCurrent: false)])
        let runs = backgrounds(plain)
        check(String(plain.characters) == "Deploy it, deploy", "marking changes no character")
        check(runs.count == 3 && runs[0].0 == "Deploy" && runs[0].1 == PreviewSyntaxRendering.currentMatchBackground && runs[1].0 == " it, " && runs[1].1 == nil
              && runs[2].0 == "deploy" && runs[2].1 == PreviewSyntaxRendering.matchBackground, "the current match and the others on their own backgrounds")
        check(PreviewSyntaxRendering.currentMatchBackground != PreviewSyntaxRendering.matchBackground, "told apart")
        // Rendered inline Markdown keeps its own attributes under the marks.
        let inline = PreviewMarkdownBlock.inline("**Deploy** [now](deploy.md)")
        let marked = PreviewSyntaxRendering.marked(inline, PreviewFind.ranges(of: "deploy now", in: String(inline.characters)).map { PreviewFindMark(range: $0, isCurrent: false) })
        check(marked.runs.contains { String(marked[$0.range].characters) == "now" && $0.link != nil && $0.backgroundColor == PreviewSyntaxRendering.matchBackground },
              "a link keeps its target, marked")
        // Decomposed Korean: the mark covers the decomposed scalars only.
        let nfd = AttributedString("배포 " + "한글".decomposedStringWithCanonicalMapping + " 끝")
        let korean = backgrounds(PreviewSyntaxRendering.marked(nfd, [PreviewFindMark(range: 3..<9, isCurrent: false)]))
        check(korean.count == 3 && korean[1].0 == "한글".decomposedStringWithCanonicalMapping && korean[1].1 == PreviewSyntaxRendering.matchBackground,
              "NFD Korean marked by its scalars")
        check(backgrounds(PreviewSyntaxRendering.marked(AttributedString("abc"), [PreviewFindMark(range: 2..<9, isCurrent: false)])).count == 1,
              "a mark past the end is left out")
        // A source line keeps its token colors under the marks.
        let line = PreviewSyntaxHighlighter.lines("let deploy = \"deploy\"", language: .swift)[0]
        let colored = PreviewSyntaxRendering.attributed(line, scheme: .light, marks: [PreviewFindMark(range: 4..<10, isCurrent: true), PreviewFindMark(range: 14..<20, isCurrent: false)])
        check(colored.runs.contains { String(colored[$0.range].characters) == "let" && $0.foregroundColor != nil && $0.backgroundColor == nil }, "keyword colored, not marked")
        check(colored.runs.contains { String(colored[$0.range].characters) == "deploy" && $0.foregroundColor != nil && $0.backgroundColor == PreviewSyntaxRendering.matchBackground },
              "the match in a string keeps the string's color, marked")
        check(colored.runs.contains { String(colored[$0.range].characters) == "deploy" && $0.backgroundColor == PreviewSyntaxRendering.currentMatchBackground }, "and the current one")
        check(PreviewSyntaxRendering.attributed(line, scheme: .light) == PreviewSyntaxRendering.attributed(line, scheme: .light, marks: []), "no marks, as before")
    }

    static func keys() {
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) -> PreviewKeyCommand? {
            PreviewKeyCommand(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!)
        }
        check(key("f", .command) == .find && key("g", .command) == .findNext && key("G", [.command, .shift]) == .findPrevious, "⌘F, ⌘G, ⇧⌘G")
        check(key("f", [.command, .capsLock]) == .find && key("F", [.command, .capsLock]) == .find, "Caps Lock doesn't matter")
        check(key("f", [.command, .option]) == nil && key("f", [.command, .shift]) == nil && key("g", [.command, .control]) == nil && key("f", []) == nil
              && key("f", .command, type: .keyUp) == nil && key("e", .command) == nil, "other modifiers, a bare f, a key-up or ⌘E aren't the preview's")
        check(PreviewKeyCommand.keys.count == 3, "three keys, in one list")
        check(PreviewFindField.step(shift: false) == 1 && PreviewFindField.step(shift: true) == -1, "Return goes to the next match, ⇧Return to the previous")
    }
}
