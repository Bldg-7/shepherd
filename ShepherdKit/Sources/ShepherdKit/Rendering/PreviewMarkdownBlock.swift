import Foundation

/// Display-only metadata: no YAML tags, aliases, templates, or expressions
/// are evaluated. Nested/multiline values remain literal and readable.
public nonisolated struct PreviewFrontmatterField: Identifiable, Sendable {
    public let id: Int
    public let key: String
    public let value: String
    public static func parse(_ text: String, separator: Character) -> [Self] {
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
public nonisolated struct PreviewMarkdownBlock: Identifiable, Sendable {
    public enum Kind: Sendable {
        case heading(Int), paragraph, code, quote, rule, frontmatter
        case listItem(marker: String, depth: Int, checked: Bool?)
        case table
    }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let language: PreviewSyntaxLanguage
    public let rows: [[String]]
    /// The 1-based line of the file the block starts on, as the source view
    /// numbers it.
    public let line: Int
    public init(id: Int, kind: Kind, text: String, language: PreviewSyntaxLanguage = .plain, rows: [[String]] = [], line: Int = 1) {
        self.id = id; self.kind = kind; self.text = text; self.language = language; self.rows = rows; self.line = line
    }

    /// A frontmatter block's fields, as the rendering shows them.
    public var frontmatterFields: [PreviewFrontmatterField] {
        PreviewFrontmatterField.parse(text, separator: language == .toml ? "=" : ":")
    }

    /// What the block is known by in the preview's scroll view, to be
    /// scrolled to. Not a bare Int, which a frontmatter field or a table row
    /// inside a block also has.
    public var anchor: PreviewBlockAnchor { PreviewBlockAnchor(block: id) }

    /// Inline Markdown as the preview renders it: emphasis, code and links,
    /// with its whitespace kept.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    /// The text's lines, broken at LF and CRLF, each with the line of the
    /// file it starts on as the source view numbers lines. The source view
    /// breaks at every newline character, so a lone CR or U+2028 inside a
    /// Markdown line starts another line there.
    public static func lines(_ text: String, cancellable: Bool = false) -> (lines: [String], starts: [Int]) {
        var lines: [String] = [], starts: [Int] = []
        var start = text.startIndex, sourceLine = 1, lineStart = 1, visited = 0
        for index in text.indices {
            visited += 1
            if cancellable && visited % 4096 == 0 && Task.isCancelled { return ([], []) }
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

    public static func parse(_ text: String, cancellable: Bool = false) -> [Self] {
        var (lines, starts) = Self.lines(text, cancellable: cancellable)
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
            if cancellable && Task.isCancelled { return [] }
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
public nonisolated struct PreviewBlockAnchor: Hashable, Sendable {
    public let block: Int
    public init(block: Int) { self.block = block }
}

