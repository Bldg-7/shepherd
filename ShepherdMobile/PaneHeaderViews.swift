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
    /// Callers opt in only while this is a current, herdr-reported working
    /// state. The default keeps cached and ordinary status badges inert.
    var showsActivity = false
    /// An explicit caller policy can request the static ornament in addition
    /// to the system Reduce Motion setting. Production callers use the
    /// default; the hosted layout fixture uses this deterministic policy.
    var activityUsesReducedMotion = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Reserve both the widest localized label and the activity slot.
            // A working transition must not resize the toolbar item or move
            // native navigation controls beside it.
            HStack(spacing: 4) {
                Color.clear.frame(width: 12, height: 12)
                reservedLabel
            }
            .hidden()
            HStack(spacing: 4) {
                if showsActivity {
                    activity
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
                Text(title)
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .layoutPriority(1)
        // The status title is the one concise VoiceOver value. The visual
        // activity ornament is hidden from accessibility to avoid duplicate
        // announcements every time its spinner advances.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("pane-status-badge")
    }

    private var reservedLabel: some View {
        ZStack {
            ForEach(reservedTitles.indices, id: \.self) { index in
                Text(reservedTitles[index]).hidden().accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var activity: some View {
        if reduceMotion || activityUsesReducedMotion {
            Image(systemName: "circle.fill")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 12, height: 12)
        } else {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        }
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
