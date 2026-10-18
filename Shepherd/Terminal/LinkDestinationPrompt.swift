#if os(macOS)
import SwiftUI

/// Asks where a clicked link is to open, the first time one is clicked
/// while Settings says to ask (see `LinkDestinationPolicy`): in the pane's
/// Shepherd Browser or in the Mac's default browser, and whether that is to
/// be the answer from now on. Return takes the first; Escape, or a click
/// outside, opens nothing.
struct LinkDestinationPrompt: View {
    let url: String
    /// The browser chosen, and whether to keep it as the setting.
    let onChoose: (_ destination: LinkDestinationPolicy.Preference, _ remember: Bool) -> Void

    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: url)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Open in hrdrhrdrhrdr Browser") { onChoose(.shepherd, remember) }
                    .keyboardShortcut(.defaultAction)
                Button("Open in Default Browser") { onChoose(.system, remember) }
            }
            Toggle("Don't ask again", isOn: $remember)
                .toggleStyle(.checkbox)
            Text("⌘-click opens a link in the other browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 360, alignment: .leading)
        .accessibilityIdentifier("terminal.link-destination-prompt")
    }
}

/// Along the bottom of the terminal column: that a link went to the default
/// browser because Shepherd Browser couldn't show it. Goes away by itself.
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
