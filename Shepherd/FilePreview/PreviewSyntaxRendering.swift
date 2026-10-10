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

    static func attributed(_ line: PreviewSyntaxLine, scheme: ColorScheme) -> AttributedString {
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
}

/// Also used for Markdown fenced code. Text is literal attributed source, not
/// rendered HTML/Markdown, and has no link or executable attributes.
struct HighlightedCode: View {
    let text: String
    var language: PreviewSyntaxLanguage = .plain
    @State private var cache = PreviewSyntaxCache()
    @Environment(\.colorScheme) private var scheme
    private var input: PreviewSyntaxInput { .init(text: text, language: language) }

    var body: some View {
        let lines = cache.lines(for: input)
        let attributed = lines.enumerated().reduce(into: AttributedString()) { result, pair in
            if pair.offset > 0 { result.append(AttributedString("\n")) }
            result.append(PreviewSyntaxRendering.attributed(pair.element, scheme: scheme))
        }
        Text(attributed)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .task(id: input) { await cache.update(input) }
    }
}
