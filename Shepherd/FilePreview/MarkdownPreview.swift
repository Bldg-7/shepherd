import SwiftUI

/// Display-only metadata: no YAML tags, aliases, templates, or expressions
/// are evaluated. Nested/multiline values remain literal and readable.
nonisolated struct PreviewFrontmatterField: Identifiable, Sendable {
    let id: Int
    let key: String
    let value: String
    static func parse(_ text: String, separator: Character) -> [Self] {
        var fields: [Self] = [], key: String?, value: [String] = []
        func flush() {
            if let key { fields.append(Self(id: fields.count, key: key, value: value.joined(separator: "\n"))) }
            key = nil; value = []
        }
        for line in text.components(separatedBy: "\n") {
            if !line.isEmpty, line.first?.isWhitespace == false,
               !line.hasPrefix("#"), let split = line.firstIndex(of: separator) {
                let name = line[..<split].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { flush(); key = name; value = [line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)]; continue }
            }
            if key != nil { value.append(line) }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                fields.append(Self(id: fields.count, key: "", value: line))
            }
        }
        flush(); return fields
    }
}

/// Native, inert Markdown: no WebView, HTML execution, image fetch, or CSS.
/// Foundation parses inline Markdown; bounded block layout is explicit.
nonisolated struct PreviewMarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable {
        case heading(Int), paragraph, code, quote, rule, frontmatter
        case listItem(marker: String, depth: Int, checked: Bool?)
        case table
    }
    let id: Int
    let kind: Kind
    let text: String
    let language: PreviewSyntaxLanguage
    let rows: [[String]]
    /// The 1-based line of the file the block starts on, as the source view
    /// numbers it.
    let line: Int
    init(id: Int, kind: Kind, text: String, language: PreviewSyntaxLanguage = .plain, rows: [[String]] = [], line: Int = 1) {
        self.id = id; self.kind = kind; self.text = text; self.language = language; self.rows = rows; self.line = line
    }

    /// A frontmatter block's fields, as the rendering shows them.
    var frontmatterFields: [PreviewFrontmatterField] {
        PreviewFrontmatterField.parse(text, separator: language == .toml ? "=" : ":")
    }

    /// What the block is known by in the preview's scroll view, to be
    /// scrolled to. Not a bare Int, which a frontmatter field or a table row
    /// inside a block also has.
    var anchor: PreviewBlockAnchor { PreviewBlockAnchor(block: id) }

    /// Inline Markdown as the preview renders it: emphasis, code and links,
    /// with its whitespace kept.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// The text's lines, broken at LF and CRLF, each with the line of the
    /// file it starts on as the source view numbers lines. The source view
    /// breaks at every newline character, so a lone CR or U+2028 inside a
    /// Markdown line starts another line there.
    static func lines(_ text: String) -> (lines: [String], starts: [Int]) {
        var lines: [String] = [], starts: [Int] = []
        var start = text.startIndex, sourceLine = 1, lineStart = 1
        for index in text.indices {
            let character = text[index]
            if character == "\n" || character == "\r\n" {
                lines.append(String(text[start..<index])); starts.append(lineStart)
                start = text.index(after: index); sourceLine += 1; lineStart = sourceLine
            } else if character.isNewline {
                sourceLine += 1
            }
        }
        lines.append(String(text[start...])); starts.append(lineStart)
        return (lines, starts)
    }

    static func parse(_ text: String) -> [Self] {
        var (lines, starts) = Self.lines(text)
        if lines.first?.first == "\u{feff}" { lines[0].removeFirst() }
        var blocks: [Self] = [], pending: [String] = [], pendingStart = 0
        var index = 0
        // `first` is the index in `lines` of the block's first line.
        func append(_ kind: Kind, _ text: String, from first: Int, language: PreviewSyntaxLanguage = .plain, rows: [[String]] = []) {
            blocks.append(Self(id: blocks.count, kind: kind, text: text, language: language, rows: rows, line: starts[first]))
        }
        func flush() { if !pending.isEmpty { append(.paragraph, pending.joined(separator: "\n"), from: pendingStart); pending = [] } }
        // Frontmatter is recognized only at document start and only when
        // closed; an unclosed opening --- remains ordinary Markdown.
        if let first = lines.first, first == "---" || first == "+++",
           let end = lines.indices.dropFirst().first(where: { lines[$0] == first || (first == "---" && lines[$0] == "...") }) {
            append(.frontmatter, lines[1..<end].joined(separator: "\n"), from: 0, language: first == "---" ? .yaml : .toml)
            index = end + 1
        }
        func cells(_ line: String) -> [String] {
            var parts: [String] = [], current = "", escaped = false, inCode = false
            for char in line.trimmingCharacters(in: .whitespaces) {
                if escaped { current.append(char); escaped = false; continue }
                if char == "\\" { current.append(char); escaped = true; continue }
                if char == "`" { inCode.toggle() }
                if char == "|", !inCode { parts.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                else { current.append(char) }
            }
            parts.append(current.trimmingCharacters(in: .whitespaces))
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            return parts
        }
        func tableSeparator(_ line: String, count: Int) -> Bool {
            let parts = cells(line)
            return count > 1 && count <= 32 && parts.count == count && parts.allSatisfy {
                let t = $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return t.count >= 3 && t.allSatisfy { $0 == "-" }
            }
        }
        while index < lines.count {
            let start = index
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.isEmpty { flush(); continue }
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    flush()
                    let language = PreviewSyntaxLanguage.fence(trimmed.dropFirst(count).split(whereSeparator: \.isWhitespace).first.map(String.init))
                    var code: [String] = []
                    while index < lines.count {
                        let next = lines[index].trimmingCharacters(in: .whitespaces)
                        index += 1
                        let closeCount = next.prefix(while: { $0 == first }).count
                        if closeCount >= count && next.dropFirst(closeCount).trimmingCharacters(in: .whitespaces).isEmpty { break }
                        code.append(lines[index - 1])
                    }
                    append(.code, code.joined(separator: "\n"), from: start, language: language); continue
                }
            }
            if !pending.isEmpty, (trimmed.allSatisfy { $0 == "=" } || (trimmed.count >= 2 && trimmed.allSatisfy { $0 == "-" })) {
                append(.heading(trimmed.first == "=" ? 1 : 2), pending.joined(separator: " "), from: pendingStart); pending = []; continue
            }
            let depth = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(depth), trimmed.dropFirst(depth).first?.isWhitespace == true {
                flush(); append(.heading(depth), String(trimmed.dropFirst(depth)).trimmingCharacters(in: .whitespaces), from: start); continue
            }
            let compact = trimmed.filter { !$0.isWhitespace }
            if compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first), compact.allSatisfy({ $0 == first }) {
                flush(); append(.rule, "", from: start); continue
            }
            if trimmed.hasPrefix(">") {
                flush(); var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                append(.quote, quote.joined(separator: "\n"), from: start); continue
            }
            let indent = line.prefix(while: \.isWhitespace).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            var marker: String?, body = ""
            if trimmed.count >= 2, let first = trimmed.first, ["-", "*", "+"].contains(first), trimmed.dropFirst().first?.isWhitespace == true {
                marker = "•"; body = String(trimmed.dropFirst(2))
            } else {
                let digits = trimmed.prefix(while: \.isNumber)
                let tail = trimmed.dropFirst(digits.count)
                if !digits.isEmpty, digits.count <= 9, let first = tail.first, first == "." || first == ")", tail.dropFirst().first?.isWhitespace == true {
                    marker = String(digits) + "."; body = String(tail.dropFirst(2))
                }
            }
            if let marker {
                flush(); var checked: Bool?
                if body.hasPrefix("[ ] ") || body.lowercased().hasPrefix("[x] ") { checked = body.lowercased().hasPrefix("[x]"); body = String(body.dropFirst(4)) }
                append(.listItem(marker: marker, depth: min(8, indent / 2), checked: checked), body, from: start); continue
            }
            let headers = cells(line)
            if line.contains("|"), index < lines.count, tableSeparator(lines[index], count: headers.count) {
                flush(); index += 1; var rows = [headers]
                while index < lines.count, lines[index].contains("|"), rows.count * headers.count < 4096 {
                    let row = cells(lines[index]); guard row.count <= 32 else { break }
                    rows.append(Array((row + Array(repeating: "", count: headers.count)).prefix(headers.count))); index += 1
                }
                append(.table, "", from: start, rows: rows); continue
            }
            if pending.isEmpty { pendingStart = start }
            pending.append(line)
        }
        flush(); return blocks
    }
}

/// A Markdown block's place in the preview's scroll view (see
/// `PreviewMarkdownBlock.anchor`).
nonisolated struct PreviewBlockAnchor: Hashable, Sendable {
    let block: Int
}

/// A heading as the table of contents lists it.
nonisolated struct PreviewMarkdownHeading: Identifiable, Equatable, Sendable {
    /// The `id` of the heading's block.
    let id: Int
    /// 1 to 6: 1 for `#` and a `===` underline, 2 for `##` and a `---` one.
    let level: Int
    /// What the heading shows, without its Markdown: plain text on one line.
    let title: String
    /// The 1-based line of the file it starts on, as the source view numbers it.
    let line: Int

    /// The headings among `blocks`, those inside fenced code not being
    /// blocks. One that shows nothing, such as `## [](#top)`, is left out.
    static func headings(in blocks: [PreviewMarkdownBlock]) -> [Self] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            let title = String(PreviewMarkdownBlock.inline(block.text).characters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return title.isEmpty ? nil : Self(id: block.id, level: level, title: title, line: block.line)
        }
    }
}

/// One Markdown text as the preview shows it, worked out once for the text
/// rather than each time the preview is drawn: its blocks, with the line each
/// starts on, its headings, and the inline Markdown of its blocks and table
/// cells rendered, each text as it first comes on screen.
final class PreviewMarkdownDocument {
    let blocks: [PreviewMarkdownBlock]
    let headings: [PreviewMarkdownHeading]
    private var rendered: [String: AttributedString] = [:]

    init(_ text: String) {
        blocks = PreviewMarkdownBlock.parse(text)
        headings = PreviewMarkdownHeading.headings(in: blocks)
    }

    /// `markdown` rendered as inline Markdown, rendered once.
    func inline(_ markdown: String) -> AttributedString {
        if let done = rendered[markdown] { return done }
        let result = PreviewMarkdownBlock.inline(markdown)
        rendered[markdown] = result
        return result
    }
}

/// The rendering of a Markdown document, for a scroll view. Each block is
/// known by its `anchor`, which the scroll view can scroll to, and tells
/// `onBlockFrame` where it is laid out in the rendering, for the scroll view
/// to work out the blocks it shows (see `PreviewVisibleRows`). The find
/// bar's matches are marked where they are shown.
struct MarkdownPreview: View {
    let document: PreviewMarkdownDocument
    /// The find bar's matches, by block `id` and text of the block (see
    /// `PreviewFindText.part`).
    var marks: PreviewFindMarks = .none
    /// Told a block's frame in the rendering as the lazy stack lays it out,
    /// and nil when the stack lets go of it.
    var onBlockFrame: ((Int, CGRect?) -> Void)? = nil
    nonisolated private static let space = "preview.markdown"
    /// Inline Markdown of `block` as it is shown, with the find bar's
    /// matches in it: `part` of the block's texts.
    private func inline(_ text: String, in block: PreviewMarkdownBlock, part: Int = 0) -> AttributedString {
        PreviewSyntaxRendering.marked(document.inline(text), marks(row: block.id, part: part))
    }
    /// Literal text of `block` as it is shown, with the find bar's matches.
    private func literal(_ text: String, in block: PreviewMarkdownBlock, part: Int) -> AttributedString {
        PreviewSyntaxRendering.marked(AttributedString(text), marks(row: block.id, part: part))
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(document.blocks, id: \.anchor) { block in
                blockView(block)
                    .id(block.anchor)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onBlockFrame?(block.id, $0) }
                    .onDisappear { onBlockFrame?(block.id, nil) }
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rendering is the scroll view's content: its space is the
        // content's, in which the scroll view tells what part it shows.
        .coordinateSpace(.named(Self.space))
    }

    @ViewBuilder private func blockView(_ block: PreviewMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let depth):
            Text(inline(block.text, in: block)).font(depth == 1 ? .title : depth == 2 ? .title2 : .headline).bold()
        case .paragraph:
            Text(inline(block.text, in: block)).frame(maxWidth: .infinity, alignment: .leading)
        case .frontmatter:
            VStack(alignment: .leading, spacing: 8) {
                Text("Frontmatter").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(block.frontmatterFields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        if !field.key.isEmpty { Text(literal(field.key, in: block, part: 2 * field.id)).font(.callout.weight(.semibold)).frame(width: 100, alignment: .leading) }
                        Text(literal(field.value, in: block, part: 2 * field.id + 1)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .code:
            HighlightedCode(text: block.text, language: block.language, marks: marks(row: block.id))
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .listItem(let marker, let depth, let checked):
            HStack(alignment: .top, spacing: 8) {
                if let checked { Image(systemName: checked ? "checkmark.square" : "square").accessibilityLabel(checked ? "Checked" : "Unchecked") }
                else { Text(verbatim: marker).monospacedDigit() }
                Text(inline(block.text, in: block)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(depth) * 16)
        case .quote:
            HStack(alignment: .top) {
                Rectangle().fill(.secondary).frame(width: 3)
                Text(inline(block.text, in: block)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(block.rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(block.rows[row].indices, id: \.self) { col in
                                Text(inline(block.rows[row][col], in: block, part: row * block.rows[row].count + col)).fontWeight(row == 0 ? .semibold : .regular)
                                    .frame(minWidth: 80, alignment: .leading)
                            }
                        }
                    }
                }.padding(10)
            }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .rule: Divider()
        }
    }
}
