import Foundation

/// Small, bounded lexical highlighting, not a compiler or a language server.
/// Unknown languages remain plain text. No grammar downloads or code execution.
nonisolated enum PreviewSyntaxLanguage: String, Sendable {
    case plain, swift, python, javascript, json, yaml, toml, shell, cFamily, rust, go, ruby, sql

    static func filename(_ path: String?) -> Self {
        guard let path else { return .plain }
        return switch (path as NSString).pathExtension.lowercased() {
        case "swift": .swift
        case "py", "pyi": .python
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": .javascript
        case "json", "jsonl": .json
        case "yaml", "yml": .yaml
        case "toml", "ini", "conf": .toml
        case "sh", "bash", "zsh": .shell
        case "c", "h", "cpp", "hpp", "cc", "m", "mm", "java", "kt": .cFamily
        case "rs": .rust
        case "go": .go
        case "rb": .ruby
        case "sql": .sql
        default: .plain
        }
    }

    static func fence(_ label: String?) -> Self {
        guard let label else { return .plain }
        return switch label.lowercased() {
        case "swift": .swift
        case "python", "py": .python
        case "javascript", "js", "jsx", "typescript", "ts", "tsx": .javascript
        case "json": .json
        case "yaml", "yml": .yaml
        case "toml", "ini": .toml
        case "sh", "shell", "bash", "zsh": .shell
        case "c", "cpp", "c++", "objc", "objective-c", "java", "kotlin": .cFamily
        case "rust", "rs": .rust
        case "go", "golang": .go
        case "ruby", "rb": .ruby
        case "sql": .sql
        default: .plain
        }
    }

    var hashComments: Bool { [.python, .yaml, .toml, .shell, .ruby].contains(self) }
    var slashComments: Bool { [.swift, .javascript, .cFamily, .rust, .go].contains(self) }
    var keywords: Set<String> {
        let words: String
        switch self {
        case .plain: words = ""
        case .swift: words = "actor any as async await associatedtype break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is isolated let macro mutating nil nonisolated open override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while"
        case .python: words = "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"
        case .javascript: words = "abstract as async await break case catch class const continue debugger declare default delete do else enum export extends false finally for from function if implements import in instanceof interface keyof let new null of private protected public readonly return static super switch this throw true try type typeof undefined var void while yield"
        case .json: words = "true false null"
        case .yaml, .toml: words = "true false null yes no on off"
        case .shell: words = "if then else elif fi for while until do done case esac in function select return export local readonly declare unset exit"
        case .cFamily: words = "abstract auto bool break case catch char class const continue default delete do double else enum extern false final float for friend if import int interface long namespace new nullptr override package private protected public return short signed sizeof static struct super switch template this throw true try typedef typename union unsigned using virtual void volatile while"
        case .rust: words = "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
        case .go: words = "break case chan const continue default defer else fallthrough for func go goto if import interface map nil package range return select struct switch type var true false"
        case .ruby: words = "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield"
        case .sql: words = "select from where join inner outer left right full on as insert into values update set delete create table drop alter index primary key foreign references null not and or is like in exists case when then else end group by order having limit offset distinct union all true false asc desc"
        }
        return Set(words.split(separator: " ").map(String.init))
    }
}

nonisolated enum PreviewSyntaxKind: String, Sendable { case keyword, string, comment, number, type, function, property }
nonisolated struct PreviewSyntaxSpan: Equatable, Sendable {
    let range: Range<Int> // Character offsets, never byte offsets inside a glyph.
    let kind: PreviewSyntaxKind
}
nonisolated struct PreviewSyntaxLine: Identifiable, Sendable {
    let id: Int
    let text: String
    let spans: [PreviewSyntaxSpan]
}

nonisolated enum PreviewSyntaxHighlighter {
    static let maximumCharacters = 120_000

    static func lines(_ text: String, language: PreviewSyntaxLanguage) -> [PreviewSyntaxLine] {
        let chars = Array(text)
        let spans = language == .plain || chars.count > maximumCharacters ? [] : tokenize(chars, language: language)
        var result: [PreviewSyntaxLine] = [], start = 0, token = 0
        for end in 0...chars.count {
            guard end == chars.count || chars[end].isNewline else { continue }
            while token < spans.count && spans[token].range.upperBound <= start { token += 1 }
            var fragments: [PreviewSyntaxSpan] = [], cursor = token
            while cursor < spans.count && spans[cursor].range.lowerBound < end {
                let span = spans[cursor]
                let a = max(start, span.range.lowerBound), b = min(end, span.range.upperBound)
                if a < b { fragments.append(.init(range: (a - start)..<(b - start), kind: span.kind)) }
                cursor += 1
            }
            result.append(.init(id: result.count, text: String(chars[start..<end]), spans: fragments))
            start = end + 1
        }
        return result
    }

    private static func tokenize(_ chars: [Character], language: PreviewSyntaxLanguage) -> [PreviewSyntaxSpan] {
        var spans: [PreviewSyntaxSpan] = [], i = 0
        let words = language.keywords, n = chars.count
        func matches(_ pattern: String, at index: Int) -> Bool {
            let pattern = Array(pattern)
            guard index + pattern.count <= n else { return false }
            return chars[index..<(index + pattern.count)].elementsEqual(pattern)
        }
        func nextNonSpace(_ index: Int) -> Character? {
            var j = index
            while j < n && chars[j].isWhitespace { j += 1 }
            return j < n ? chars[j] : nil
        }
        func emit(_ start: Int, _ end: Int, _ kind: PreviewSyntaxKind) {
            if start < end { spans.append(.init(range: start..<end, kind: kind)) }
        }
        while i < n {
            if i % 4096 == 0 && Task.isCancelled { return [] }
            let start = i, c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if (language.hashComments && c == "#") || (language.slashComments && matches("//", at: i)) || (language == .sql && matches("--", at: i)) {
                while i < n && !chars[i].isNewline { i += 1 }
                emit(start, i, .comment); continue
            }
            if (language.slashComments || language == .sql) && matches("/*", at: i) {
                i += 2
                var depth = 1
                while i < n && depth > 0 {
                    if matches("*/", at: i) { depth -= 1; i += 2 }
                    else if (language == .swift || language == .rust) && matches("/*", at: i) { depth += 1; i += 2 }
                    else { i += 1 }
                }
                emit(start, i, .comment); continue
            }
            let singleQuote = c == "'" && language != .swift && language != .json
            let lifetime = language == .rust && singleQuote && i + 2 < n && chars[i + 1].isLetter && chars[i + 2] != "'"
            if c == "\"" || (singleQuote && !lifetime) || (c == "`" && [.javascript, .shell, .go, .ruby].contains(language)) {
                let triple = (language == .python || language == .swift) && matches(String(repeating: String(c), count: 3), at: i)
                let delimiter = String(repeating: String(c), count: triple ? 3 : 1)
                i += triple ? 3 : 1
                while i < n {
                    if chars[i] == "\\" { i = min(n, i + 2); continue }
                    if matches(delimiter, at: i) { i += triple ? 3 : 1; break }
                    if chars[i].isNewline && !triple && ![.javascript, .shell, .ruby, .go, .sql].contains(language) { break }
                    i += 1
                }
                emit(start, i, language == .json && nextNonSpace(i) == ":" ? .property : .string)
                continue
            }
            if c.isASCII && c.isNumber {
                i += 1
                if c == "0", i < n, "xXoObB".contains(chars[i]) {
                    i += 1
                    while i < n && "0123456789abcdefABCDEF_".contains(chars[i]) { i += 1 }
                } else {
                    while i < n && (chars[i].isNumber || chars[i] == "_") { i += 1 }
                    if i + 1 < n && chars[i] == "." && chars[i + 1].isNumber {
                        i += 1; while i < n && (chars[i].isNumber || chars[i] == "_") { i += 1 }
                    }
                    if i < n && (chars[i] == "e" || chars[i] == "E") {
                        i += 1; if i < n && (chars[i] == "+" || chars[i] == "-") { i += 1 }
                        while i < n && chars[i].isNumber { i += 1 }
                    }
                }
                emit(start, i, .number); continue
            }
            if c.isLetter || c == "_" || (language == .shell && c == "$") {
                i += 1
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                let word = String(chars[start..<i])
                if words.contains(language == .sql ? word.lowercased() : word) { emit(start, i, .keyword) }
                else if [.yaml, .toml].contains(language) && (nextNonSpace(i) == ":" || nextNonSpace(i) == "=") { emit(start, i, .property) }
                else if nextNonSpace(i) == "(" { emit(start, i, .function) }
                else if c.isUppercase { emit(start, i, .type) }
                else if c == "$" { emit(start, i, .property) }
                continue
            }
            i += 1
        }
        return spans
    }
}
