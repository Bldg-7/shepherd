import Foundation
import CoreGraphics

/// Capture at pointer-down, before any TUI input. Once claimed, the complete
/// gesture stays local even if the target disappears, a drag cancels opening,
/// the preview fails, or the pane's connection is retired.
nonisolated struct TerminalFileGesture {
    private var link: String?
    private var origin = CGPoint.zero
    private var dragged = false
    var ownsPointer: Bool { link != nil }

    mutating func begin(link: String?, at point: CGPoint) -> Bool {
        cancel()
        guard let link else { return false }
        self.link = link; origin = point
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

    mutating func cancel() { link = nil; dragged = false }
}
