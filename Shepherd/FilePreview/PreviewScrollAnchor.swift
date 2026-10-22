import Foundation

/// A place in a text preview, independent of a lazy stack's estimates of
/// off-screen row heights. Rendered rows are block IDs; source rows are
/// 1-based line numbers. Kept in memory with the pane, never persisted.
nonisolated struct PreviewScrollAnchor: Equatable, Sendable {
    var inSource: Bool
    var row: Int
    var offset: CGFloat
    var height: CGFloat
}
