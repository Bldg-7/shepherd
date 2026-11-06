#if DEBUG && os(macOS)
import AppKit
import CoreGraphics
import Foundation
import SwiftTerm

private nonisolated struct HcLayoutAuditOwnedStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32
    let holders: [Holder]
}

@MainActor private final class HcAuditFullscreenObservation {
    var entered = false
    var exited = false
    private var tokens: [NSObjectProtocol] = []
    init(window: NSWindow) {
        tokens.append(NotificationCenter.default.addObserver(forName:NSWindow.didEnterFullScreenNotification,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.entered = true }
        })
        tokens.append(NotificationCenter.default.addObserver(forName:NSWindow.didExitFullScreenNotification,object:window,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.exited = true }
        })
    }
    isolated deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// Actual hc-root composition audit, not a substitute for product approval.
/// Operates only on the explicitly owned fixture window/core and public APIs.
@MainActor enum HcWorkspaceLayoutAudit {
    enum Failure: Error { case assertion(String) }
    static func wait(_ label: String, seconds: Double = 6, _ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
        while !predicate() {
            guard !Task.isCancelled, ContinuousClock.now < end else { throw Failure.assertion(label) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func split(_ view: NSView) -> NSSplitViewController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           controller.splitViewItems.count == 2 { return controller }
        return view.subviews.lazy.compactMap { split($0) }.first
    }
    static func terminals(_ view: NSView) -> [FocusReportingTerminalView] {
        if let terminal = view as? FocusReportingTerminalView { return [terminal] }
        return view.subviews.flatMap(terminals)
    }
    static func elements(_ view: NSView) -> [String:NSObject] {
        var result: [String:NSObject] = [:], seen = Set<ObjectIdentifier>()
        func visit(_ node: AnyObject, depth: Int) {
            guard depth < 60, seen.count < 16000, seen.insert(ObjectIdentifier(node)).inserted else { return }
            if let element = node as? NSAccessibilityElementProtocol, let id = element.accessibilityIdentifier?(),
               let object = node as? NSObject, !id.isEmpty { result[id] = object }
            for next in (node.accessibilityChildren?() ?? nil) ?? [] { visit(next as AnyObject, depth: depth + 1) }
            if let view = node as? NSView { for next in view.subviews { visit(next, depth: depth + 1) } }
        }
        // Toolbar buttons are siblings of content, not children of the detail.
        visit(view.superview ?? view, depth: 0)
        for item in view.window?.toolbar?.items ?? [] { if let own = item.view { visit(own, depth: 0) } }
        if view.window?.styleMask.contains(.fullScreen) == true {
            // AppKit may host this app's fullscreen toolbar in an auxiliary
            // window. No other application's AX tree is ever queried.
            for window in NSApp.windows where window !== view.window {
                if let own = window.contentView { visit(own.superview ?? own, depth: 0) }
            }
        }
        return result
    }
    static func press(_ id: String, content: NSView) throws {
        guard NSApp.isActive, let window = content.window, window.isKeyWindow else { throw Failure.assertion("owned active window") }
        if let toolbar = window.toolbar, let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == id }) {
            guard item.isEnabled, toolbar.isVisible, toolbar.visibleItems?.contains(where: { $0 === item }) == true else {
                throw Failure.assertion("actual visible enabled toolbar item: " + id)
            }
            if let button = item.view as? NSButton {
                guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { throw Failure.assertion("native toolbar button") }
                button.performClick(nil)
                return
            }
            if let action = item.action {
                guard NSApp.sendAction(action, to:item.target, from:item) else { throw Failure.assertion("native toolbar action") }
                return
            }
            // A custom SwiftUI toolbar item owns its hosted AX subtree.
            // Choose that route before any dispatch; never replay a false one.
            guard let own = item.view else { throw Failure.assertion("native toolbar has no view/action") }
            let object = elements(own)[id]
            guard let object, (object as AnyObject).isAccessibilityEnabled?() == true,
                  (object as AnyObject).accessibilityPerformPress?() == true else { throw Failure.assertion("hosted native toolbar action") }
            return
        }
        guard NSApp.isActive, content.window?.isKeyWindow == true,
              let control = elements(content)[id], (control as AnyObject).isAccessibilityEnabled?() == true else {
            throw Failure.assertion("actual enabled control: " + id)
        }
        if let cell = control as? NSCell {
            // Pick one native route before dispatch; no retry after AX false.
            guard let button = cell.controlView as? NSButton, button.cell === cell,
                  let owner = button.window, NSApp.windows.contains(where: { $0 === owner }),
                  owner.isVisible, button.isEnabled, !button.isHiddenOrHasHiddenAncestor else {
                throw Failure.assertion("owned native toolbar control: " + id)
            }
            button.performClick(nil)
        } else {
            guard (control as AnyObject).accessibilityPerformPress?() == true else { throw Failure.assertion("actual control: " + id) }
        }
    }
    static func clickRow(_ id: String, content: NSView) throws {
        guard NSApp.isActive, let window = content.window, window.isKeyWindow,
              let node = elements(content)[id], let rect = (node as AnyObject).accessibilityFrame?(),
              rect.width > 0, rect.height > 0 else { throw Failure.assertion("actual visible row: " + id) }
        let point = window.convertPoint(fromScreen:NSPoint(x:rect.midX,y:rect.midY))
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0) else {
                throw Failure.assertion("owned row event")
            }
            NSApp.sendEvent(event)
        }
    }
    static func grid(_ terminal: FocusReportingTerminalView) -> [Int] {
        let screen = terminal.getTerminal(); return [screen.cols,screen.rows]
    }
    static func frame(_ terminal: NSView, in content: NSView) -> NSRect { terminal.convert(terminal.bounds, to: content) }
    static func geometry(_ terminal: NSView, content: NSView) -> [[String:Any]] {
        var result: [[String:Any]] = [], node: NSView? = terminal
        while let view = node, result.count < 30 {
            let f = view.convert(view.bounds,to:content), inset = view.safeAreaInsets
            result.append(["class":String(describing:type(of:view)),"frame":[f.minX,f.minY,f.width,f.height],
                "safeArea":[inset.top,inset.left,inset.bottom,inset.right]])
            if view === content { break }
            node = view.superview
        }
        return result
    }
    static func settleGeometry(_ terminal: NSView, content: NSView) async throws {
        var previous = frame(terminal,in:content), stable = 0
        for _ in 0..<200 {
            try await Task.sleep(for:.milliseconds(20))
            let next = frame(terminal,in:content)
            if near(previous,next) { stable += 1 } else { stable = 0; previous = next }
            if stable >= 15 { return }
        }
        throw Failure.assertion("native geometry did not settle")
    }
    static func near(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX-b.minX) < 1 && abs(a.minY-b.minY) < 1 && abs(a.width-b.width) < 1 && abs(a.height-b.height) < 1
    }
    static func run(model: HcWorkspaceModel, connection: CoreRPCConnection, root: URL,
                    fullscreen: Bool) async throws -> [String:Any] {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure.assertion(label) }; checks += 1
        }
        let workspace = try await model.createWorkspace(name: "Owned UI behavior audit")
        try await model.launchTab(workspaceID: workspace, name: "Owned terminal", argv: ["/usr/bin/python3","-I","-S","-B",root.appending(path:"ui-peer.py").path])
        guard let reference = model.selectedTab?.layout?.panes.first?.terminal else { throw Failure.assertion("known run receipt") }
        let status: HcLayoutAuditOwnedStatus = try await connection.call("server.status").result()
        let records = try await HcTerminalBoard(connection:connection).list(all:true)
        let owned = [status.pid] + status.holders.map(\.pid) + records.compactMap(\.pid)
        try JSONSerialization.data(withJSONObject:["ownedPIDs":owned,"auditPending":true]).write(to:root.appending(path:"audit-owned-identities.json"),options:.atomic)
        try await wait("actual hc terminal rendered", seconds: 12) { HcMigrationRenderProbe.shared.text.contains("HC-UI-RENDER-DONE") }
        guard let window = NSApp.windows.first(where: { $0.contentView?.bounds.width ?? 0 > 500 }),
              let content = window.contentView else { throw Failure.assertion("owned hc root window") }
        NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil)
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with:NSNumber(value:true), with:"AXEnhancedUserInterface")
        try Data("{}".utf8).write(to: root.appending(path:"ui-wants-focus.json"), options:.atomic)
        let activationEnd = ContinuousClock.now.advanced(by:.seconds(12))
        var tried = false
        while !NSApp.isActive || !window.isKeyWindow {
            if !tried, FileManager.default.fileExists(atPath:root.appending(path:"activation-yielded.json").path),
               let value = ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_PARENT_PID"], let pid = Int32(value),
               let parent = NSRunningApplication(processIdentifier:pid),
               HcFixtureBundlePath.matches(parent.bundleURL,expected:root.appending(path:"OwnedUILauncher.app")) {
                _ = NSRunningApplication.current.activate(from:parent,options:[.activateAllWindows]); tried = true
            }
            guard ContinuousClock.now < activationEnd else { throw Failure.assertion("owned foreground readiness") }
            try await Task.sleep(for:.milliseconds(20))
        }
        let toolbarFacts = (window.toolbar?.items ?? []).map { item in
            ["id":item.itemIdentifier.rawValue,"enabled":item.isEnabled,"view":item.view.map { String(describing:type(of:$0)) } ?? "nil",
             "action":item.action.map(NSStringFromSelector) ?? "nil"] as [String:Any]
        }
        try JSONSerialization.data(withJSONObject:toolbarFacts).write(to:root.appending(path:"native-toolbar-audit.json"),options:.atomic)
        try await wait("actual hc tree and native sidebar toolbar") {
            split(content) != nil && terminals(content).count == 1
                && window.toolbar?.items.contains(where: { $0.itemIdentifier.rawValue == "workspace-sidebar-toggle" }) == true
        }
        guard let controller = split(content), let sidebar = controller.splitViewItems.first,
              let terminal = terminals(content).first else { throw Failure.assertion("actual native sidebar/terminal") }
        let originalRecord = try await HcTerminalBoard(connection:connection).get(reference.terminalID)
        let originalTerminal = ObjectIdentifier(terminal)
        let wasFullscreen = window.styleMask.contains(.fullScreen)
        let fullscreenEvents = HcAuditFullscreenObservation(window: window)
        let originalPointer = NSEvent.mouseLocation
        var lastWarp: NSPoint?
        func movePointer(_ point: NSPoint) throws {
            guard NSApp.isActive, window.isKeyWindow else { throw Failure.assertion("owned foreground lost before pointer move") }
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let target = CGPoint(x:point.x,y:primaryTop-point.y)
            guard CGWarpMouseCursorPosition(target) == .success else { throw Failure.assertion("public pointer move refused") }
            lastWarp = point
            let observed = CGEvent(source:nil)?.location ?? .zero
            let trace = root.appending(path:"pointer-audit.jsonl")
            let eventWindow = NSApp.orderedWindows.first(where: { $0.isVisible && $0.frame.contains(point) }) ?? window
            let line = try JSONSerialization.data(withJSONObject:["requested":[target.x,target.y],"observed":[observed.x,observed.y],
                "eventWindow":eventWindow.windowNumber,"rootWindow":window.windowNumber,
                "windowFrame":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height]])
            if !FileManager.default.fileExists(atPath:trace.path) { _ = FileManager.default.createFile(atPath:trace.path,contents:nil) }
            let file = try FileHandle(forWritingTo:trace); try file.seekToEnd(); try file.write(contentsOf:line + Data([10])); try file.close()
            // Deliver movement only to this app's own window; no global CGEvent
            // injection, accessibility grant, external app or private API.
            if let event = NSEvent.mouseEvent(with:.mouseMoved,location:eventWindow.convertPoint(fromScreen:point),modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:eventWindow.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0) {
                NSApp.sendEvent(event)
            }
        }
        var restoreStarted = false, restoreSucceeded = false
        func restore() async -> Bool {
            if restoreStarted { return restoreSucceeded }
            restoreStarted = true
            var pointerRestored = true
            if let lastWarp, hypot(NSEvent.mouseLocation.x-lastWarp.x,NSEvent.mouseLocation.y-lastWarp.y) < 3 {
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                pointerRestored = CGWarpMouseCursorPosition(CGPoint(x:originalPointer.x,y:primaryTop-originalPointer.y)) == .success
            }
            if !wasFullscreen && window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                do { try await wait("exit owned fullscreen",seconds:10) { fullscreenEvents.exited && !window.styleMask.contains(.fullScreen) } }
                catch { return false }
            }
            restoreSucceeded = pointerRestored
            return restoreSucceeded
        }
        do {
            if fullscreen && !wasFullscreen {
                window.toggleFullScreen(nil)
                try await wait("enter actual owned fullscreen",seconds:10) { fullscreenEvents.entered && window.styleMask.contains(.fullScreen) && !window.inLiveResize }
            }
            // Start with the same explicit unpin action as the existing UI.
            if !sidebar.isCollapsed { try press("workspace-sidebar-toggle",content:content) }
            try await wait("sidebar actually collapsed") { sidebar.isCollapsed }
            try await settleGeometry(terminal,content:content)
            let before = frame(terminal,in:content), beforeGrid = grid(terminal)
            let beforeAncestors = geometry(terminal,content:content)
            let resizeCount = HcMigrationRenderProbe.shared.resizeEvents.count
            if fullscreen {
                // Establish a known in-window starting position first. A warp
                // to an already occupied rim is not an edge-entry stimulus.
                try movePointer(NSPoint(x:window.frame.midX,y:window.frame.midY))
                try await Task.sleep(for:.milliseconds(150))
                for x in [40.0,10.0,1.0] {
                    try movePointer(NSPoint(x:window.frame.minX+x,y:window.frame.midY))
                    try await Task.sleep(for:.milliseconds(40))
                }
                try await wait("actual fullscreen edge reveal",seconds:5) { !sidebar.isCollapsed }
                // Enter the revealed native drawer as a real pointer traversal
                // does, rather than parking on its one-pixel dismissal rim.
                try movePointer(NSPoint(x:window.frame.minX+40,y:window.frame.midY))
            } else {
                controller.toggleSidebar(nil)
                try await wait("actual native reveal") { !sidebar.isCollapsed }
            }
            try await wait("native drawer finishes revealing") { !sidebar.isCollapsed && sidebar.viewController.view.bounds.width >= WorkspaceSidebarMetrics.preferred }
            try await settleGeometry(terminal,content:content)
            let after = frame(terminal,in:content)
            try JSONSerialization.data(withJSONObject:["beforeFrame":[before.minX,before.minY,before.width,before.height],
                "afterFrame":[after.minX,after.minY,after.width,after.height],"beforeGrid":beforeGrid,"afterGrid":grid(terminal),
                "resizeEventsDuringReveal":Array(HcMigrationRenderProbe.shared.resizeEvents.dropFirst(resizeCount)),
                "beforeAncestors":beforeAncestors,"afterAncestors":geometry(terminal,content:content),
                "sameRootController":split(content) === controller,"fullscreen":fullscreen,
                "sidebarWidth":sidebar.viewController.view.bounds.width,"sidebarCollapsed":sidebar.isCollapsed,
                "sidebarEvents":WorkspaceSidebarDiagnostics.events,
                "ownWindows":NSApp.windows.map { ["number":$0.windowNumber,"visible":$0.isVisible,"frame":[ $0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height]] as [String:Any] }])
                .write(to:root.appending(path:"reveal-geometry.json"),options:.atomic)
            try check(near(before,frame(terminal,in:content)),"reveal must overlay actual hc terminal, not resize it")
            try check(grid(terminal) == beforeGrid,"reveal must preserve actual hc grid")
            try check(terminals(content).first.map { ObjectIdentifier($0) == originalTerminal } == true,"reveal must preserve terminal identity")
            try check(sidebar.viewController.view.bounds.width >= WorkspaceSidebarMetrics.preferred,"native revealed width must be at least360")
            try press("workspace-sidebar-toggle",content:content)
            try await wait("actual explicit pin reserves width") { !sidebar.isCollapsed && terminal.bounds.width < before.width }
            checks += 1
            // Native collapse is an API-driven component step, not a claimed
            // physical divider drag. Reopen uses the actual production button.
            sidebar.isCollapsed = true
            try await wait("native collapse reconciled") { sidebar.isCollapsed }
            try await Task.sleep(for:.milliseconds(100))
            try press("workspace-sidebar-toggle",content:content)
            try await wait("single actual button reopens") { !sidebar.isCollapsed }
            checks += 1
            // Drive the actual retained-mode toggle and row, not the model's
            // selection API: a mode switch must clear the displayed selection.
            guard let tabID = model.selectedTab?.id else { throw Failure.assertion("selected tab") }
            try press("workspace.board.group-by-tab",content:content)
            try await wait("mode change clears actual selected terminal") { terminals(content).isEmpty }
            checks += 1
            try await wait("actual grouped tab row") { elements(content)["hc-workspace.tab.\(tabID)"] != nil }
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("actual tab row selects terminal") { terminals(content).count == 1 }
            checks += 1
            // Same-row activation must return the keyboard after filtering,
            // without requiring a new attach or an artificial focus flag.
            guard let activeTerminal = terminals(content).first else { throw Failure.assertion("selected actual terminal") }
            try clickRow("workspace.board.filter",content:content)
            try await wait("actual filter receives keyboard") { window.firstResponder !== activeTerminal }
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("same-row activation restores keyboard") { window.firstResponder === activeTerminal }
            checks += 1
            // Real preview reader/panel on the selected hc pane. Opening uses
            // the production file-gesture callback; expansion/return use the
            // actual panel control and must not detach the live terminal.
            guard let openFile = activeTerminal.onOpenFileGesture else { throw Failure.assertion("actual file gesture") }
            let previewURL = root.appending(path:"owned-preview.md").absoluteString
            openFile(previewURL,.unknown)
            try await wait("actual preview file contents") { hcAccessibilityText(content).contains("HC-FILE-PREVIEW-CONTENT") }
            try check(terminals(content).first === activeTerminal,"preview opening retains native terminal")
            let sideGrid = grid(activeTerminal), sideFrame = frame(activeTerminal,in:content)
            try press("preview.expand",content:content)
            try await wait("preview expansion takes keyboard from terminal") { window.firstResponder !== activeTerminal }
            try await settleGeometry(activeTerminal,content:content)
            try check(terminals(content).first === activeTerminal && near(sideFrame,frame(activeTerminal,in:content)) && grid(activeTerminal) == sideGrid,
                      "expanded preview covers without reparent/resize/detach")
            try press("preview.expand",content:content)
            try await settleGeometry(activeTerminal,content:content)
            try check(terminals(content).first === activeTerminal && grid(activeTerminal) == sideGrid,"preview return retains same terminal/grid")
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("row returns keyboard after preview") { window.firstResponder === activeTerminal }
            checks += 1
            let record = try await HcTerminalBoard(connection:connection).get(reference.terminalID)
            try check(record.pid == originalRecord.pid && record.createdMs == originalRecord.createdMs && record.state == "live",
                      "sidebar does not replace or end actual hc program")
            guard await restore() else { throw Failure.assertion("owned fullscreen/pointer cleanup") }
            let result: [String:Any] = ["passed":true,"checks":checks,"actualHcRoot":true,"actualCore":true,
                "fullscreenSpaceAndEdgeReveal":fullscreen,"fullscreenExitRestored":restoreSucceeded,"nativeRevealOnly":!fullscreen,"physicalDividerDrag":"NOTRUN",
                "globalEventInjection":false,"borrowedPermissions":false,"releaseCutover":false,"ownedPIDs":owned]
            try JSONSerialization.data(withJSONObject:result).write(to:root.appending(path:"layout-audit.json"),options:.atomic)
            return result
        } catch {
            let cleanup = await restore()
            try? JSONSerialization.data(withJSONObject:["passed":false,"checks":checks,"error":String(describing:error),"fullscreenRequested":fullscreen,"fullscreenExitRestored":cleanup])
                .write(to:root.appending(path:"layout-audit.json"),options:.atomic)
            throw error
        }
    }
}
#endif
