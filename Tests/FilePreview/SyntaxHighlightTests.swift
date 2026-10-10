import SwiftUI

@main @MainActor enum SyntaxHighlightTests {
    static var checks = 0
    static func check(_ b: Bool) { precondition(b); checks += 1 }
    static func has(_ text: String, _ language: PreviewSyntaxLanguage, _ needle: String, _ kind: PreviewSyntaxKind) -> Bool {
        PreviewSyntaxHighlighter.lines(text, language: language).contains { line in
            let chars = Array(line.text)
            return line.spans.contains { $0.kind == kind && String(chars[$0.range]) == needle }
        }
    }
    static func main() async {
        for (path, language) in [("a.swift", PreviewSyntaxLanguage.swift), ("a.py", .python), ("a.tsx", .javascript), ("a.json", .json), ("a.yaml", .yaml), ("a.toml", .toml), ("a.sh", .shell), ("a.rs", .rust), ("a.go", .go), ("a.cpp", .cFamily), ("a.rb", .ruby), ("a.sql", .sql), ("a.txt", .plain)] {
            check(PreviewSyntaxLanguage.filename(path) == language)
        }
        check(PreviewSyntaxLanguage.fence("typescript") == .javascript)
        check(PreviewSyntaxLanguage.fence("python") == .python)
        check(PreviewSyntaxLanguage.fence("javascript:alert(1)") == .plain)
        check(PreviewSyntaxLanguage.filename(nil) == .plain)
        check(has("import Foundation\nlet x = 12.5\nfunc greet() { print(\"한글 👩🏽‍💻\") } // note", .swift, "let", .keyword))
        check(has("func greet() {}", .swift, "greet", .function))
        check(has("let x = Widget()", .swift, "Widget", .function))
        check(has("var x: Widget", .swift, "Widget", .type))
        check(has("let x = 12.5", .swift, "12.5", .number))
        check(has("print(\"한글 👩🏽‍💻\")", .swift, "\"한글 👩🏽‍💻\"", .string))
        check(has("// note", .swift, "// note", .comment))
        check(has("let x = \"// not comment\"", .swift, "\"// not comment\"", .string))
        check(has("/* outer /* inner */ done */ let x = 1", .swift, "/* outer /* inner */ done */", .comment))
        check(has("def greet():\n    return True # note", .python, "def", .keyword))
        check(has("def greet():\n    return True # note", .python, "# note", .comment))
        check(has("'''first\nsecond'''\nreturn 3", .python, "second'''", .string))
        check(has("const x = `a ${1}`;", .javascript, "const", .keyword))
        check(has("const x = `a ${1}`;", .javascript, "`a ${1}`", .string))
        check(has("{\"key\": \"value\", \"ok\": true}", .json, "\"key\"", .property))
        check(has("{\"key\": \"value\"}", .json, "\"value\"", .string))
        check(has("enabled: true # note", .yaml, "enabled", .property))
        check(has("name = \"owned\"", .toml, "name", .property))
        check(has("export VAR=1 # note", .shell, "export", .keyword))
        check(has("echo $HOME", .shell, "$HOME", .property))
        check(has("fn test<'a>(x: &'a str) { let y = 2; }", .rust, "let", .keyword))
        check(has("package main\nfunc test() {}", .go, "func", .keyword))
        check(has("int value = 0xFF;", .cFamily, "0xFF", .number))
        check(has("SELECT * FROM table WHERE x = 2", .sql, "SELECT", .keyword))
        check(has("SELECT '-- literal' -- note", .sql, "'-- literal'", .string))
        check(PreviewSyntaxHighlighter.lines("let x = 1", language: .plain)[0].spans.isEmpty)
        let colored = PreviewSyntaxHighlighter.lines("let name = \"owned\" // comment", language: .swift)[0]
        let styled = PreviewSyntaxRendering.attributed(colored, scheme: .dark)
        check(styled.runs.filter { $0.foregroundColor != nil }.count >= 3)
        check(PreviewSyntaxRendering.color(.keyword, scheme: .light) != PreviewSyntaxRendering.color(.keyword, scheme: .dark))
        let unicode = "let 한글 = \"👩🏽‍💻 é\"\n/* a\nb */\n\n"
        for language in [PreviewSyntaxLanguage.swift, .python, .javascript, .json, .plain] {
            let lines = PreviewSyntaxHighlighter.lines(unicode, language: language)
            check(lines.map(\.text).joined(separator: "\n") == unicode)
            for line in lines {
                var previous = 0
                for span in line.spans {
                    check(span.range.lowerBound >= previous && span.range.upperBound <= line.text.count)
                    previous = span.range.upperBound
                }
                for scheme in [ColorScheme.light, .dark] {
                    let attributed = PreviewSyntaxRendering.attributed(line, scheme: scheme)
                    check(String(attributed.characters) == line.text)
                    check(attributed.runs.allSatisfy { $0.link == nil })
                }
            }
        }
        check(PreviewSyntaxHighlighter.lines("a\r\nb\r\n", language: .plain).map(\.text) == ["a", "b", ""])
        let huge = String(repeating: "let x = 1 ", count: 15_000)
        let oversized = PreviewSyntaxHighlighter.lines(huge, language: .swift)
        check(oversized.map(\.text).joined(separator: "\n") == huge && oversized.allSatisfy { $0.spans.isEmpty })
        let blocks = PreviewMarkdownBlock.parse("```python\ndef run():\n    return True\n```\n\n~~~ts\nconst x = 1\n~~~")
        check(blocks.count == 2 && blocks[0].language == .python && blocks[1].language == .javascript)
        check(PreviewMarkdownBlock.parse("```unknown\nx\n```")[0].language == .plain)
        let cache = PreviewSyntaxCache()
        let input = PreviewSyntaxInput(text: "let x = 1", language: .swift)
        await cache.update(input)
        check(cache.lines(for: input)[0].spans.contains { $0.kind == .keyword })
        await cache.update(input)
        check(cache.lines(for: input)[0].text == input.text)
        let changed = PreviewSyntaxInput(text: "newest", language: .plain)
        check(cache.lines(for: changed)[0].text == "newest")
        let cancelled = Task { await cache.update(changed) }
        cancelled.cancel(); await cancelled.value
        check(cache.lines(for: input)[0].text == input.text)
        let newest = PreviewSyntaxInput(text: String(repeating: "let value = 1\n", count: 5000), language: .swift)
        let refresh = Task { await cache.update(newest) }
        await Task.yield()
        let stale = Task { await cache.update(changed) }
        stale.cancel(); await stale.value; await refresh.value
        check(cache.lines(for: newest)[0].spans.contains { $0.kind == .keyword })
        print("PASS \(checks) lexical syntax, extension/fence, Unicode/text preservation, no-link attributes, palette and cache checks; no code execution/downloads")
    }
}
