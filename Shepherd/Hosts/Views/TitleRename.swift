import Foundation

/// One name being typed into the window's title, from a row's Rename item —
/// or a double-click on the title — until the field is done with it.
///
/// A reference, and nothing on screen follows it: the field writes what is
/// typed into `text` as it goes, and nothing about that may change SwiftUI's
/// state — AppKit reports some of it in the middle of SwiftUI's updates (a
/// composition committed as the field goes away), where a change of state
/// isn't allowed. What is typed only matters when the rename ends.
@MainActor protocol TitleRenameEditing: AnyObject {
    var startText: String { get }
    var prompt: String { get }
    var text: String { get set }
    var isTab: Bool { get }
    var isEnded: Bool { get }
    var keyboardBefore: AnyObject? { get set }
}

/// How a rename typed into the window's title ended.
enum TitleRenameEnding {
    /// Return: the name is sent, if it can be.
    case submit
    /// Escape: nothing is sent.
    case cancel
    /// The keyboard went elsewhere, or the field went away: as Return, but
    /// a tab's name left empty is let go of instead.
    case left
}
