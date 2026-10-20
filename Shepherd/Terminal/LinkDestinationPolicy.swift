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
/// An HTML file on this Mac, clicked in a pane of this Mac's own herdr,
/// goes where a web link would (`TerminalPageLink`), except that a click
/// opens it in the default browser too while an agent is connected to the
/// pane's In-app Browser — which an agent could otherwise read the file in,
/// and the other files of this Mac it shows — and says so in a notice. An
/// agent connecting to a browser that shows such a file empties its tab
/// (`PaneBrowser.emptyLocalFileTabs`).
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

    /// What a link points to.
    enum Target: Equatable, Sendable {
        /// A web page: an `http` or `https` link.
        case web
        /// An HTML file on this Mac (`TerminalPageLink`).
        case localFile
    }

    /// Where a click goes. `browserEnabled` is whether In-app Browser is on
    /// in Settings, `engineAvailable` whether its engine can run on this Mac,
    /// `agentConnected` whether an agent is connected to the In-app Browser
    /// of the clicked pane, which only matters for a file.
    static func destination(_ target: Target = .web, commandHeld: Bool, browserEnabled: Bool, engineAvailable: Bool,
                            agentConnected: Bool = false) -> Destination {
        guard !commandHeld, browserEnabled, engineAvailable else { return .system }
        return target == .localFile && agentConnected ? .system : .shepherd
    }

    /// Whether a link that goes to the default browser only does so because
    /// In-app Browser, though on, can't run on this Mac — worth a word, so
    /// that the person knows why the click didn't open it there. Not with
    /// In-app Browser off: then the default browser is where links go.
    static func saysBrowserUnavailable(commandHeld: Bool, browserEnabled: Bool, engineAvailable: Bool) -> Bool {
        !commandHeld && browserEnabled && !engineAvailable
    }

    /// Whether a file goes to the default browser only because an agent is
    /// connected to the clicked pane's In-app Browser — said in a notice, as
    /// the click would have opened it there otherwise.
    static func saysAgentUsesBrowser(_ target: Target, commandHeld: Bool, browserEnabled: Bool, engineAvailable: Bool,
                                     agentConnected: Bool) -> Bool {
        target == .localFile && agentConnected && !commandHeld && browserEnabled && engineAvailable
    }
}
