import SwiftUI

/// Native, inert Markdown: no WebView, HTML execution, image fetch, or CSS.
/// Inline emphasis/links are Foundation Markdown; block layout is explicit.
nonisolated struct PreviewMarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable { case heading(Int), paragraph, code, quote, rule }
    let id: Int
    let kind: Kind
    let text: String
    let language: PreviewSyntaxLanguage

    init(id: Int, kind: Kind, text: String, language: PreviewSyntaxLanguage = .plain) {
        self.id = id; self.kind = kind; self.text = text; self.language = language
    }

    static func parse(_ text: String) -> [Self] {
        var blocks: [Self] = [], pending: [String] = [], code: [String] = []
        var fence: String?
        var codeLanguage = PreviewSyntaxLanguage.plain
        func append(_ kind: Kind, _ text: String, language: PreviewSyntaxLanguage = .plain) {
            blocks.append(Self(id: blocks.count, kind: kind, text: text, language: language))
        }
        func flush() { if !pending.isEmpty { append(.paragraph, pending.joined(separator: "\n")); pending = [] } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker) { append(.code, code.joined(separator: "\n"), language: codeLanguage); code = []; fence = nil }
                else { code.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); fence = String(trimmed.prefix(3))
                codeLanguage = .fence(trimmed.dropFirst(3).split(whereSeparator: { $0.isWhitespace }).first.map(String.init))
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            let depth = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(depth), trimmed.dropFirst(depth).first == " " {
                flush(); append(.heading(depth), String(trimmed.dropFirst(depth + 1))); continue
            }
            if ["---", "***", "___"].contains(trimmed) { flush(); append(.rule, ""); continue }
            if trimmed.hasPrefix("> ") { flush(); append(.quote, String(trimmed.dropFirst(2))); continue }
            // Preserve list line boundaries without pretending to implement
            // the entire CommonMark nesting/table grammar.
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush(); append(.paragraph, "• " + trimmed.dropFirst(2)); continue
            }
            pending.append(line)
        }
        flush()
        if fence != nil { append(.code, code.joined(separator: "\n"), language: codeLanguage) }
        return blocks
    }
}

struct MarkdownPreview: View {
    let text: String
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(PreviewMarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .heading(let depth):
                    Text(inline(block.text)).font(depth == 1 ? .title : depth == 2 ? .title2 : .headline).bold()
                case .paragraph:
                    Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading)
                case .code:
                    HighlightedCode(text: block.text, language: block.language)
                        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                case .quote:
                    HStack(alignment: .top) {
                        Rectangle().fill(.secondary).frame(width: 3)
                        Text(inline(block.text)).foregroundStyle(.secondary)
                    }
                case .rule: Divider()
                }
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
