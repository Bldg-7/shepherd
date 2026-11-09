import SwiftUI

// Retain UIKit's ordinary inline navigation title: it truncates into the
// space left after the intrinsic-sized bar items, without replacing back
// navigation, title accessibility, or the native title's compression policy.

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
