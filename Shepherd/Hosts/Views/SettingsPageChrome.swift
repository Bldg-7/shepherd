#if os(macOS)
import SwiftUI

/// The top of a page Settings opens from its Machines list: the way back to
/// Machines, then the page's title.
struct SettingsPageHeader: View {
    let title: LocalizedStringKey
    /// The back button's, which each page names after itself.
    let backAccessibilityIdentifier: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) { Label("Machines", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to Machines")
                .accessibilityIdentifier(backAccessibilityIdentifier)
            Divider().frame(height: 14)
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

/// The bottom of such a page: a divider, and Done, which closes Settings.
/// Two views, laid out by the page's own stack.
struct SettingsPageFooter: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Divider()
        HStack {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
#endif
