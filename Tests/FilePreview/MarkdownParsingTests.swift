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
        print("PASS \(checks) YAML/TOML frontmatter, bounded inert metadata, Markdown headings/lists/tasks/tables/fences/quotes regressions")
    }
}
