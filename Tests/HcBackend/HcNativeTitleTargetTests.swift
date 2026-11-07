import AppKit
import Foundation

@MainActor private final class FixtureToolbar: NSObject, NSToolbarDelegate {
    let item = NSToolbarItem(itemIdentifier: .init("owned-anchor"))
    override init() { super.init(); item.view = NSView(frame:NSRect(x:0,y:0,width:50,height:25)) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [item.itemIdentifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [item.itemIdentifier] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { itemIdentifier == item.itemIdentifier ? item : nil }
}
@main @MainActor private struct HcNativeTitleTargetTests {
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value,message); checks += 1 }
        func window() -> NSWindow {
            let w = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:500),styleMask:[.titled,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            w.isReleasedWhenClosed = false; return w
        }
        let owner = window(), auxiliary = window(), unrelated = window()
        defer { owner.close(); auxiliary.close(); unrelated.close() }
        owner.title = "Owned title"; auxiliary.title = owner.title; unrelated.title = owner.title
        let fixture = FixtureToolbar(), toolbar = NSToolbar(identifier:"owned-toolbar")
        toolbar.delegate = fixture; owner.toolbar = toolbar
        owner.contentView?.superview?.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(3)
        while (toolbar.items.isEmpty || HcNativeTitleTarget.find(in:owner) == nil) && Date() < end {
            RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))
        }
        check(toolbar.items.first === fixture.item,"actual owned toolbar item mounted")
        check(HcNativeTitleTarget.find(in:owner)?.window === owner,"ordinary native title resolves in owner")
        check(HcNativeTitleTarget.windows(of:owner).count == 1,"owner's native toolbar windows deduplicate")
        owner.titleVisibility = .hidden
        let lookalike = NSTextField(labelWithString:owner.title)
        lookalike.frame = NSRect(x:0,y:0,width:160,height:25); owner.contentView?.addSubview(lookalike)
        check(HcNativeTitleTarget.find(in:owner) == nil,"content lookalike and unrelated matching title are not native title authority")
        // Composition seam only, never fullscreen/physical GUI evidence: put
        // the exact retained native toolbar anchor in an owned auxiliary host.
        auxiliary.contentView?.addSubview(fixture.item.view!)
        check(fixture.item.view?.window === auxiliary,"same native toolbar item is auxiliary-hosted")
        check(HcNativeTitleTarget.windows(of:owner).contains(where:{ $0 === auxiliary }),"auxiliary scope comes from exact item membership")
        check(HcNativeTitleTarget.find(in:owner)?.window === auxiliary,"auxiliary native title resolves with the production hit predicate")
        check(!HcNativeTitleTarget.windows(of:owner).contains(where:{ $0 === unrelated }),"matching title alone never associates another window")
        fixture.item.view?.removeFromSuperview()
        check(HcNativeTitleTarget.find(in:owner) == nil,"retired auxiliary association cannot supply a title target")
        owner.title = ""
        check(HcNativeTitleTarget.find(in:owner) == nil,"empty native title has no target")
        check(!owner.isVisible && !auxiliary.isVisible && !unrelated.isVisible,"all component windows remain never-shown")
        print("PASS \(checks) native title locator checks; auxiliary composition seam, no GUI/focus/events/fullscreen authority")
    }
}
