#if DEBUG && os(macOS)
import AppKit

/// Test locator only: derive auxiliary windows from this exact owner's native
/// toolbar views. Never search another window merely because its title matches.
@MainActor enum HcNativeTitleTarget {
    struct Target {
        let window: NSWindow
        let point: NSPoint
    }
    static func windows(of owner: NSWindow) -> [NSWindow] {
        var result = [owner]
        for view in owner.toolbar?.items.compactMap(\.view) ?? [] {
            if let window = view.window, !result.contains(where: { $0 === window }) {
                result.append(window)
            }
        }
        return result
    }
    static func find(in owner: NSWindow) -> Target? {
        func search(_ view: NSView, clicked: NSWindow) -> Target? {
            if let label = view as? NSTextField, !label.isEditable,
               !label.isHiddenOrHasHiddenAncestor, label.stringValue == owner.title,
               label.bounds.width > 0, label.bounds.height > 0 {
                let point = label.convert(NSPoint(x:label.bounds.midX,y:label.bounds.midY),to:nil)
                if TitleDoubleClickView.isTitleText(at:point,in:clicked,of:owner) {
                    return Target(window:clicked,point:point)
                }
            }
            return view.subviews.lazy.compactMap { search($0,clicked:clicked) }.first
        }
        for clicked in windows(of:owner) {
            guard var root = clicked.contentView else { continue }
            while let parent = root.superview { root = parent }
            if let result = search(root,clicked:clicked) { return result }
        }
        return nil
    }
}
#endif
