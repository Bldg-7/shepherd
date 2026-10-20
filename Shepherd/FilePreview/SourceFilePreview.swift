import SwiftUI

/// A vertical-only scroll view supplies a finite width to each source row.
/// Wrapped fragments keep their original line number; geometry changes alter
/// wrapping, not the file request or its cached lexical tokens.
///
/// Each row is known by its 1-based line number: a `ScrollViewReader` around
/// this view scrolls to a line by its number, and `onVisibleLines` is told
/// the numbers of the lines shown. The find bar's matches are marked where
/// they are shown.
struct SourceFilePreview: View {
    let text: String
    var selectedLine: Int?
    var language: PreviewSyntaxLanguage = .plain
    /// Where to put the scroll view as it comes up, in place of the selected
    /// line: where it was left, for a preview that comes back with its pane.
    var restoredOffset: CGPoint? = nil
    /// Told where the scroll view is, each time it scrolls.
    var onScroll: ((CGPoint) -> Void)? = nil
    /// Told the 1-based numbers of the lines shown, in order, each time they
    /// change.
    var onVisibleLines: (([Int]) -> Void)? = nil
    /// The find bar's matches, by line number.
    var marks: PreviewFindMarks = .none
    @State private var cache = PreviewSyntaxCache()
    @State private var shownLines = PreviewVisibleRows()
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .callout) private var baseGutter: CGFloat = 42
    private var input: PreviewSyntaxInput { .init(text: text, language: language) }
    nonisolated private static let space = "preview.source"

    var body: some View {
        let lines = cache.lines(for: input)
        let gutter = baseGutter * max(1, CGFloat(String(lines.count).count) / 4)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.number) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: String(line.number))
                                .foregroundStyle(.secondary)
                                .frame(width: gutter, alignment: .trailing)
                            Text(line.text.isEmpty ? AttributedString(" ") : PreviewSyntaxRendering.attributed(line, scheme: scheme, marks: marks(row: line.number)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedLine == line.number ? Color.accentColor.opacity(0.14) : .clear)
                        .id(line.number)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                            report(shownLines.place(line.number, at: frame))
                        }
                        .onDisappear { report(shownLines.place(line.number, at: nil)) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .textSelection(.enabled)
                // The scroll view's content: its space is the content's, in
                // which the scroll view tells what part it shows.
                .coordinateSpace(.named(Self.space))
            }
            .modifier(PreviewScrollPlace(restoring: restoredOffset, onScroll: onScroll))
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, visible in
                report(shownLines.show(visible))
            }
            .onAppear { if restoredOffset == nil { scrollToLine(proxy) } }
            .onChange(of: selectedLine) { _, _ in scrollToLine(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: input) { await cache.update(input) }
    }

    private func scrollToLine(_ proxy: ScrollViewProxy) {
        if let selectedLine { proxy.scrollTo(selectedLine, anchor: .topLeading) }
    }

    private func report(_ lines: [Int]?) {
        if let lines { onVisibleLines?(lines) }
    }
}

extension PreviewSyntaxLine {
    /// The line's 1-based number, as the source view shows and knows it.
    nonisolated var number: Int { id + 1 }
}

/// Works out which rows of a lazy stack in a scroll view are shown: from
/// where each row the stack has made is laid out in the scroll view's
/// content, and the part of the content the scroll view shows. A row is
/// shown when any of it is. Rows are made, and let go of, as they come near
/// the part shown, so this follows a few dozen rows, not a whole document.
///
/// Not scroll targets (`scrollTargetLayout`), whose stack would change how a
/// place put back with `PreviewScrollPlace` comes out: lower by the stack's
/// top padding, and, after the view has been scrolled elsewhere, gone back
/// to whenever the content is laid out again.
final class PreviewVisibleRows {
    private var frames: [Int: Range<CGFloat>] = [:]
    private var visible: Range<CGFloat>?
    private var shown: [Int] = []

    /// Where `row` is laid out in the content, or nil once it is let go of.
    /// Returns the rows shown when that changes them.
    func place(_ row: Int, at frame: CGRect?) -> [Int]? {
        frames[row] = frame.map { $0.minY..<$0.maxY }
        return update()
    }

    /// The part of the content the scroll view shows. Returns the rows shown
    /// when that changes them.
    func show(_ rect: CGRect) -> [Int]? {
        visible = rect.minY..<rect.maxY
        return update()
    }

    private func update() -> [Int]? {
        guard let visible else { return nil }
        let rows = frames.compactMap { $0.value.overlaps(visible) ? $0.key : nil }.sorted()
        guard rows != shown else { return nil }
        shown = rows
        return rows
    }
}

/// Puts a preview's scroll view back where it was left as it comes up, and
/// reports where it is as it scrolls, for a preview that is shown again when
/// its pane is selected again.
struct PreviewScrollPlace: ViewModifier {
    let onScroll: ((CGPoint) -> Void)?
    @State private var position: ScrollPosition

    init(restoring offset: CGPoint?, onScroll: ((CGPoint) -> Void)?) {
        self.onScroll = onScroll
        _position = State(initialValue: offset.map { ScrollPosition(point: $0) } ?? ScrollPosition())
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, offset in
                onScroll?(offset)
            }
    }
}
