#if os(macOS)
import SwiftUI

/// The spot in a window that a pane browser's page is shown in. The page's
/// view is AppKit's, and lives on when this goes away — `BrowserStore` puts
/// it in here while this window shows its pane, and takes it back out when
/// it no longer does.
struct BrowserRegionView: NSViewRepresentable {
    let region: BrowserRegion
    let key: BrowserKey?
    let terminalID: String?

    func makeNSView(context: Context) -> NSView {
        region.container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        BrowserStore.shared.show(key, in: region, terminalID: terminalID)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(region: region)
    }

    final class Coordinator {
        let region: BrowserRegion

        init(region: BrowserRegion) {
            self.region = region
        }

        func dismantle() {
            BrowserStore.shared.remove(region)
        }
    }
}
#endif
