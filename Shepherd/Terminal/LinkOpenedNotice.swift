#if os(macOS)
import SwiftUI

/// Along the bottom of the terminal column: that a link went to the default
/// browser because In-app Browser couldn't show it. Goes away by itself.
struct LinkOpenedNotice: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            .accessibilityIdentifier("terminal.link-opened-notice")
    }
}
#endif
