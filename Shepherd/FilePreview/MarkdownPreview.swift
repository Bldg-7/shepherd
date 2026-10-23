import SwiftUI
#if canImport(ShepherdKit)
import ShepherdKit
#endif

/// A heading as the table of contents lists it.
nonisolated struct PreviewMarkdownHeading: Identifiable, Equatable, Sendable {
    /// The `id` of the heading's block.
    let id: Int
    /// 1 to 6: 1 for `#` and a `===` underline, 2 for `##` and a `---` one.
    let level: Int
    /// What the heading shows, without its Markdown: plain text on one line.
    let title: String
    /// The 1-based line of the file it starts on, as the source view numbers it.
    let line: Int

    /// The headings among `blocks`, those inside fenced code not being
    /// blocks. One that shows nothing, such as `## [](#top)`, is left out.
    static func headings(in blocks: [PreviewMarkdownBlock]) -> [Self] {
        blocks.compactMap { block in
            guard case .heading(let level) = block.kind else { return nil }
            let title = String(PreviewMarkdownBlock.inline(block.text).characters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return title.isEmpty ? nil : Self(id: block.id, level: level, title: title, line: block.line)
        }
    }
}

/// One Markdown text as the preview shows it, worked out once for the text
/// rather than each time the preview is drawn: its blocks, with the line each
/// starts on, its headings, and the inline Markdown of its blocks and table
/// cells rendered, each text as it first comes on screen.
final class PreviewMarkdownDocument {
    let blocks: [PreviewMarkdownBlock]
    let headings: [PreviewMarkdownHeading]
    private var rendered: [String: AttributedString] = [:]

    init(_ text: String) {
        blocks = PreviewMarkdownBlock.parse(text)
        headings = PreviewMarkdownHeading.headings(in: blocks)
    }

    /// `markdown` rendered as inline Markdown, rendered once.
    func inline(_ markdown: String) -> AttributedString {
        if let done = rendered[markdown] { return done }
        let result = PreviewMarkdownBlock.inline(markdown)
        rendered[markdown] = result
        return result
    }
}

/// The rendering of a Markdown document, for a scroll view. Each block is
/// known by its `anchor`, which the scroll view can scroll to, and tells
/// `onBlockFrame` where it is laid out in the rendering and `onBlockAppear`
/// whether it is on screen, for the scroll view to work out the blocks it
/// shows (see `PreviewVisibleRows`). The find bar's matches are marked where
/// they are shown.
struct MarkdownPreview: View {
    let document: PreviewMarkdownDocument
    /// The find bar's matches, by block `id` and text of the block (see
    /// `PreviewFindText.part`).
    var marks: PreviewFindMarks = .none
    /// Told a block's frame in the rendering as the lazy stack lays it out.
    var onBlockFrame: ((Int, CGRect) -> Void)? = nil
    /// Told that a block is on screen as it appears, true, and no longer as
    /// it disappears, false. A block the stack lays out without showing it
    /// never appears.
    var onBlockAppear: ((Int, Bool) -> Void)? = nil
    nonisolated private static let space = "preview.markdown"
    /// Inline Markdown of `block` as it is shown, with the find bar's
    /// matches in it: `part` of the block's texts.
    private func inline(_ text: String, in block: PreviewMarkdownBlock, part: Int = 0) -> AttributedString {
        PreviewSyntaxRendering.marked(document.inline(text), marks(row: block.id, part: part))
    }
    /// Literal text of `block` as it is shown, with the find bar's matches.
    private func literal(_ text: String, in block: PreviewMarkdownBlock, part: Int) -> AttributedString {
        PreviewSyntaxRendering.marked(AttributedString(text), marks(row: block.id, part: part))
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(document.blocks, id: \.anchor) { block in
                blockView(block)
                    .id(block.anchor)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { onBlockFrame?(block.id, $0) }
                    .onAppear { onBlockAppear?(block.id, true) }
                    .onDisappear { onBlockAppear?(block.id, false) }
            }
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The rendering is the scroll view's content: its space is the
        // content's, in which the scroll view tells what part it shows.
        .coordinateSpace(.named(Self.space))
    }

    @ViewBuilder private func blockView(_ block: PreviewMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let depth):
            Text(inline(block.text, in: block)).font(depth == 1 ? .title : depth == 2 ? .title2 : .headline).bold()
        case .paragraph:
            Text(inline(block.text, in: block)).frame(maxWidth: .infinity, alignment: .leading)
        case .frontmatter:
            VStack(alignment: .leading, spacing: 8) {
                Text("Frontmatter").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(block.frontmatterFields) { field in
                    HStack(alignment: .top, spacing: 12) {
                        if !field.key.isEmpty { Text(literal(field.key, in: block, part: 2 * field.id)).font(.callout.weight(.semibold)).frame(width: 100, alignment: .leading) }
                        Text(literal(field.value, in: block, part: 2 * field.id + 1)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .code:
            HighlightedCode(text: block.text, language: block.language, marks: marks(row: block.id))
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .listItem(let marker, let depth, let checked):
            HStack(alignment: .top, spacing: 8) {
                if let checked { Image(systemName: checked ? "checkmark.square" : "square").accessibilityLabel(checked ? "Checked" : "Unchecked") }
                else { Text(verbatim: marker).monospacedDigit() }
                Text(inline(block.text, in: block)).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(depth) * 16)
        case .quote:
            HStack(alignment: .top) {
                Rectangle().fill(.secondary).frame(width: 3)
                Text(inline(block.text, in: block)).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(block.rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(block.rows[row].indices, id: \.self) { col in
                                Text(inline(block.rows[row][col], in: block, part: row * block.rows[row].count + col)).fontWeight(row == 0 ? .semibold : .regular)
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
