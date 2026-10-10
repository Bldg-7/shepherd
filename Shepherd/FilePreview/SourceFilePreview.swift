import SwiftUI

/// A vertical-only scroll view supplies a finite width to each source row.
/// Wrapped fragments keep their original line number; geometry changes alter
/// wrapping, not the file request or its cached lexical tokens.
struct SourceFilePreview: View {
    let text: String
    var selectedLine: Int?
    var language: PreviewSyntaxLanguage = .plain
    @State private var cache = PreviewSyntaxCache()
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .callout) private var baseGutter: CGFloat = 42
    private var input: PreviewSyntaxInput { .init(text: text, language: language) }

    var body: some View {
        let lines = cache.lines(for: input)
        let gutter = baseGutter * max(1, CGFloat(String(lines.count).count) / 4)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: String(line.id + 1))
                                .foregroundStyle(.secondary)
                                .frame(width: gutter, alignment: .trailing)
                            Text(line.text.isEmpty ? AttributedString(" ") : PreviewSyntaxRendering.attributed(line, scheme: scheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedLine == line.id + 1 ? Color.accentColor.opacity(0.14) : .clear)
                        .id(line.id + 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .textSelection(.enabled)
            }
            .onAppear { scrollToLine(proxy) }
            .onChange(of: selectedLine) { _, _ in scrollToLine(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: input) { await cache.update(input) }
    }

    private func scrollToLine(_ proxy: ScrollViewProxy) {
        if let selectedLine { proxy.scrollTo(selectedLine, anchor: .topLeading) }
    }
}
