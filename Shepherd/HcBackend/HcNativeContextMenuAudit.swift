#if DEBUG && os(macOS)
import AppKit
import Foundation

/// Opens the actual owned row's menu, observes its native tracking, and sends
/// one enabled menu-item action. No substitute model closure/global events.
@MainActor enum HcNativeContextMenuAudit {
    @MainActor private final class Probe: NSObject {
        let window: NSWindow
        let title: String
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        var menu: NSMenu?
        var dispatched = false
        var finished = false
        var items: [[String:Any]] = []
        init(window: NSWindow, title: String) { self.window = window; self.title = title }
        // NSMenu tracking is an AppKit main-thread notification. A selector
        // callback keeps Notification inside that UI boundary, rather than
        // sending the non-Sendable notification through an actor closure.
        @objc func menuBegan(_ note: Notification) {
            precondition(Thread.isMainThread)
            menu = note.object as? NSMenu
        }
        @objc func tick(_ timer: Timer) {
            guard !finished else { timer.invalidate(); return }
            guard NSApp.isActive, window.isKeyWindow, ContinuousClock.now < deadline else {
                menu?.cancelTrackingWithoutAnimation(); finished = true; timer.invalidate(); return
            }
            guard let menu else { return }
            items = menu.items.map { ["title":$0.title,"enabled":$0.isEnabled,"hidden":$0.isHidden,"action":$0.action.map(NSStringFromSelector) ?? "nil"] }
            let matches = menu.items.indices.filter { menu.items[$0].title == title && !menu.items[$0].isHidden }
            guard matches.count == 1, let index = matches.first, menu.items[index].isEnabled, menu.items[index].action != nil else { return }
            dispatched = true; finished = true; timer.invalidate()
            menu.performActionForItem(at:index)
            menu.cancelTrackingWithoutAnimation()
        }
    }
    static func perform(_ title: String, row: String, content: NSView, root: URL, label: String) async throws {
        guard NSApp.isActive, let window = content.window, window.isKeyWindow,
              let element = HcWorkspaceLayoutAudit.elements(content)[row],
              let rect = (element as AnyObject).accessibilityFrame?(), rect.width > 0, rect.height > 0 else {
            throw HcWorkspaceLayoutAudit.Failure.assertion("owned context row ready")
        }
        let probe = Probe(window:window,title:title)
        NotificationCenter.default.addObserver(probe,selector:#selector(Probe.menuBegan(_:)),name:NSMenu.didBeginTrackingNotification,object:nil)
        defer { NotificationCenter.default.removeObserver(probe,name:NSMenu.didBeginTrackingNotification,object:nil); probe.menu?.cancelTrackingWithoutAnimation() }
        let timer = Timer(timeInterval:0.05,target:probe,selector:#selector(Probe.tick(_:)),userInfo:nil,repeats:true)
        RunLoop.main.add(timer,forMode:.eventTracking); RunLoop.main.add(timer,forMode:.common)
        defer { timer.invalidate() }
        let point = window.convertPoint(fromScreen:NSPoint(x:rect.midX,y:rect.midY))
        var frameView = content
        while let parent = frameView.superview { frameView = parent }
        guard let hit = frameView.hitTest(point), hit.window === window,
              let event = NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) else {
            throw HcWorkspaceLayoutAudit.Failure.assertion("owned native context target")
        }
        // Preselect one native dispatch route; never replay an uncertain click
        // through another route. The native tracking loop runs the live timer.
        hit.rightMouseDown(with:event)
        try await HcWorkspaceLayoutAudit.wait("actual context menu dispatch",seconds:6) { probe.finished }
        try JSONSerialization.data(withJSONObject:["opened":probe.menu != nil,"dispatchedOnce":probe.dispatched,
            "title":title,"items":probe.items,"row":row,"hitClass":String(describing:type(of:hit)),
            "localDispatch":"nativeView.rightMouseDown","globalEventInjection":false]).write(to:root.appending(path:label+".json"),options:.atomic)
        guard probe.dispatched else { throw HcWorkspaceLayoutAudit.Failure.assertion("native context action: "+title) }
    }
}
#endif
