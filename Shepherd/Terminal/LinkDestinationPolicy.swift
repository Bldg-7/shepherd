import Foundation

/// Where an `http(s)` link clicked in a terminal opens: the clicked pane's
/// In-app Browser, or the Mac's default browser.
///
/// A click opens it in In-app Browser, as a click on a file link opens it
/// in the preview beside the pane; ⌘-click opens it in the default browser.
/// With In-app Browser off, or on but unable to run on this Mac, every link
/// opens in the default browser: nothing else can show it. There is nothing
/// to set: what 0.5 kept under `links.destination`, when this was a setting,
/// is no longer read, and is left where it is.
///
/// ⌘ is the one modifier this can use. The xterm mouse protocol sends
/// Shift, Option and Control along with a click to the program in the pane,
/// so giving those a meaning here would take input away from it; Command
/// is not part of that protocol (see `FocusReportingTerminalView.mouseUp`).
nonisolated enum LinkDestinationPolicy {
    enum Destination: Equatable, Sendable {
        /// The clicked pane's In-app Browser.
        case shepherd
        /// The Mac's default browser.
        case system
    }

    /// Where a click goes. `browserEnabled` is whether In-app Browser is on
    /// in Settings, `engineAvailable` whether its engine can run on this Mac.
    static func destination(commandHeld: Bool, browserEnabled: Bool, engineAvailable: Bool) -> Destination {
        !commandHeld && browserEnabled && engineAvailable ? .shepherd : .system
    }

    /// Whether a link that goes to the default browser only does so because
    /// In-app Browser, though on, can't run on this Mac — worth a word, so
    /// that the person knows why the click didn't open it there. Not with
    /// In-app Browser off: then the default browser is where links go.
    static func saysBrowserUnavailable(commandHeld: Bool, browserEnabled: Bool, engineAvailable: Bool) -> Bool {
        !commandHeld && browserEnabled && !engineAvailable
    }
}
