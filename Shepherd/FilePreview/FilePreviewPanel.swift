import SwiftUI
#if canImport(ShepherdKit)
import ShepherdKit
#endif
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
    /// How many times the file has been asked to be read again, with the
    /// header's Reload button, ⌘R or Retry: each starts a read.
    @State private var reloads = 0
    /// What is shown of the text read, worked out once for each read.
    @State private var shownText = PreviewTextCache()
    /// Which blocks of the Markdown rendering its scroll view shows.
    @State private var shownBlocks = PreviewVisibleRows()
    /// The find bar's matches in what is shown.
    @State private var finder = PreviewFindCache()
    #if os(macOS)
    @State private var keyboard = PreviewKeyboard()
    @FocusState private var panelFocused: Bool
    /// Kept in this view rather than the pane model: a table-of-contents
    /// reveal must not reappear after a pane or document changes.
    @FocusState private var outlineFocused: Bool
    @State private var outlineExplicitlyRevealed = false
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
                if case .loaded(let document) = model.state, case .text(_, let markdown) = document.content, markdown {
                    // The other view of the file starts at its top, as it
                    // always did, not at the place the one left was at.
                    Toggle("Source", isOn: Binding(get: { model.showsSource }, set: { shows in
                        model.scrollOffset = nil; model.scrollAnchor = nil
                        model.visibleBlocks = []; model.visibleLines = []
                        model.showsSource = shows
                        // What is looked for is kept; the other view has
                        // matches of its own, and the bar is at none yet.
                        model.find.current = nil
                    }))
                    .toggleStyle(.button)
                    .accessibilityIdentifier("preview.source")
                }
                reloadButton
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
                    Button("Retry", action: reloadFile)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let document):
                content(document)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .navigationTitle(title)
        #if os(macOS)
        // ⌘F and the find bar's keys, and ⌘R, while the preview has the
        // keyboard, which a click in it gives it.
        .background {
            PreviewKeyCatcher(keyboard: keyboard, perform: perform, onTakeKeyboard: { panelFocused = true })
        }
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onChange(of: isExpanded, initial: true) { _, expanded in
            panelFocused = expanded
            // Restored to its size, the keyboard goes back to the terminal
            // it came from, as it always did.
            if !expanded { keyboard.giveBack() }
        }
        .onExitCommand {
            if outlineFocused || outlineExplicitlyRevealed {
                outlineFocused = false
                outlineExplicitlyRevealed = false
                keyboard.focusPreview()
            } else if model.find.isShown {
                closeFind()
            } else if isExpanded {
                onToggleExpanded?()
            } else {
                onClose()
            }
        }
        #endif
        #if os(macOS)
        .onChange(of: request.id) { _, _ in
            // A different request can have identical text, but it is still a
            // new document/pane identity and cannot retain an accessible reveal.
            outlineFocused = false
            outlineExplicitlyRevealed = false
        }
        #endif
        // A preview shown again with its pane has been read already; only
        // Reload, ⌘R and Retry, or a read that was cancelled when its pane
        // was left, read.
        .task(id: "\(request.id)-\(reloads)") {
            if reloads > 0 {
                await model.reload(request, store: machineStore)
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
            let inSource = shown.markdown == nil || model.showsSource
            // The find bar's matches are marked while it is shown.
            let matches = model.find.isShown
                ? finder.matches(of: model.find.query, in: shown.text, rendering: inSource ? nil : shown.markdown) : []
            let current = PreviewFind.current(model.find.current, count: matches.count)
            let marks = model.find.isShown ? finder.marks(current: current) : .none
            VStack(spacing: 0) {
                #if os(macOS)
                if model.find.isShown {
                    PreviewFindBar(query: model.find.query, current: current, count: matches.count, keyboard: keyboard,
                                   onQuery: findQueryChanged, onStep: findStep, onClose: closeFind)
                }
                #endif
                if shown.truncated {
                    Text("Preview truncated to 120,000 characters.").font(.caption).foregroundStyle(.secondary).padding(8)
                }
                ScrollViewReader { proxy in
                    Group {
                        if let markdown = shown.markdown, !model.showsSource {
                            ScrollView {
                                MarkdownPreview(document: markdown, marks: marks, onBlockFrame: { block, frame in
                                    keepVisibleBlocks(shownBlocks.place(block, at: frame))
                                }, onBlockAppear: { block, appeared in
                                    keepVisibleBlocks(shownBlocks.appear(block, appeared))
                                })
                            }
                            .modifier(PreviewScrollPlace(restoring: model.scrollOffset, anchor: model.scrollAnchor,
                                                         inSource: false, rowRange: 0..<markdown.blocks.count,
                                                         id: { PreviewBlockAnchor(block: $0) }, rows: shownBlocks,
                                                         navigationID: model.scrollRequest?.id,
                                                         onScroll: keepScrollOffset, onAnchor: { model.scrollAnchor = $0 }))
                            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, visible in
                                keepVisibleBlocks(shownBlocks.show(visible))
                            }
                        } else {
                            SourceFilePreview(text: shown.text, selectedLine: model.link?.line,
                                              language: .filename(model.link?.path),
                                              restoredOffset: model.scrollOffset, restoredAnchor: model.scrollAnchor,
                                              onAnchor: { model.scrollAnchor = $0 }, navigationID: model.scrollRequest?.id,
                                              onScroll: keepScrollOffset,
                                              onVisibleLines: { model.visibleLines = $0 }, marks: marks)
                        }
                    }
                    .onChange(of: model.scrollRequest) { _, request in
                        scroll(proxy, to: request, inSource: inSource)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    #if os(macOS)
                    if let markdown = shown.markdown, !markdown.headings.isEmpty {
                        PreviewOutlineOverlay(model: model, headings: markdown.headings, document: shown.text,
                                              documentID: request.id, outlineFocus: $outlineFocused,
                                              explicitReveal: $outlineExplicitlyRevealed)
                    }
                    #endif
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

    /// Brings what `request` asks for into view, when it is in the view
    /// shown: a block of the rendering, or a line of the source, to the top,
    /// or the place in it asked for at the same place in the view.
    private func scroll(_ proxy: ScrollViewProxy, to request: PreviewScrollRequest?, inSource: Bool) {
        func anchor(_ place: Double) -> UnitPoint { place > 0 ? UnitPoint(x: 0, y: min(1, place)) : .top }
        switch request?.target {
        case .block(let id, let place)? where !inSource: proxy.scrollTo(PreviewBlockAnchor(block: id), anchor: anchor(place))
        case .line(let line, let place)? where inSource: proxy.scrollTo(line, anchor: anchor(place))
        default: break
        }
    }

    /// The text shown, if it is text, and whether it is shown as the source
    /// view shows it.
    private func shownTextNow() -> (shown: PreviewTextCache.Shown, inSource: Bool)? {
        guard case .loaded(let document) = model.state, case .text(let text, let markdown) = document.content else { return nil }
        let shown = shownText.shown(text, markdown: markdown, limit: renderCharacters)
        return (shown, shown.markdown == nil || model.showsSource)
    }

    /// The find bar's matches in the view shown, and whether it is the
    /// source. Nil when no text is shown.
    private func findMatches() -> (matches: [PreviewFindMatch], inSource: Bool)? {
        guard let (shown, inSource) = shownTextNow() else { return nil }
        return (finder.matches(of: model.find.query, in: shown.text, rendering: inSource ? nil : shown.markdown), inSource)
    }

    /// The first row the view shown shows: a line of the source, or a block
    /// of the rendering.
    private func firstShownRow(inSource: Bool) -> Int? {
        (inSource ? model.visibleLines : model.visibleBlocks).first
    }

    /// What is typed into the find bar is looked for as it is typed: the
    /// bar goes to the first match from where the view is.
    private func findQueryChanged(_ query: String) {
        model.find.query = query
        guard let (matches, inSource) = findMatches() else { return }
        goToMatch(PreviewFind.first(matches, atOrAfter: firstShownRow(inSource: inSource)), in: matches, inSource: inSource)
    }

    /// The next match, `by` 1, or the previous, -1, going round at either
    /// end. With the bar at none yet: the first from where the view is, or
    /// the last before it. Shows the bar if it was closed.
    private func findStep(_ by: Int) {
        if !model.find.isShown { model.find.isShown = true }
        guard let (matches, inSource) = findMatches(), !matches.isEmpty else { return }
        let next: Int?
        if let current = PreviewFind.current(model.find.current, count: matches.count) {
            next = PreviewFind.step(from: current, by: by, count: matches.count)
        } else {
            let row = firstShownRow(inSource: inSource)
            next = by > 0 ? PreviewFind.first(matches, atOrAfter: row) : PreviewFind.last(matches, before: row)
        }
        goToMatch(next, in: matches, inSource: inSource)
    }

    /// Makes `index` the match the bar is at, and brings it into view
    /// unless its row is shown whole already: neither the first nor the
    /// last row shown, either of which may be cut off. Rows shown are one
    /// run of rows; when they are not, what was reported is not trusted.
    private func goToMatch(_ index: Int?, in matches: [PreviewFindMatch], inSource: Bool) {
        model.find.current = index
        guard let index else { return }
        let match = matches[index]
        let shownRows = inSource ? model.visibleLines : model.visibleBlocks
        if let first = shownRows.first, let last = shownRows.last, last - first == shownRows.count - 1,
           first < match.row, match.row < last { return }
        model.reveal(inSource ? .line(match.row, at: match.place) : .block(match.row, at: match.place))
    }

    /// Closes the find bar, its matches no longer marked, and gives the
    /// keyboard to the preview. What it looked for is kept for the next ⌘F.
    private func closeFind() {
        model.find.isShown = false
        #if os(macOS)
        keyboard.focusPreview()
        #endif
    }

    /// Reads the file again, keeping how it is looked at (see
    /// `FilePreviewModel.reload`): one read at a time.
    private func reloadFile() {
        guard !model.isReading else { return }
        reloads += 1
    }

    /// The header's Reload button, as In-app Browser's: disabled while the
    /// file is read, and a small spinner in its place while it is read again
    /// over what was read.
    private var reloadButton: some View {
        Button(action: reloadFile) {
            Label {
                Text("Reload")
            } icon: {
                Image(systemName: "arrow.clockwise").opacity(model.isReloading ? 0 : 1)
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(model.isReading)
        .overlay {
            if model.isReloading {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
        }
        .help("Reload (⌘R)")
        .accessibilityIdentifier("preview.reload")
    }

    #if os(macOS)
    /// Does what a key the preview takes asks for (see `PreviewKeyCatcher`):
    /// ⌘R whatever is shown, and find's keys while text is. Whether it did.
    private func perform(_ command: PreviewKeyCommand) -> Bool {
        switch command {
        case .reload:
            // Taken while the file is read, too: one read at a time.
            reloadFile()
        case .find:
            guard let (_, inSource) = shownTextNow() else { return false }
            // The bar shows with the keyboard in it, what it looks for
            // selected; opened anew, it goes to the first match from where
            // the view is.
            let opening = !model.find.isShown
            model.find.isShown = true
            keyboard.focusFindField()
            if opening, let (matches, _) = findMatches() {
                goToMatch(PreviewFind.first(matches, atOrAfter: firstShownRow(inSource: inSource)), in: matches, inSource: inSource)
            }
        case .findNext, .findPrevious:
            guard shownTextNow() != nil else { return false }
            // With nothing to look for yet, as ⌘F.
            if model.find.query.isEmpty { return perform(.find) }
            findStep(command == .findNext ? 1 : -1)
        }
        return true
    }
    #endif

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

/// The table of contents lives in the preview viewport rather than the
/// header. Its hover region contains only the visible trigger, panel, and
/// their small bridge gap, so it does not cover the preview body.
#if os(macOS)
private struct PreviewOutlineOverlay: View {
    let model: FilePreviewModel
    let headings: [PreviewMarkdownHeading]
    /// A changed read must not retain a previous document's hover/focus state.
    let document: String
    /// Request identity also changes for a pane/document replacement whose
    /// visible text happens to be the same.
    let documentID: UUID
    let outlineFocus: FocusState<Bool>.Binding
    let explicitReveal: Binding<Bool>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointerInside = false

    private var isPresented: Bool {
        PreviewOutlineHover.isPresented(pointerInside: pointerInside, hasKeyboardFocus: outlineFocus.wrappedValue,
                                        hasExplicitReveal: explicitReveal.wrappedValue)
    }

    private func dismissExplicitReveal() {
        explicitReveal.wrappedValue = false
        outlineFocus.wrappedValue = false
    }

    var body: some View {
        let inSource = model.showsSource
        let current = PreviewOutline.current(in: headings, firstVisible: (inSource ? model.visibleLines : model.visibleBlocks).first,
                                             inSource: inSource)
        GeometryReader { geometry in
            let triggerSize: CGFloat = 32
            let panelWidth = PreviewOutline.width(for: geometry.size.width)
            let panelHeight = max(0, geometry.size.height - triggerSize - 16)
            ZStack(alignment: .topTrailing) {
                if isPresented {
                    PreviewOutlinePanel(headings: headings, current: current, maxHeight: panelHeight) { heading in
                        model.reveal(inSource ? .line(heading.line) : .block(heading.id))
                        // Selecting a heading dismisses an explicit accessible
                        // reveal; pointer hover can still keep it visible.
                        dismissExplicitReveal()
                    }
                    .frame(width: panelWidth)
                    .padding(.top, triggerSize + 4)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
                Button(action: {}) {
                    Label("Table of Contents", systemImage: "list.bullet.indent")
                        .labelStyle(.iconOnly)
                        .frame(width: triggerSize, height: triggerSize)
                }
                .buttonStyle(.borderless)
                // The control itself, not just its icon label, is the
                // 32-point trigger. The surrounding ZStack remains the
                // separate trigger/panel hover region.
                .frame(width: triggerSize, height: triggerSize)
                .contentShape(Rectangle())
                .help("Show Table of Contents")
                .accessibilityIdentifier("preview.outline.trigger")
                .accessibilityAction {
                    // Accessibility activation has an explicit, view-local
                    // reveal intent. Focus is requested too for keyboard use,
                    // but AppKit can decline that request for an AX action.
                    explicitReveal.wrappedValue = true
                    outlineFocus.wrappedValue = true
                }
                .focused(outlineFocus)
                .onChange(of: outlineFocus.wrappedValue) { wasFocused, isFocused in
                    // A real keyboard-focus transfer dismisses the explicit
                    // reveal. Do not clear it merely because AX declined the
                    // best-effort focus request while it was already false.
                    if wasFocused && !isFocused { explicitReveal.wrappedValue = false }
                }
            }
            // This is deliberately intrinsically tall: a short panel must
            // not turn the hover region into a full-height transparent strip.
            .frame(width: isPresented ? panelWidth : triggerSize, alignment: .topTrailing)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("preview.outline.region")
            .onHover { pointerInside = $0 }
            .onChange(of: document) { _, _ in
                pointerInside = false
                dismissExplicitReveal()
            }
            .onChange(of: documentID) { _, _ in
                pointerInside = false
                dismissExplicitReveal()
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isPresented)
            // The GeometryReader itself fills the overlay proposal; this
            // wrapper, rather than its leading origin, anchors the actual
            // trigger/panel region to the viewport's trailing edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}
#endif

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
