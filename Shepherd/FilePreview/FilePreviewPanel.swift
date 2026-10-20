import SwiftUI
import ImageIO

struct FilePreviewPanel: View {
    let request: FilePreviewRequest
    /// The preview's read and how it is being looked at, which outlive this
    /// view: they are kept with the pane the preview is for (see
    /// `FilePreviewPaneStates`), and this view is made anew for each preview.
    let model: FilePreviewModel
    let machineStore: MachineStore
    var onClose: () -> Void
    var onFileLink: (FilePreviewRequest) -> Void
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil
    @State private var reload = 0
    /// What is shown of the text read, worked out once for each read.
    @State private var shownText = PreviewTextCache()
    /// Which blocks of the Markdown rendering its scroll view shows.
    @State private var shownBlocks = PreviewVisibleRows()
    #if os(macOS)
    @FocusState private var panelFocused: Bool
    #endif
    // Both raw text and Markdown have a bounded render budget independent
    // of the transport limit. The source file is never modified.
    private let renderCharacters = 120_000

    #if os(macOS)
    func previewExpansion(isExpanded: Bool, onToggle: @escaping () -> Void) -> Self {
        var panel = self
        panel.isExpanded = isExpanded
        panel.onToggleExpanded = onToggle
        return panel
    }
    #endif

    private var title: String {
        ((model.link?.path ?? request.rawLink) as NSString).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                Text(verbatim: title).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                if case .loaded(let document) = model.state, case .text(let text, let markdown) = document.content, markdown {
                    // The other view of the file starts at its top, as it
                    // always did, not at the place the one left was at.
                    Toggle("Source", isOn: Binding(get: { model.showsSource }, set: { shows in
                        model.scrollOffset = nil
                        model.visibleBlocks = []; model.visibleLines = []
                        model.showsSource = shows
                    })).toggleStyle(.button)
                    let headings = shownText.shown(text, markdown: true, limit: renderCharacters).markdown?.headings ?? []
                    outlineToggle(hasHeadings: !headings.isEmpty)
                }
                #if os(macOS)
                if let onToggleExpanded {
                    Button(action: onToggleExpanded) {
                        Label(isExpanded ? "Restore Preview Size" : "Expand Preview", systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Restore Preview Size" : "Expand Preview")
                    .accessibilityIdentifier("preview.expand")
                }
                #endif
                Button(action: onClose) {
                    Label("Close Preview", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }.padding(10)
            if let link = model.link {
                HStack {
                    Text(verbatim: request.machine.displayName + " · " + link.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if let line = link.line { Text("Line \(line)").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            switch model.state {
            case .loading:
                ProgressView("Reading File…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Cannot Preview File", systemImage: "doc.badge.ellipsis")
                } description: { Text(verbatim: message) } actions: {
                    Button("Retry") { reload += 1 }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let document):
                content(document)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .navigationTitle(title)
        #if os(macOS)
        .focusable(isExpanded)
        .focusEffectDisabled()
        .focused($panelFocused)
        .onChange(of: isExpanded, initial: true) { _, expanded in panelFocused = expanded }
        .onExitCommand {
            if isExpanded { onToggleExpanded?() } else { onClose() }
        }
        #endif
        // A preview shown again with its pane has been read already; only
        // Retry, or a read that was cancelled when its pane was left, reads.
        .task(id: "\(request.id)-\(reload)") {
            if reload > 0 {
                await model.load(request, store: machineStore)
            } else {
                await model.loadIfNeeded(request, store: machineStore)
            }
        }
        // All links in native Markdown are explicitly routed. External URLs,
        // scripts and images never cause automatic network or app launching.
        .environment(\.openURL, OpenURLAction { url in
            let raw = url.scheme == nil ? (url.relativeString.removingPercentEncoding ?? url.relativeString) : url.absoluteString
            guard !raw.hasPrefix("#"), url.scheme == nil || url.scheme?.lowercased() == "file",
                  let current = model.link else { return .handled }
            let directory = (current.path as NSString).deletingLastPathComponent
            onFileLink(request.following(raw, directory: directory))
            return .handled
        })
    }

    @ViewBuilder private func content(_ document: FilePreviewDocument) -> some View {
        switch document.content {
        case .text(let text, let markdown):
            let shown = shownText.shown(text, markdown: markdown, limit: renderCharacters)
            VStack(spacing: 0) {
                if shown.truncated {
                    Text("Preview truncated to 120,000 characters.").font(.caption).foregroundStyle(.secondary).padding(8)
                }
                ScrollViewReader { proxy in
                    Group {
                        if let markdown = shown.markdown, !model.showsSource {
                            ScrollView {
                                MarkdownPreview(document: markdown) { block, frame in
                                    keepVisibleBlocks(shownBlocks.place(block, at: frame))
                                }
                            }
                            .modifier(PreviewScrollPlace(restoring: model.scrollOffset, onScroll: keepScrollOffset))
                            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, visible in
                                keepVisibleBlocks(shownBlocks.show(visible))
                            }
                        } else {
                            SourceFilePreview(text: shown.text, selectedLine: model.link?.line,
                                              language: .filename(model.link?.path),
                                              restoredOffset: model.scrollOffset, onScroll: keepScrollOffset,
                                              onVisibleLines: { model.visibleLines = $0 })
                        }
                    }
                    .onChange(of: model.scrollRequest) { _, request in
                        scroll(proxy, to: request, inSource: shown.markdown == nil || model.showsSource)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let markdown = shown.markdown, model.showsOutline, !markdown.headings.isEmpty {
                        PreviewOutlineOverlay(model: model, headings: markdown.headings)
                    }
                }
            }
        case .image(let data):
            if let image = thumbnail(data) {
                let scale = min(1.0, 1600.0 / Double(max(image.width, image.height)))
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: Double(image.width) * scale, height: Double(image.height) * scale).padding()
                }
                .modifier(PreviewScrollPlace(restoring: model.scrollOffset, onScroll: keepScrollOffset))
            } else {
                ContentUnavailableView("Cannot Preview File", systemImage: "photo", description: Text("This file type or text encoding cannot be previewed."))
            }
        }
    }

    private func keepScrollOffset(_ offset: CGPoint) {
        model.scrollOffset = offset
    }

    private func keepVisibleBlocks(_ blocks: [Int]?) {
        if let blocks { model.visibleBlocks = blocks }
    }

    /// Brings what `request` asks for to the top, when it is in the view
    /// shown: a block of the rendering, or a line of the source.
    private func scroll(_ proxy: ScrollViewProxy, to request: PreviewScrollRequest?, inSource: Bool) {
        switch request?.target {
        case .block(let id)? where !inSource: proxy.scrollTo(PreviewBlockAnchor(block: id), anchor: .top)
        case .line(let line)? where inSource: proxy.scrollTo(line, anchor: .top)
        default: break
        }
    }

    /// Shows or hides the table of contents of this preview. With no
    /// headings to list, it is off and can't be turned on.
    private func outlineToggle(hasHeadings: Bool) -> some View {
        Toggle(isOn: Binding(get: { hasHeadings && model.showsOutline }, set: { model.showsOutline = $0 })) {
            Label("Table of Contents", systemImage: "list.bullet.indent")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .disabled(!hasHeadings)
        .help(!hasHeadings ? "No Headings" : model.showsOutline ? "Hide Table of Contents" : "Show Table of Contents")
        .accessibilityIdentifier("preview.outline.toggle")
    }

    private func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 16_000, height.doubleValue <= 16_000,
              width.doubleValue * height.doubleValue <= 16_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

/// The table of contents over the top right of a Markdown preview, at most
/// as tall as the preview less 24 points. It marks the heading at the top of
/// what the preview shows, and a heading chosen in it is brought to the top.
/// It, not the panel, follows what is shown, so scrolling redraws only it.
private struct PreviewOutlineOverlay: View {
    let model: FilePreviewModel
    let headings: [PreviewMarkdownHeading]

    var body: some View {
        let inSource = model.showsSource
        let current = PreviewOutline.current(in: headings, firstVisible: (inSource ? model.visibleLines : model.visibleBlocks).first,
                                             inSource: inSource)
        GeometryReader { geometry in
            PreviewOutlinePanel(headings: headings, current: current, maxHeight: max(0, geometry.size.height - 24)) { heading in
                model.reveal(inSource ? .line(heading.line) : .block(heading.id))
            }
            .frame(width: PreviewOutline.width(for: geometry.size.width))
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

/// What the panel shows of a text file, worked out once for each file read
/// rather than each time the panel is drawn: the part rendered, whether that
/// is all of it, and for Markdown, its blocks, headings and inline renders.
final class PreviewTextCache {
    struct Shown {
        /// The text up to the render limit.
        let text: String
        /// Whether the file goes on past the limit.
        let truncated: Bool
        /// The rendered text as Markdown, for a Markdown file.
        let markdown: PreviewMarkdownDocument?
    }
    private var source: String?
    private var cached: Shown?

    func shown(_ text: String, markdown: Bool, limit: Int) -> Shown {
        // The same read is the same string: this compares no characters.
        if let cached, source == text, (cached.markdown != nil) == markdown { return cached }
        let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        let shown = String(text[..<end])
        let result = Shown(text: shown, truncated: end < text.endIndex, markdown: markdown ? PreviewMarkdownDocument(shown) : nil)
        source = text; cached = result
        return result
    }
}
