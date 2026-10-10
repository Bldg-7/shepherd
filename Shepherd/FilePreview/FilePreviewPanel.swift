import SwiftUI
import ImageIO

struct FilePreviewPanel: View {
    let request: FilePreviewRequest
    let machineStore: MachineStore
    var onClose: () -> Void
    var onFileLink: (FilePreviewRequest) -> Void
    @State private var model = FilePreviewModel()
    @State private var reload = 0
    @State private var showsSource = false
    // Both raw text and Markdown have a bounded render budget independent
    // of the transport limit. The source file is never modified.
    private let renderCharacters = 120_000

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
                    Toggle("Source", isOn: $showsSource).toggleStyle(.button)
                }
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
        .task(id: "\(request.id)-\(reload)") {
            showsSource = false
            await model.load(request, store: machineStore)
            if model.link?.line != nil { showsSource = true }
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
            let rendered = String(text.prefix(renderCharacters))
            VStack(spacing: 0) {
                if text.count > renderCharacters {
                    Text("Preview truncated to 120,000 characters.").font(.caption).foregroundStyle(.secondary).padding(8)
                }
                if markdown && !showsSource {
                    ScrollView { MarkdownPreview(text: rendered) }
                } else {
                    SourceFilePreview(text: rendered, selectedLine: model.link?.line,
                                      language: .filename(model.link?.path))
                }
            }
        case .image(let data):
            if let image = thumbnail(data) {
                let scale = min(1.0, 1600.0 / Double(max(image.width, image.height)))
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: Double(image.width) * scale, height: Double(image.height) * scale).padding()
                }
            } else {
                ContentUnavailableView("Cannot Preview File", systemImage: "photo", description: Text("This file type or text encoding cannot be previewed."))
            }
        }
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
