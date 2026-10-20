import SwiftUI

/// What the table of contents of a Markdown preview works out: the heading
/// to mark, and how wide to be.
nonisolated enum PreviewOutline {
    /// The heading the reader is at: the last one that starts at or before
    /// `firstVisible`, the first row the preview shows. A row is a block
    /// `id` in the rendering, a 1-based line in the source. None above the
    /// first heading, or before the preview has said what it shows.
    static func current(in headings: [PreviewMarkdownHeading], firstVisible: Int?, inSource: Bool) -> PreviewMarkdownHeading.ID? {
        guard let firstVisible else { return nil }
        return headings.last { (inSource ? $0.line : $0.id) <= firstVisible }?.id
    }

    /// How wide the table of contents is over a preview `width` points
    /// wide: half of it, at least 160 points and at most 260.
    static func width(for width: CGFloat) -> CGFloat {
        min(260, max(160, width * 0.5))
    }
}

/// A Markdown preview's table of contents: its headings, each indented 12
/// points a level below the document's highest, on a Liquid Glass panel
/// like the new tab launcher's. A heading is chosen with a click, and the
/// one the reader is at is marked. A long list scrolls within the panel,
/// and follows the marked heading.
struct PreviewOutlinePanel: View {
    let headings: [PreviewMarkdownHeading]
    let current: PreviewMarkdownHeading.ID?
    /// The tallest the panel may be; shorter lists make it shorter.
    let maxHeight: CGFloat
    var onSelect: (PreviewMarkdownHeading) -> Void

    var body: some View {
        let top = headings.map(\.level).min() ?? 1
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(headings) { heading in
                        row(heading, indent: CGFloat(heading.level - top) * 12)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: current, initial: true) { _, current in
                if let current { proxy.scrollTo(current) }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table of Contents")
        .accessibilityIdentifier("preview.outline")
    }

    private func row(_ heading: PreviewMarkdownHeading, indent: CGFloat) -> some View {
        let isCurrent = heading.id == current
        return Button { onSelect(heading) } label: {
            Text(verbatim: heading.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, indent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isCurrent ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.callout)
        .help(Text(verbatim: heading.title))
        .id(heading.id)
        .accessibilityIdentifier("preview.outline.\(heading.id)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
