import Foundation
@main enum MarkdownParsingTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
    static func main() {
        let md = "\u{feff}---\r\ntitle: Test\r\ntags: [a, b]\r\nnested:\r\n  key: value\r\ndescription: |\r\n  multiline\r\n  body\r\n---\r\n# Heading\r\n\r\n**bold** and [file](next.md)\r\n"
        let parsed = PreviewMarkdownBlock.parse(md)
        check(parsed.count == 3, "frontmatter metadata + heading + inline paragraph")
        if case .frontmatter = parsed[0].kind { checks += 1 } else { preconditionFailure("YAML frontmatter") }
        check(parsed[0].language == .yaml, "YAML metadata language")
        let fields = PreviewFrontmatterField.parse(parsed[0].text, separator: ":")
        check(fields.map(\.key) == ["title", "tags", "nested", "description"], "top-level metadata fields")
        check(fields[1].value == "[a, b]", "array preserved without execution")
        check(fields[2].value.contains("  key: value"), "nested metadata preserved")
        check(fields[3].value.contains("multiline\n  body"), "literal multiline metadata preserved")
        check(PreviewFrontmatterField.parse("url: https://host/path", separator: ":")[0].value == "https://host/path", "colon in scalar")
        check(PreviewFrontmatterField.parse("payload: !execute echo\n  &alias *alias", separator: ":")[0].value.contains("!execute"), "tags aliases remain literal")
        let toml = PreviewMarkdownBlock.parse("+++\ntitle = \"Hi\"\ntags = [\"a\"]\n+++\nBody")
        check(toml.count == 2 && toml[0].language == .toml, "TOML frontmatter")
        check(PreviewFrontmatterField.parse(toml[0].text, separator: "=").count == 2, "TOML metadata fields")
        check(PreviewMarkdownBlock.parse("---\na: b\n...\nBody").count == 2, "YAML end marker")
        let unclosed = PreviewMarkdownBlock.parse("---\na: b\n# Body")
        if case .rule = unclosed[0].kind { checks += 1 } else { preconditionFailure("unclosed frontmatter must not swallow document") }
        let middle = PreviewMarkdownBlock.parse("Before\n\n---\nfoo: bar\n---")
        check(!middle.contains { if case .frontmatter = $0.kind { return true }; return false }, "mid-document rule is not frontmatter")
        let fence = PreviewMarkdownBlock.parse("````swift\n```\nlet a = 1\n````\nAfter")
        check(fence.count == 2 && fence[0].text == "```\nlet a = 1", "fence length respected")
        check(fence[0].language == .swift, "fence language retained")
        check(PreviewMarkdownBlock.parse("```\nlast")[0].text == "last", "unclosed code remains literal")
        let lists = PreviewMarkdownBlock.parse("- [ ] todo\n  - [x] done\n1. ordered\n+ bullet")
        check(lists.count == 4, "task unordered ordered lists parsed")
        if case .listItem(_, 0, false) = lists[0].kind { checks += 1 } else { preconditionFailure("unchecked") }
        if case .listItem(_, 1, true) = lists[1].kind { checks += 1 } else { preconditionFailure("nested checked") }
        if case .listItem("1.", 0, nil) = lists[2].kind { checks += 1 } else { preconditionFailure("ordered") }
        let headings = PreviewMarkdownBlock.parse("Title\n===\n\nSubtitle\n---")
        if case .heading(1) = headings[0].kind { checks += 1 } else { preconditionFailure("setext H1") }
        if case .heading(2) = headings[1].kind { checks += 1 } else { preconditionFailure("setext H2") }
        let table = PreviewMarkdownBlock.parse("| Key | Value |\n| :--- | ---: |\n| a | **b** |\n| c | `x|y` |\n\nAfter")
        check(table.count == 2, "table then paragraph")
        if case .table = table[0].kind { checks += 1 } else { preconditionFailure("table parsed") }
        check(table[0].rows.count == 3 && table[0].rows[2][1] == "`x|y`", "inline-code pipe is not column separator")
        check(PreviewMarkdownBlock.parse("a | b\nnot | a-table").count == 1, "invalid separator remains paragraph")
        let quote = PreviewMarkdownBlock.parse("> First\n> Second\n\nEnd")
        check(quote.count == 2 && quote[0].text == "First\nSecond", "multiline quote")
        let html = PreviewMarkdownBlock.parse("<script>alert(1)</script>\n![remote](https://localhost/image.png)")
        check(html.count == 1 && html[0].text.contains("<script>"), "HTML/images remain native inert text; no web engine")
        tableOfContents()
        print("PASS \(checks) YAML/TOML frontmatter, bounded inert metadata, Markdown headings/lists/tasks/tables/fences/quotes regressions, table of contents headings, their source lines and the heading the reader is at")
    }

    /// The table of contents' headings and the source lines they start on,
    /// which must be the lines the source view shows them on.
    static func tableOfContents() {
        let guide = "\u{feff}---\r\ntitle: Guide\r\n---\r\n# Deploy **guide**\r\n\r\nIntro with a lone CR\rinside it.\r\n\r\n"
            + "First line of a\r\nsetext heading\r\n===\r\n\r\n```sh\r\n# not a heading\r\n```\r\n\r\n## [](#empty)\r\n\r\n"
            + "### Configure `env` and [secrets](secrets.md)\r\nText\u{2028}more\r\n#### Last\r\nSub\r\n---\r\n"
        let source = PreviewSyntaxHighlighter.lines(guide, language: .plain).map(\.text)
        check(source.count == 25 && source[6] == "inside it." && source[19] == "Text" && source[20] == "more",
              "the source view breaks at CRLF, a lone CR and U+2028 alike (owned fixture)")
        let blocks = PreviewMarkdownBlock.parse(guide)
        let headings = PreviewMarkdownHeading.headings(in: blocks)
        check(headings.map(\.title) == ["Deploy guide", "First line of a setext heading", "Configure env and secrets", "Last", "Sub"],
              "headings by their plain names: emphasis, code and links rendered, a setext heading's lines joined; none from fenced code, none that shows nothing")
        check(headings.map(\.level) == [1, 1, 3, 4, 2], "ATX and setext levels")
        check(headings.map(\.line) == [4, 9, 19, 22, 23], "each heading's line, after a BOM, CRLF and frontmatter, a lone CR and a U+2028")
        for heading in headings {
            check(source[heading.line - 1].hasPrefix(["Deploy guide": "# Deploy", "First line of a setext heading": "First line of a",
                                                     "Configure env and secrets": "### Configure", "Last": "#### Last", "Sub": "Sub"][heading.title]!),
                  "the source view shows \(heading.title) on the heading's line")
        }
        check(blocks.contains { if case .heading(2) = $0.kind { return $0.text == "[](#empty)" }; return false },
              "a heading that shows nothing is still rendered as one, only not listed")
        check(blocks.contains { if case .code = $0.kind { return $0.text == "# not a heading" && $0.line == 13 }; return false },
              "fenced # stays code, at its fence's line")
        check(blocks.first { if case .paragraph = $0.kind { return true }; return false }?.line == 6, "a paragraph starts at its first line")
        check(blocks.first?.line == 1, "frontmatter starts the file")
        let crcrlf = PreviewMarkdownBlock.parse("a\r\r\n# H")
        check(PreviewMarkdownHeading.headings(in: crcrlf).map(\.line) == [3] && PreviewSyntaxHighlighter.lines("a\r\r\n# H", language: .plain)[2].text == "# H",
              "CR then CRLF is two line breaks in both views")
        check(PreviewMarkdownHeading.headings(in: PreviewMarkdownBlock.parse("Para\n\n# One\n\n## Two")).map(\.line) == [3, 5], "LF lines")

        // The document the preview keeps for a text: parsed once, the same
        // headings, inline renders kept.
        let document = PreviewMarkdownDocument(guide)
        check(document.headings == headings && document.blocks.count == blocks.count, "the kept document's blocks and headings")
        check(document.inline("**a**") == document.inline("**a**") && String(document.inline("**a** `b`").characters) == "a b", "inline renders")

        // The heading the reader is at: the last one at or before the first
        // row shown, by block id in the rendering and by line in the source.
        let ids = headings.map(\.id)
        check(PreviewOutline.current(in: headings, firstVisible: nil, inSource: false) == nil, "nothing shown yet")
        check(PreviewOutline.current(in: headings, firstVisible: 0, inSource: false) == nil, "frontmatter is before the first heading")
        check(PreviewOutline.current(in: headings, firstVisible: ids[0], inSource: false) == ids[0], "a heading at the top is the one")
        check(PreviewOutline.current(in: headings, firstVisible: ids[2] - 1, inSource: false) == ids[1], "the text after a heading belongs to it")
        check(PreviewOutline.current(in: headings, firstVisible: ids[4] + 5, inSource: false) == ids[4], "past the last heading")
        check(PreviewOutline.current(in: headings, firstVisible: 3, inSource: true) == nil, "source: frontmatter lines")
        check(PreviewOutline.current(in: headings, firstVisible: 14, inSource: true) == ids[1], "source: the fenced # is no heading")
        check(PreviewOutline.current(in: headings, firstVisible: 19, inSource: true) == ids[2], "source: a heading's own line")
        check(PreviewOutline.width(for: 200) == 160 && PreviewOutline.width(for: 400) == 200 && PreviewOutline.width(for: 900) == 260,
              "half the preview's width, from 160 to 260 points")
    }
}
