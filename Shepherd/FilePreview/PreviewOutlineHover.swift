import Foundation

/// The small view-local state rule for a Markdown table of contents over a
/// preview. The pointer region includes its trigger and, once shown, the
/// panel, so moving between them never closes the panel in between.
nonisolated enum PreviewOutlineHover {
    static func isPresented(pointerInside: Bool, hasKeyboardFocus: Bool, hasExplicitReveal: Bool) -> Bool {
        pointerInside || hasKeyboardFocus || hasExplicitReveal
    }
}
