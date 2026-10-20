import SwiftUI

/// One text a preview shows, as its find bar looks in it: a line of the
/// source view, or one text of a block of the Markdown rendering.
nonisolated struct PreviewFindText: Equatable, Sendable {
    /// The row it is in: a 1-based line of the source view, or the `id` of
    /// a block of the rendering.
    let row: Int
    /// Which text of the row it is: 0 for a line, and for a block of text or
    /// code. A table's cells are numbered row by row, left to right; a
    /// frontmatter's fields by key and value, 2n and 2n + 1 for field n.
    let part: Int
    let text: String
    /// About which line of its row the text starts on, and how many lines
    /// the row takes, lines being counted `PreviewFind.lineWidth` characters
    /// wide: to bring a match in a row too tall to be shown whole roughly
    /// into view.
    var line = 0
    var rowLines = 1
}

/// A match of the find bar: the text it is in (see `PreviewFindText`), where
/// in it by Unicode scalar offsets, and roughly where it is in its row, from
/// 0 at its top to 1 at its bottom — 0 in a row short enough to be shown
/// whole (see `PreviewScrollRequest.Target`).
nonisolated struct PreviewFindMatch: Equatable, Sendable {
    let row: Int
    let part: Int
    let range: Range<Int>
    let place: Double
}

/// Finds what a preview's find bar looks for in the text the preview shows:
/// in the lines of the source view, or in what the Markdown rendering shows —
/// its text without the Markdown, link targets left out, and its code,
/// tables and frontmatter. Case is ignored, and a character composed or not
/// (NFC or NFD) is the same character.
enum PreviewFind {
    /// How many characters wide a line is counted, to tell roughly where a
    /// match is in a tall row.
    static let lineWidth = 80
    /// A row taller than this many lines may not be shown whole: a match in
    /// it is brought into view at its place in the row, not with its top.
    static let tallRow = 30

    /// The source view's lines, as it breaks and numbers them, empty ones
    /// left out.
    static func sourceTexts(_ text: String) -> [PreviewFindText] {
        PreviewSyntaxHighlighter.lines(text, language: .plain).compactMap { line in
            line.text.isEmpty ? nil : PreviewFindText(row: line.id + 1, part: 0, text: line.text, rowLines: lineCount(line.text))
        }
    }

    /// What the Markdown rendering of `document` shows, block by block.
    static func renderedTexts(_ document: PreviewMarkdownDocument) -> [PreviewFindText] {
        var texts: [PreviewFindText] = []
        for block in document.blocks {
            func add(_ text: String, part: Int = 0, line: Int = 0, rowLines: Int? = nil) {
                guard !text.isEmpty else { return }
                texts.append(PreviewFindText(row: block.id, part: part, text: text, line: line, rowLines: rowLines ?? lineCount(text)))
            }
            switch block.kind {
            case .heading, .paragraph, .listItem, .quote:
                add(String(document.inline(block.text).characters))
            case .code:
                add(block.text)
            case .frontmatter:
                // One field under another, each as tall as its value.
                let fields = block.frontmatterFields
                let total = fields.reduce(0) { $0 + lineCount($1.value) }
                var line = 0
                for field in fields {
                    add(field.key, part: 2 * field.id, line: line, rowLines: total)
                    add(field.value, part: 2 * field.id + 1, line: line, rowLines: total)
                    line += lineCount(field.value)
                }
            case .table:
                // One row under another, a line each: the table scrolls
                // sideways rather than wrap its cells.
                for (index, row) in block.rows.enumerated() {
                    for (column, cell) in row.enumerated() {
                        add(String(document.inline(cell).characters), part: index * row.count + column, line: index, rowLines: block.rows.count)
                    }
                }
            case .rule:
                break
            }
        }
        return texts
    }

    /// Where `query` is in `text`, case ignored, by Unicode scalar offsets,
    /// in order and apart. None for an empty query.
    static func ranges(of query: String, in text: String) -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        let scalars = text.unicodeScalars
        var found: [Range<Int>] = [], from = text.startIndex, counted = text.startIndex, offset = 0
        while from < text.endIndex, let match = text.range(of: query, options: .caseInsensitive, range: from..<text.endIndex),
              !match.isEmpty {
            let lower = offset + scalars.distance(from: counted, to: match.lowerBound)
            let upper = lower + scalars.distance(from: match.lowerBound, to: match.upperBound)
            found.append(lower..<upper)
            counted = match.upperBound; offset = upper; from = match.upperBound
        }
        return found
    }

    /// The matches of `query` in `texts`, in the order they are shown.
    static func matches(of query: String, in texts: [PreviewFindText]) -> [PreviewFindMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [PreviewFindMatch] = []
        for text in texts {
            let ranges = ranges(of: query, in: text.text)
            guard !ranges.isEmpty else { continue }
            var lines = LineCounter(text.text)
            for range in ranges {
                let place = text.rowLines > tallRow
                    ? min(1, Double(text.line + lines.line(at: range.lowerBound)) / Double(text.rowLines)) : 0
                matches.append(PreviewFindMatch(row: text.row, part: text.part, range: range, place: place))
            }
        }
        return matches
    }

    /// The first match in a row at or after `row`, the first row shown;
    /// past the last, the first of all. Nil with no matches.
    static func first(_ matches: [PreviewFindMatch], atOrAfter row: Int?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let row else { return 0 }
        return matches.firstIndex { $0.row >= row } ?? 0
    }

    /// The last match in a row before `row`, the first row shown; before
    /// the first, the last of all. Nil with no matches.
    static func last(_ matches: [PreviewFindMatch], before row: Int?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let row else { return matches.count - 1 }
        return matches.lastIndex { $0.row < row } ?? matches.count - 1
    }

    /// The match `by` matches on from `current` among `count`, going round
    /// from the last to the first and from the first to the last.
    static func step(from current: Int, by: Int, count: Int) -> Int {
        ((current + by) % count + count) % count
    }

    /// The match the find bar is at among `count` matches: `current`, the
    /// one it was at, or the last when there are fewer now. Nil with none.
    static func current(_ current: Int?, count: Int) -> Int? {
        guard count > 0, let current else { return nil }
        return min(max(0, current), count - 1)
    }

    /// `matches` as their texts mark them, `current` being the one the bar
    /// is at.
    static func marks(_ matches: [PreviewFindMatch], current: Int?) -> PreviewFindMarks {
        var rows: [Int: [Int: [PreviewFindMark]]] = [:]
        for (index, match) in matches.enumerated() {
            rows[match.row, default: [:]][match.part, default: []].append(PreviewFindMark(range: match.range, isCurrent: index == current))
        }
        return PreviewFindMarks(rows: rows)
    }

    /// How many lines `text` takes, `lineWidth` characters wide.
    static func lineCount(_ text: String) -> Int {
        var lines = LineCounter(text)
        return lines.line(at: Int.max) + 1
    }

    /// Counts the lines of a text up to Unicode scalar offsets, in order.
    private struct LineCounter {
        let scalars: String.UnicodeScalarView
        var index: String.UnicodeScalarView.Index
        var offset = 0, line = 0, column = 0

        init(_ text: String) {
            scalars = text.unicodeScalars
            index = scalars.startIndex
        }

        /// The 0-based line `target` is on. Targets come in order.
        mutating func line(at target: Int) -> Int {
            while offset < target, index < scalars.endIndex {
                switch scalars[index].value {
                case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
                    line += 1; column = 0
                default:
                    column += 1
                    if column == PreviewFind.lineWidth { line += 1; column = 0 }
                }
                index = scalars.index(after: index); offset += 1
            }
            return line
        }
    }
}

/// The find bar's matches in what a preview shows, worked out once for each
/// text, view and query rather than each time the panel is drawn — and again
/// whenever the text shown is another.
final class PreviewFindCache {
    private var text: String?
    private var document: PreviewMarkdownDocument?
    private var texts: [PreviewFindText] = []
    private var query: String?
    private var found: [PreviewFindMatch] = []
    private var marked: (current: Int?, marks: PreviewFindMarks)?

    /// The matches of `query` in `text` as the source view shows it, or in
    /// `rendering`, the Markdown rendering of it.
    func matches(of query: String, in text: String, rendering: PreviewMarkdownDocument?) -> [PreviewFindMatch] {
        // The same read is the same string: this compares no characters.
        if self.text != text || document !== rendering {
            self.text = text; document = rendering
            texts = rendering.map { PreviewFind.renderedTexts($0) } ?? PreviewFind.sourceTexts(text)
            self.query = nil
        }
        if self.query != query {
            self.query = query
            found = PreviewFind.matches(of: query, in: texts)
            marked = nil
        }
        return found
    }

    /// The marks of the matches last asked for, `current` being the one the
    /// find bar is at.
    func marks(current: Int?) -> PreviewFindMarks {
        if let marked, marked.current == current { return marked.marks }
        let marks = PreviewFind.marks(found, current: current)
        marked = (current, marks)
        return marks
    }
}
