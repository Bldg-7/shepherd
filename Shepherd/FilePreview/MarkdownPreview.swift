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
    init(id: Int, kind: Kind, text: String, language: PreviewSyntaxLanguage = .plain, rows: [[String]] = []) {
        self.id = id; self.kind = kind; self.text = text; self.language = language; self.rows = rows
    }

    static func parse(_ text: String) -> [Self] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.first == "\u{feff}" { lines[0].removeFirst() }
        var blocks: [Self] = [], pending: [String] = []
        var index = 0
        func append(_ kind: Kind, _ text: String, language: PreviewSyntaxLanguage = .plain, rows: [[String]] = []) {
            blocks.append(Self(id: blocks.count, kind: kind, text: text, language: language, rows: rows))
        }
        func flush() { if !pending.isEmpty { append(.paragraph, pending.joined(separator: "\n")); pending = [] } }
        // Frontmatter is recognized only at document start and only when
        // closed; an unclosed opening --- remains ordinary Markdown.
        if let first = lines.first, first == "---" || first == "+++",
           let end = lines.indices.dropFirst().first(where: { lines[$0] == first || (first == "---" && lines[$0] == "...") }) {
            append(.frontmatter, lines[1..<end].joined(separator: "\n"), language: first == "---" ? .yaml : .toml)
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
                    append(.code, code.joined(separator: "\n"), language: language); continue
                }
            }
            if !pending.isEmpty, (trimmed.allSatisfy { $0 == "=" } || (trimmed.count >= 2 && trimmed.allSatisfy { $0 == "-" })) {
                append(.heading(trimmed.first == "=" ? 1 : 2), pending.joined(separator: " ")); pending = []; continue
            }
            let depth = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(depth), trimmed.dropFirst(depth).first?.isWhitespace == true {
                flush(); append(.heading(depth), String(trimmed.dropFirst(depth)).trimmingCharacters(in: .whitespaces)); continue
            }
            let compact = trimmed.filter { !$0.isWhitespace }
            if compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first), compact.allSatisfy({ $0 == first }) {
                flush(); append(.rule, ""); continue
            }
            if trimmed.hasPrefix(">") {
                flush(); var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                append(.quote, quote.joined(separator: "\n")); continue
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
                append(.listItem(marker: marker, depth: min(8, indent / 2), checked: checked), body); continue
            }
            let headers = cells(line)
            if line.contains("|"), index < lines.count, tableSeparator(lines[index], count: headers.count) {
                flush(); index += 1; var rows = [headers]
                while index < lines.count, lines[index].contains("|"), rows.count * headers.count < 4096 {
                    let row = cells(lines[index]); guard row.count <= 32 else { break }
                    rows.append(Array((row + Array(repeating: "", count: headers.count)).prefix(headers.count))); index += 1
                }
                append(.table, "", rows: rows); continue
            }
            pending.append(line)
        }
        flush(); return blocks
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
                case .frontmatter:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Frontmatter").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(PreviewFrontmatterField.parse(block.text, separator: block.language == .toml ? "=" : ":")) { field in
                            HStack(alignment: .top, spacing: 12) {
                                if !field.key.isEmpty { Text(verbatim: field.key).font(.callout.weight(.semibold)).frame(width: 100, alignment: .leading) }
                                Text(verbatim: field.value).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                case .code:
                    HighlightedCode(text: block.text, language: block.language)
                        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                case .listItem(let marker, let depth, let checked):
                    HStack(alignment: .top, spacing: 8) {
                        if let checked { Image(systemName: checked ? "checkmark.square" : "square").accessibilityLabel(checked ? "Checked" : "Unchecked") }
                        else { Text(verbatim: marker).monospacedDigit() }
                        Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, CGFloat(depth) * 16)
                case .quote:
                    HStack(alignment: .top) {
                        Rectangle().fill(.secondary).frame(width: 3)
                        Text(inline(block.text)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                case .table:
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ForEach(block.rows.indices, id: \.self) { row in
                                GridRow {
                                    ForEach(block.rows[row].indices, id: \.self) { col in
                                        Text(inline(block.rows[row][col])).fontWeight(row == 0 ? .semibold : .regular)
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
        .textSelection(.enabled)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
