import Foundation
#if canImport(ShepherdKit)
import ShepherdKit
#endif

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
