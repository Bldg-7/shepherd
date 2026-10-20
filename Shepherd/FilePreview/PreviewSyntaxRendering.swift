import SwiftUI
import Observation

nonisolated struct PreviewSyntaxInput: Hashable, Sendable {
    let text: String
    let language: PreviewSyntaxLanguage
}

/// Parse once per source/language, not on every geometry or color-scheme change.
@MainActor @Observable final class PreviewSyntaxCache {
    private var input: PreviewSyntaxInput?
    private var parsed: [PreviewSyntaxLine] = []
    private var epoch = UUID()

    func lines(for requested: PreviewSyntaxInput) -> [PreviewSyntaxLine] {
        input == requested ? parsed : PreviewSyntaxHighlighter.lines(requested.text, language: .plain)
    }

    func update(_ requested: PreviewSyntaxInput) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        epoch = generation
        guard input != requested else { return }
        let work = Task.detached(priority: .userInitiated) {
            PreviewSyntaxHighlighter.lines(requested.text, language: requested.language)
        }
        let lines = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled, epoch == generation else { return }
        parsed = lines; input = requested
    }
}

@MainActor enum PreviewSyntaxRendering {
    static func color(_ kind: PreviewSyntaxKind, scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch kind {
        case .keyword: return dark ? Color(red: 0.82, green: 0.62, blue: 0.99) : Color(red: 0.48, green: 0.20, blue: 0.70)
        case .string: return dark ? Color(red: 0.58, green: 0.84, blue: 0.60) : Color(red: 0.12, green: 0.42, blue: 0.20)
        case .comment: return dark ? Color(red: 0.65, green: 0.68, blue: 0.71) : Color(red: 0.40, green: 0.43, blue: 0.46)
        case .number: return dark ? Color(red: 0.98, green: 0.75, blue: 0.43) : Color(red: 0.65, green: 0.30, blue: 0.08)
        case .type: return dark ? Color(red: 0.48, green: 0.78, blue: 0.97) : Color(red: 0.12, green: 0.36, blue: 0.70)
        case .function: return dark ? Color(red: 0.45, green: 0.84, blue: 0.86) : Color(red: 0.08, green: 0.40, blue: 0.45)
        case .property: return dark ? Color(red: 0.88, green: 0.73, blue: 0.54) : Color(red: 0.55, green: 0.34, blue: 0.13)
        }
    }

    /// The line as the source view shows it: its tokens colored, and the
    /// find bar's matches in it marked.
    static func attributed(_ line: PreviewSyntaxLine, scheme: ColorScheme, marks: [PreviewFindMark] = []) -> AttributedString {
        marked(colored(line, scheme: scheme), marks)
    }

    private static func colored(_ line: PreviewSyntaxLine, scheme: ColorScheme) -> AttributedString {
        let chars = Array(line.text)
        var result = AttributedString(), position = 0
        for span in line.spans {
            if span.range.lowerBound > position {
                result.append(AttributedString(String(chars[position..<span.range.lowerBound])))
            }
            var token = AttributedString(String(chars[span.range]))
            token.foregroundColor = color(span.kind, scheme: scheme)
            result.append(token)
            position = span.range.upperBound
        }
        if position < chars.count { result.append(AttributedString(String(chars[position...]))) }
        return result
    }

    /// The background of a match of the find bar, and of the one it is at.
    static let matchBackground = Color.yellow.opacity(0.35)
    static let currentMatchBackground = Color.orange.opacity(0.75)

    /// `text` with `marks`, the find bar's matches in it, on their
    /// backgrounds. Marks are by Unicode scalar, in order and apart; one
    /// past the end of `text` is left out.
    static func marked(_ text: AttributedString, _ marks: [PreviewFindMark]) -> AttributedString {
        guard !marks.isEmpty else { return text }
        let scalars = text.unicodeScalars
        let count = scalars.count
        var result = AttributedString(), index = text.startIndex, offset = 0
        for mark in marks where mark.range.lowerBound >= offset && mark.range.upperBound <= count {
            let start = scalars.index(index, offsetBy: mark.range.lowerBound - offset)
            let end = scalars.index(start, offsetBy: mark.range.count)
            result.append(text[index..<start])
            var match = AttributedString(text[start..<end])
            match.backgroundColor = mark.isCurrent ? currentMatchBackground : matchBackground
            result.append(match)
            index = end; offset = mark.range.upperBound
        }
        result.append(text[index...])
        return result
    }
}

/// A match of a preview's find bar in one text the preview shows: where it
/// is, by Unicode scalar offsets in that text, and whether it is the match
/// the bar is at.
nonisolated struct PreviewFindMark: Equatable, Sendable {
    let range: Range<Int>
    let isCurrent: Bool
}

/// The find bar's matches in what a preview shows, by the row each is in —
/// a source line, by its 1-based number, or a block of the Markdown
/// rendering, by its `id` — and by which text of the row (see
/// `PreviewFindText.part`).
nonisolated struct PreviewFindMarks: Sendable {
    static let none = PreviewFindMarks(rows: [:])
    let rows: [Int: [Int: [PreviewFindMark]]]

    /// The marks in `part` of `row`, in order.
    func callAsFunction(row: Int, part: Int = 0) -> [PreviewFindMark] {
        rows[row]?[part] ?? []
    }
}

/// Also used for Markdown fenced code. Text is literal attributed source, not
/// rendered HTML/Markdown, and has no link or executable attributes.
struct HighlightedCode: View {
    let text: String
    var language: PreviewSyntaxLanguage = .plain
    /// The find bar's matches in `text`.
    var marks: [PreviewFindMark] = []
    @State private var cache = PreviewSyntaxCache()
    @Environment(\.colorScheme) private var scheme
    private var input: PreviewSyntaxInput { .init(text: text, language: language) }

    var body: some View {
        let lines = cache.lines(for: input)
        let attributed = lines.enumerated().reduce(into: AttributedString()) { result, pair in
            if pair.offset > 0 { result.append(AttributedString("\n")) }
            result.append(PreviewSyntaxRendering.attributed(pair.element, scheme: scheme))
        }
        Text(PreviewSyntaxRendering.marked(attributed, marks))
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: input) { await cache.update(input) }
    }
}
