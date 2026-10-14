import SwiftUI

/// Along the bottom of a pane: an upload's progress, with a way to stop it,
/// or what the last drop couldn't do. Nothing otherwise. The terminal above
/// it stays usable throughout.
struct TerminalDropBanner: View {
    let controller: TerminalDropController

    var body: some View {
        switch controller.activity {
        case .idle:
            EmptyView()
        case .uploading(let current, let total, let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(width: 80)
                Text("Uploading \(current) of \(total)…")
                    .font(.callout)
                    .monospacedDigit()
                Button("Cancel") { controller.cancel() }
                    .controlSize(.small)
            }
            .modifier(BannerBackground())
        case .finished(let lines):
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Button { controller.dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .modifier(BannerBackground())
            // A note is no reason to keep part of the terminal covered.
            .task(id: lines) {
                do {
                    try await Task.sleep(for: .seconds(12))
                    controller.dismiss()
                } catch {}
            }
        }
    }
}

private struct BannerBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
    }
}
