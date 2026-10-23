import SwiftUI
#if canImport(ShepherdKit)
import ShepherdKit
#endif

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
    var restoredAnchor: PreviewScrollAnchor? = nil
    var onAnchor: ((PreviewScrollAnchor) -> Void)? = nil
    /// A new explicit navigation request takes precedence over restoration.
    var navigationID: UUID? = nil
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
                        .onAppear { report(shownLines.appear(line.number, true)) }
                        .onDisappear { report(shownLines.appear(line.number, false)) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .textSelection(.enabled)
                // The scroll view's content: its space is the content's, in
                // which the scroll view tells what part it shows.
                .coordinateSpace(.named(Self.space))
            }
            .modifier(PreviewScrollPlace(restoring: restoredOffset, anchor: restoredAnchor,
                                         inSource: true, rowRange: 1..<(lines.count + 1),
                                         id: { $0 }, rows: shownLines, navigationID: navigationID,
                                         onScroll: onScroll, onAnchor: onAnchor))
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, visible in
                report(shownLines.show(visible))
            }
            .onAppear { if restoredOffset == nil && restoredAnchor == nil { scrollToLine(proxy) } }
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
/// where each row on screen is laid out in the scroll view's content, and
/// the part of the content the scroll view shows. A row is shown when any
/// of it is. Rows come on screen, and go, as they come near the part shown,
/// so this looks at a few dozen rows, not a whole document.
///
/// A row is on screen from its `onAppear` to its `onDisappear`. The stack
/// also lays out rows it makes ahead, and may keep them aside, away from
/// their place, without showing them: those never appear, so where they
/// were laid out doesn't count. Where a row was laid out is kept while it is
/// off screen: one that comes back where it was isn't told its place again.
///
/// Not scroll targets (`scrollTargetLayout`), whose stack would change how a
/// place put back with `PreviewScrollPlace` comes out: lower by the stack's
/// top padding, and, after the view has been scrolled elsewhere, gone back
/// to whenever the content is laid out again.
final class PreviewVisibleRows {
    private var frames: [Int: Range<CGFloat>] = [:]
    private var onScreen: Set<Int> = []
    private var visible: Range<CGFloat>?
    private var shown: [Int] = []
    var isRestoring = false
    var inSource = false
    var gap: CGFloat = 14
    var onAnchor: ((PreviewScrollAnchor) -> Void)?

    /// Do not save a distant first visible row while lazy layout is still
    /// catching up. A small negative offset represents the inter-row gap.
    func top() -> PreviewScrollAnchor? {
        guard let visible,
              let row = onScreen.filter({ frames[$0]?.overlaps(visible) == true }).min(),
              let frame = frames[row] else { return nil }
        let offset = visible.lowerBound - frame.lowerBound
        guard offset >= -gap - 0.5 || visible.lowerBound <= 0.5 else { return nil }
        return PreviewScrollAnchor(inSource: inSource, row: row, offset: offset,
                                   height: frame.upperBound - frame.lowerBound)
    }

    func target(for anchor: PreviewScrollAnchor) -> CGFloat? {
        guard onScreen.contains(anchor.row), let frame = frames[anchor.row] else { return nil }
        let height = frame.upperBound - frame.lowerBound
        // Keep a gap in points; scale a place inside a rewrapped row.
        let offset = anchor.offset <= 0 || anchor.height <= 0 || abs(height - anchor.height) < 0.5
            ? anchor.offset : anchor.offset / anchor.height * height
        return max(0, frame.lowerBound + offset)
    }

    var viewTop: CGFloat? { visible?.lowerBound }

    func saveAnchor() {
        if !isRestoring, let anchor = top() { onAnchor?(anchor) }
    }

    /// Where `row` is laid out in the content. Returns the rows shown when
    /// that changes them.
    func place(_ row: Int, at frame: CGRect) -> [Int]? {
        frames[row] = frame.minY..<frame.maxY
        return update()
    }

    /// Whether `row` is on screen: true as it appears, false as it
    /// disappears. Returns the rows shown when that changes them.
    func appear(_ row: Int, _ appeared: Bool) -> [Int]? {
        if appeared { onScreen.insert(row) } else { onScreen.remove(row) }
        return update()
    }

    /// The part of the content the scroll view shows. Returns the rows shown
    /// when that changes them.
    func show(_ rect: CGRect) -> [Int]? {
        visible = rect.minY..<rect.maxY
        return update()
    }

    private func update() -> [Int]? {
        defer { saveAnchor() }
        guard let visible else { return nil }
        let rows = onScreen.filter { frames[$0]?.overlaps(visible) == true }.sorted()
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
    private var rows: PreviewVisibleRows?
    private var onAnchor: ((PreviewScrollAnchor) -> Void)?
    private var jump: ((ScrollViewProxy, Int) -> Void)?
    private var navigationID: UUID?
    @State private var position: ScrollPosition
    @State private var keptAnchor: PreviewScrollAnchor?
    @State private var restoring: Bool

    /// Images retain their horizontal and vertical point-based position.
    init(restoring offset: CGPoint?, onScroll: ((CGPoint) -> Void)?) {
        self.onScroll = onScroll
        _position = State(initialValue: offset.map { ScrollPosition(point: $0) } ?? ScrollPosition())
        _keptAnchor = State(initialValue: nil)
        _restoring = State(initialValue: false)
    }

    init<ID: Hashable>(restoring offset: CGPoint?, anchor: PreviewScrollAnchor?,
                       inSource: Bool, rowRange: Range<Int>, id: @escaping (Int) -> ID,
                       rows: PreviewVisibleRows, navigationID: UUID?,
                       onScroll: ((CGPoint) -> Void)?, onAnchor: ((PreviewScrollAnchor) -> Void)?) {
        let kept = anchor.flatMap { $0.inSource == inSource && rowRange.contains($0.row) ? $0 : nil }
        self.onScroll = onScroll
        self.rows = rows
        self.onAnchor = onAnchor
        self.navigationID = navigationID
        jump = { proxy, row in proxy.scrollTo(id(row), anchor: .top) }
        rows.inSource = inSource
        rows.gap = inSource ? 2 : 14
        _position = State(initialValue: offset.map { ScrollPosition(point: $0) } ?? ScrollPosition())
        _keptAnchor = State(initialValue: kept)
        _restoring = State(initialValue: kept != nil)
    }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .scrollPosition($position)
                .opacity(restoring ? 0 : 1)
                .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, offset in
                    if !restoring { onScroll?(offset) }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { finishRestoring() }
                }
                .onChange(of: navigationID) { _, _ in finishRestoring() }
                .task {
                    guard let rows else { return }
                    rows.onAnchor = onAnchor
                    rows.isRestoring = restoring
                    guard let anchor = keptAnchor, restoring else {
                        rows.saveAnchor()
                        return
                    }
                    // A removed/replaced view must not publish its old
                    // geometry after the next view has begun scrolling.
                    defer { if !Task.isCancelled { finishRestoring() } }
                    var stable = 0
                    // Lazy row estimates settle over several layouts. Hide
                    // only this initial correction; never fight user input.
                    for _ in 0..<40 {
                        do { try await Task.sleep(for: .milliseconds(16)) }
                        catch { return }
                        guard restoring else { return }
                        if let target = rows.target(for: anchor), let top = rows.viewTop {
                            if abs(top - target) <= 0.5 {
                                stable += 1
                                if stable >= 3 { return }
                            } else {
                                stable = 0
                                position.scrollTo(y: target)
                            }
                        } else {
                            stable = 0
                            jump?(proxy, anchor.row)
                        }
                    }
                }
                .onDisappear {
                    // Geometry callbacks from a departing lazy stack must
                    // not overwrite the last place the user actually saw.
                    rows?.onAnchor = nil
                    rows?.isRestoring = false
                }
        }
    }

    private func finishRestoring() {
        let wasRestoring = restoring
        restoring = false
        rows?.isRestoring = false
        rows?.saveAnchor()
        if wasRestoring, let top = rows?.viewTop {
            onScroll?(CGPoint(x: 0, y: top))
        }
    }
}
