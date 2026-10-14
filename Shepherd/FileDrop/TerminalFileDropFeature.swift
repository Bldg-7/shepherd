import Foundation

/// The opt-in for dropping files on a terminal (Settings › Experimental
/// Features). Off unless turned on. Turning it either way needs nothing
/// done: a terminal takes drops while it is on, and an upload already under
/// way when it is turned off finishes.
nonisolated enum TerminalFileDropFeature {
    static let preferenceKey = "experimentalTerminalFileDropEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }
}
