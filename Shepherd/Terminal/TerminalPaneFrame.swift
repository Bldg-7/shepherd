import SwiftUI

nonisolated enum TerminalPaneFrameMetrics {
    static let inset: CGFloat = 3
    static let borderWidth: CGFloat = 2
}

/// Reserve the same gutter for focused and unfocused panes. The inner native
/// terminal receives the reduced bounds and reports that grid to its PTY; the
/// focus stroke stays outside those bounds, including its antialiased edge.
struct TerminalPaneFrame<Content: View>: View {
    let isFocused: Bool
    private let content: Content

    init(isFocused: Bool, @ViewBuilder content: () -> Content) {
        self.isFocused = isFocused
        self.content = content()
    }

    var body: some View {
        content
            .padding(TerminalPaneFrameMetrics.inset)
            .background(Color.black)
            .overlay {
                Rectangle()
                    .strokeBorder(isFocused ? Color.accentColor : .clear,
                                  lineWidth: TerminalPaneFrameMetrics.borderWidth)
                    .allowsHitTesting(false)
            }
    }
}
