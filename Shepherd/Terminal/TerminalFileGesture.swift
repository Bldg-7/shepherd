import Foundation
import CoreGraphics

/// Capture at pointer-down, before any TUI input. Once claimed, the complete
/// gesture stays local even if the target disappears, a drag cancels opening,
/// the preview fails, or the pane's connection is retired.
///
/// A double or triple click that starts on a link is the link's too: the
/// presses after the claimed one are claimed as well, but open nothing, so a
/// link opens once however many times it is clicked in a row. What counts is
/// that the click before was claimed, not where the next press lands: the
/// first click can move the link away (a browser column appearing beside the
/// terminal), and the second press then falls on whatever took its place.
nonisolated struct TerminalFileGesture {
    private var link: String?
    private var origin = CGPoint.zero
    private var dragged = false
    private var owned = false
    /// Whether presses that continue this click, as a double or triple
    /// click, are taken without opening anything.
    private var claimsFollowingPresses = false
    var ownsPointer: Bool { owned }

    /// Whether the press is claimed. `clickCount` is the press's place in a
    /// run of clicks, as AppKit counts them: 1 starts a new run.
    mutating func begin(link: String?, at point: CGPoint, clickCount: Int = 1) -> Bool {
        cancel()
        if clickCount > 1, claimsFollowingPresses {
            owned = true; origin = point
            return true
        }
        claimsFollowingPresses = link != nil
        guard let link else { return false }
        self.link = link; origin = point; owned = true
        return true
    }

    mutating func move(to point: CGPoint) {
        guard ownsPointer else { return }
        if hypot(point.x - origin.x, point.y - origin.y) > 8 { dragged = true }
    }

    mutating func end(at point: CGPoint) -> String? {
        move(to: point)
        let result = dragged ? nil : link
        cancel()
        return result
    }

    mutating func cancel() { link = nil; dragged = false; owned = false }
}

/// How a link was clicked, for whoever opens it: whether ⌘ was held, which
/// opens a web link in the default browser rather than the pane's In-app
/// Browser (see `LinkDestinationPolicy`). `unknown` for a click SwiftTerm
/// reports itself.
nonisolated struct TerminalLinkClick: Equatable, Sendable {
    var commandHeld = false

    static let unknown = TerminalLinkClick()
}
