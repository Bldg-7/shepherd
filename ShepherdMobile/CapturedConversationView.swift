import SwiftUI
import UIKit
import ShepherdKit
import AgentProxyCore

struct CapturedConversationView: View {
    @Bindable var model: CapturedConversationModel
    let blocked: Bool
    @State private var followsLatest = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.window.nextBeforeItemID != nil {
                        Button {
                            let anchor = model.window.items.first?.id
                            followsLatest = false
                            Task {
                                await model.loadOlder()
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        } label: {
                            if model.isLoadingOlder { ProgressView() } else { Text("Load older conversation") }
                        }
                        .disabled(model.isLoadingOlder)
                    }
                    if model.window.summary?.truncated == true || model.window.clientLimited {
                        Text("Older conversation is outside the memory limit.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.window.items.contains(where: { $0.origin == "reconstructed" }) {
                        Text("Earlier messages were reconstructed from model context.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.window.items, id: \.id) { item in
                        CapturedMessageView(item: item).id(item.id)
                    }
                    if blocked {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("The agent is waiting for your response.", systemImage: "hand.raised")
                            if let tool = pendingTool {
                                Text(verbatim: tool.toolName ?? "Tool").font(.headline)
                                Text(verbatim: tool.text).font(.system(.caption, design: .monospaced)).lineLimit(5)
                            }
                            Button("View screen") { model.prefersScreen = true }
                        }
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 1).id("capture-end")
                }
                .padding()
            }
            .onScrollPhaseChange { _, phase, context in
                if phase == .interacting || phase == .decelerating { followsLatest = false }
                else if phase == .idle {
                    followsLatest = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 80
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                if followsLatest { proxy.scrollTo("capture-end", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        withAnimation { proxy.scrollTo("capture-end", anchor: .bottom) }
                    } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderedProminent).clipShape(.circle).padding()
                    .accessibilityLabel("Latest message")
                }
            }
            .refreshable { model.retry() }
        }
    }
    private var pendingTool: ConversationReadAPI.Block? {
        var results = Set<String>()
        for item in model.window.items.reversed() {
            for block in item.blocks.reversed() {
                if block.kind == "toolResult", let id = block.callID { results.insert(id) }
                if block.kind == "toolCall", let id = block.callID, !results.contains(id) { return block }
            }
        }
        return nil
    }
}

private struct CapturedMessageView: View {
    let item: ConversationMessage
    var body: some View {
        if item.origin == "compaction" {
            VStack(spacing: 6) {
                Divider()
                Text("Conversation compacted").font(.caption.weight(.semibold))
                if item.compaction == "opaque" { Text("The provider did not expose the summary text.").font(.caption) }
                else if item.compaction == "incomplete" { Text("Compaction did not complete.").font(.caption) }
                else if item.compaction == "no_text" { Text("No visible summary was returned.").font(.caption) }
                Divider()
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if item.origin == "discontinuity" {
            Label("Conversation context changed", systemImage: "arrow.triangle.branch")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top) {
                if item.role == "user" { Spacer(minLength: 28) }
                VStack(alignment: .leading, spacing: 8) {
                    if item.origin == "summary" { Label("Context summary", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                        switch block.kind {
                        case "image":
                            Label("Image not captured", systemImage: "photo").foregroundStyle(.secondary)
                        case "toolCall", "toolResult":
                            DisclosureGroup {
                                ScrollView(.horizontal) {
                                    Text(verbatim: block.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            } label: {
                                Label(block.toolName ?? (block.kind == "toolResult" ? String(localized: "Tool result") : String(localized: "Tool")), systemImage: "wrench.and.screwdriver")
                                    .font(.subheadline)
                            }
                        default:
                            if item.role == "assistant" { ConversationMarkdown(text: block.text) }
                            else { Text(verbatim: block.text).textSelection(.enabled) }
                        }
                    }
                    if item.status == "incomplete" {
                        Label("Response incomplete", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    if item.truncated { Text("Content truncated at the memory limit.").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(item.role == "user" ? 12 : 0)
                .background(item.role == "user" ? Color.accentColor.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.role != "user" { Spacer(minLength: 0) }
            }
        }
    }
}

/// The same inert block parser as desktop file preview. No WebView, image
/// download, HTML or executable link scheme. Parsing is cancellable off-main.
private struct ConversationMarkdown: View {
    let text: String
    @State private var blocks: [PreviewMarkdownBlock] = []
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in render(block) }
        }
        .task(id: text) {
            let worker = Task.detached(priority: .userInitiated) { PreviewMarkdownBlock.parse(text, cancellable: true) }
            let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            blocks = parsed
        }
        .environment(\.openURL, OpenURLAction { url in
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }
    private func inline(_ text: String) -> Text { Text(PreviewMarkdownBlock.inline(text)) }
    @ViewBuilder private func render(_ block: PreviewMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            inline(block.text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline).textSelection(.enabled)
        case .paragraph:
            inline(block.text).textSelection(.enabled)
        case .code, .frontmatter:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Code").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = block.text }.font(.caption)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: block.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(10).background(.quaternary, in: .rect(cornerRadius: 10))
        case .quote:
            HStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
                inline(block.text).foregroundStyle(.secondary).textSelection(.enabled)
            }.fixedSize(horizontal: false, vertical: true)
        case .rule: Divider()
        case .listItem(let marker, let depth, let checked):
            HStack(alignment: .firstTextBaseline) {
                if let checked { Image(systemName: checked ? "checkmark.square" : "square") }
                else { Text(verbatim: marker) }
                inline(block.text).textSelection(.enabled)
            }.padding(.leading, CGFloat(depth) * 12)
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                inline(cell).fontWeight(row == 0 ? .semibold : .regular)
                                    .frame(minWidth: 80, maxWidth: 280, alignment: .leading).textSelection(.enabled)
                            }
                        }
                        if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(10)
            }.background(.quaternary, in: .rect(cornerRadius: 10))
        }
    }
}
