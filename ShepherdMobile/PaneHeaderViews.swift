import SwiftUI

// Retain UIKit's ordinary inline navigation title: it truncates into the
// space left after the intrinsic-sized bar items, without replacing back
// navigation, title accessibility, or the native title's compression policy.

/// Reserve the widest localized state label at the current text size. A
/// state update cannot shrink the badge or move the surrounding buttons, and
/// UIKit receives a non-compressible intrinsic width instead of ellipsizing it.
struct PaneStatusBadge: View {
    let title: LocalizedStringResource
    let reservedTitles: [LocalizedStringResource]
    let color: Color

    var body: some View {
        ZStack {
            ForEach(reservedTitles.indices, id: \.self) { index in
                Text(reservedTitles[index]).hidden().accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("pane-status-badge")
    }
}

/// Native toolbar buttons keep their standard hit targets. The label remains
/// icon-only and intrinsic-sized on both iPhone and iPad; its title remains
/// available to VoiceOver rather than competing with the pane title for width.
struct MobileToolbarIcon: View {
    let title: LocalizedStringKey
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(1)
    }
}
