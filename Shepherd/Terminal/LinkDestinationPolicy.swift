import Foundation

/// Where an `http(s)` link clicked in a terminal opens: the clicked pane's
/// Shepherd Browser, or the Mac's default browser.
///
/// The person picks a default in Settings (`Preference`), and ⌘-click opens
/// in the other one. Until they have picked, the first click asks
/// (`Destination.ask`). With Shepherd Browser off, or unavailable on this
/// Mac, every link opens in the default browser: nothing else can show it.
///
/// ⌘ is the one modifier this can use. The xterm mouse protocol sends
/// Shift, Option and Control along with a click to the program in the pane,
/// so giving those a meaning here would take input away from it; Command
/// is not part of that protocol (see `FocusReportingTerminalView.mouseUp`).
nonisolated enum LinkDestinationPolicy {
    /// The `UserDefaults` key the preference is stored under.
    static let preferenceKey = "links.destination"

    /// What Settings offers.
    enum Preference: String, CaseIterable, Sendable {
        /// Ask at the first click, and remember the answer if told to.
        case ask
        /// The clicked pane's Shepherd Browser.
        case shepherd
        /// The Mac's default browser.
        case system
    }

    enum Destination: Equatable, Sendable {
        case shepherd
        case system
        /// Put the two to the person.
        case ask
    }

    /// Where a click goes. `browserAvailable` is whether Shepherd Browser is
    /// on and its engine can run on this Mac.
    static func destination(preference: Preference, commandHeld: Bool, browserAvailable: Bool) -> Destination {
        switch (preference, commandHeld) {
        case (.shepherd, false), (.system, true):
            return browserAvailable ? .shepherd : .system
        case (.system, false), (.shepherd, true), (.ask, true):
            return .system
        case (.ask, false):
            return browserAvailable ? .ask : .system
        }
    }

    /// Whether a link that goes to the default browser only does so because
    /// Shepherd Browser can't show it — worth a word, so that the person
    /// knows their choice wasn't ignored.
    static func fallsBackToSystem(preference: Preference, commandHeld: Bool, browserAvailable: Bool) -> Bool {
        !browserAvailable && destination(preference: preference, commandHeld: commandHeld, browserAvailable: true) == .shepherd
    }
}
