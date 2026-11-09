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

/// Component stand-in for AppKit's destination protocol, NOT a physical drag.
/// The pasteboard is uniquely owned and never the user's clipboard.
@MainActor private final class HcAuditRowDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let source: AnyObject?
    init(_ pasteboard: NSPasteboard, source: AnyObject?) { draggingPasteboard = pasteboard; self.source = source }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
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
    static func renderedFlatText(_ view: FocusReportingTerminalView) -> String {
        let screen = view.getTerminal()
        return (0..<screen.rows).compactMap { screen.getLine(row:$0)?.translateToString(trimRight:true,
            skipNullCellsFollowingWide:true,characterProvider:screen.getCharacter) }.joined()
    }
    static func terminals(_ view: NSView) -> [FocusReportingTerminalView] {
        if let terminal = view as? FocusReportingTerminalView { return [terminal] }
        return view.subviews.flatMap(terminals)
    }
    static func elements(_ view: NSView, includeChrome: Bool = true) -> [String:NSObject] {
        var result: [String:NSObject] = [:], seen = Set<ObjectIdentifier>()
        func visit(_ node: AnyObject, depth: Int) {
            guard depth < 60, seen.count < 16000, seen.insert(ObjectIdentifier(node)).inserted else { return }
            if let element = node as? NSAccessibilityElementProtocol, let id = element.accessibilityIdentifier?(),
               let object = node as? NSObject, !id.isEmpty { result[id] = object }
            for next in (node.accessibilityChildren?() ?? nil) ?? [] { visit(next as AnyObject, depth: depth + 1) }
            if let view = node as? NSView { for next in view.subviews { visit(next, depth: depth + 1) } }
        }
        // Native toolbar paths can request only their own hosted subtree;
        // unrelated sheets/hidden auxiliaries must not override a live AX node.
        visit(includeChrome ? (view.superview ?? view) : view, depth: 0)
        if includeChrome, let owner = view.window {
            for item in owner.toolbar?.visibleItems ?? [] { if let own = item.view { visit(own, depth: 0) } }
            if owner.styleMask.contains(.fullScreen) {
                for window in HcNativeTitleTarget.windows(of:owner) where window !== owner && window.isVisible {
                    if let own = window.contentView { visit(own.superview ?? own, depth: 0) }
                }
            }
        }
        return result
    }
    private static var lastPress: [String:Any] = [:]
    static func press(_ id: String, content: NSView) throws {
        lastPress = ["identifier":id,"route":"not-dispatched","dispatched":false]
        guard NSApp.isActive, let window = content.window, window.isKeyWindow else { throw Failure.assertion("owned active window") }
        if let toolbar = window.toolbar, let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == id }) {
            lastPress["route"] = "native-toolbar"; lastPress["itemEnabled"] = item.isEnabled
            lastPress["itemWindow"] = item.view?.window?.windowNumber ?? -1
            guard item.isEnabled, toolbar.isVisible, toolbar.visibleItems?.contains(where: { $0 === item }) == true else {
                throw Failure.assertion("actual visible enabled toolbar item: " + id)
            }
            if let button = item.view as? NSButton {
                guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { throw Failure.assertion("native toolbar button") }
                lastPress["dispatched"] = true; lastPress["action"] = "native-button"
                button.performClick(nil)
                return
            }
            if let action = item.action {
                lastPress["dispatched"] = true; lastPress["action"] = "native-item-action"
                guard NSApp.sendAction(action, to:item.target, from:item) else { throw Failure.assertion("native toolbar action") }
                return
            }
            // A custom SwiftUI toolbar item owns its hosted AX subtree.
            // Choose that route before any dispatch; never replay a false one.
            guard let own = item.view else { throw Failure.assertion("native toolbar has no view/action") }
            let object = elements(own,includeChrome:false)[id]
            guard let object, (object as AnyObject).isAccessibilityEnabled?() == true else { throw Failure.assertion("hosted native toolbar readiness") }
            lastPress["dispatched"] = true; lastPress["action"] = "scoped-hosted-AX"
            guard (object as AnyObject).accessibilityPerformPress?() == true else { throw Failure.assertion("hosted native toolbar action") }
            return
        }
        guard NSApp.isActive, content.window?.isKeyWindow == true,
              let control = elements(content)[id], (control as AnyObject).isAccessibilityEnabled?() == true else {
            throw Failure.assertion("actual enabled control: " + id)
        }
        lastPress["route"] = "content"; lastPress["controlClass"] = String(describing:type(of:control))
        if let cell = control as? NSCell {
            // Pick one native route before dispatch; no retry after AX false.
            guard let button = cell.controlView as? NSButton, button.cell === cell,
                  let owner = button.window, NSApp.windows.contains(where: { $0 === owner }),
                  owner.isVisible, button.isEnabled, !button.isHiddenOrHasHiddenAncestor else {
                throw Failure.assertion("owned native toolbar control: " + id)
            }
            lastPress["dispatched"] = true; lastPress["action"] = "native-cell-button"
            button.performClick(nil)
        } else {
            lastPress["dispatched"] = true; lastPress["action"] = "content-AX"
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
    static func renameField(_ view: NSView) -> TitleRenameTextField? {
        if let field = view as? TitleRenameTextField { return field }
        return view.subviews.lazy.compactMap(renameField).first
    }
    static func renameField(in window: NSWindow) -> TitleRenameTextField? {
        for item in window.toolbar?.visibleItems ?? [] {
            if let view = item.view, let field = renameField(view) { return field }
        }
        return nil
    }
    static func competingWorkspaceRename(_ name: String, workspace: UUID, model: HcWorkspaceModel,
                                         connection: CoreRPCConnection) async throws {
        let competitor = try await CoreWorkspaceStore(connection:connection)
        do {
            let view = try await competitor.start()
            guard let version = view.snapshot?.version else { throw Failure.assertion("competing snapshot") }
            let result = try await competitor.edit(.renameWorkspace(workspace,name),expectedVersion:version)
            guard case .acknowledged = result else { throw Failure.assertion("competing CAS acknowledged") }
            try await competitor.close()
        } catch { try? await competitor.close(); throw error }
        try await wait("competing snapshot reaches actual UI") {
            model.document?.workspaces.first(where: { $0.id == workspace })?.name == name
        }
    }
    static func editNativeTitle(_ text: String, cancel: Bool, window: NSWindow, root: URL,
                                beforeEnding: (@MainActor () async throws -> Void)? = nil) async throws {
        guard NSApp.isActive, window.isKeyWindow else { throw Failure.assertion("owned key title window") }
        let target = HcNativeTitleTarget.find(in:window)
        try JSONSerialization.data(withJSONObject:["owner":window.windowNumber,"ownerKey":window.isKeyWindow,
            "candidates":HcNativeTitleTarget.windows(of:window).map { ["window":$0.windowNumber,"visible":$0.isVisible,"key":$0.isKeyWindow] },
            "targetWindow":target?.window.windowNumber ?? -1,"physicalGestureQualified":false])
            .write(to:root.appending(path:"native-title-target.json"),options:.atomic)
        guard let target, target.window.isVisible,
              HcNativeTitleTarget.windows(of:window).contains(where:{ $0 === target.window }) else {
            throw Failure.assertion("actual title text hit target")
        }
        // The app's own event queue runs the real local event monitor. Never
        // call the rename model closure or post events to another application.
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with:type,location:target.point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:target.window.windowNumber,context:nil,eventNumber:0,clickCount:2,pressure:type == .leftMouseDown ? 1 : 0) else { throw Failure.assertion("owned title event") }
            NSApp.postEvent(event,atStart:false)
        }
        try await wait("real title field owns keyboard") {
            guard let field = renameField(in:window), let editor = field.currentEditor(), let key = NSApp.keyWindow,
                  HcNativeTitleTarget.windows(of:window).contains(where:{ $0 === key }) else { return false }
            return key.firstResponder === editor
        }
        guard let editor = renameField(in:window)?.currentEditor() as? NSTextView,
              let editorWindow = NSApp.keyWindow, editorWindow.firstResponder === editor,
              HcNativeTitleTarget.windows(of:window).contains(where:{ $0 === editorWindow }) else { throw Failure.assertion("title editor") }
        editor.selectAll(nil); editor.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))
        try await beforeEnding?()
        guard editor.string == text else { throw Failure.assertion("title text survives intervening snapshot") }
        if cancel { try key("\u{1b}",code:53,in:editorWindow) } else { try returnKey(in:editorWindow) }
        try await wait("title field dismissed") { renameField(in:window) == nil }
    }
    static func launcherField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.delegate is LauncherField.Coordinator { return field }
        return view.subviews.lazy.compactMap(launcherField).first
    }
    static func launcherField(in window: NSWindow) -> NSTextField? {
        if let view = window.contentView?.superview, let field = launcherField(view) { return field }
        for own in NSApp.windows where own.isVisible && own !== window {
            if let view = own.contentView?.superview, let field = launcherField(view) { return field }
        }
        return nil
    }
    static func ownedSheetContent(_ root: NSWindow) -> NSView? {
        NSApp.windows.first(where: { $0.isVisible && ($0.sheetParent === root || root.attachedSheet === $0) })?.contentView
    }
    static func returnKey(in window: NSWindow) throws { try key("\r",code:36,in:window) }
    static func key(_ characters: String, code: UInt16, in window: NSWindow) throws {
        guard NSApp.isActive, window.isKeyWindow,
              let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code) else {
            throw Failure.assertion("owned switcher key")
        }
        NSApp.sendEvent(event)
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
                    owner: HcMachineConnection, transports: HcFixtureConnectFactory, store: MachineStore, fullscreen: Bool) async throws -> [String:Any] {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure.assertion(label) }; checks += 1
        }
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with:NSNumber(value:true), with:"AXEnhancedUserInterface")
        try await wait("actual initially empty board") {
            NSApp.windows.compactMap(\.contentView).contains { elements($0)["workspace.board.empty"] != nil }
        }
        checks += 1
        guard let window = NSApp.windows.first(where: { $0.contentView?.bounds.width ?? 0 > 500 }),
              let content = window.contentView else { throw Failure.assertion("owned hc root window") }
        NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil)
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with:NSNumber(value:true), with:"AXEnhancedUserInterface")
        try Data("{}".utf8).write(to: root.appending(path:"ui-wants-focus.json"), options:.atomic)
        let humanActivation = ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_HUMAN_ACTIVATION"] == "1"
        let activationEnd = ContinuousClock.now.advanced(by:.seconds(humanActivation ? 150 : 12))
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
        try JSONSerialization.data(withJSONObject:["active":NSApp.isActive,"key":window.isKeyWindow,"window":window.windowNumber])
            .write(to:root.appending(path:"ui-foreground-ready.json"),options:.atomic)
        checks += try await HcNativeDiscoveryAudit.run(model:model,connection:connection,window:window,content:content,root:root)
        let workspace = try await model.createWorkspace(name: "Owned UI behavior audit")
        try await model.launchTab(workspaceID: workspace, name: "Owned terminal", argv: ["/usr/bin/python3","-I","-S","-B",root.appending(path:"ui-peer.py").path])
        guard let reference = model.selectedTab?.layout?.panes.first?.terminal else { throw Failure.assertion("known run receipt") }
        let status: HcLayoutAuditOwnedStatus = try await connection.call("server.status").result()
        let records = try await HcTerminalBoard(connection:connection).list(all:true)
        var owned = [status.pid] + status.holders.map(\.pid) + records.compactMap(\.pid)
        try JSONSerialization.data(withJSONObject:["ownedPIDs":owned,"auditPending":true]).write(to:root.appending(path:"audit-owned-identities.json"),options:.atomic)
        try await wait("actual hc terminal rendered",seconds:12) { HcMigrationRenderProbe.shared.text.contains("HC-UI-RENDER-DONE") }
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
        let warpOnly = ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_POINTER_WARP_ONLY"] == "1"
        let nativeFullscreenLayout = ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_FULLSCREEN_NATIVE_LAYOUT"] == "1"
        guard !nativeFullscreenLayout || (fullscreen && !warpOnly && ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_FULLSCREEN_AUDIT"] != "1") else {
            throw Failure.assertion("native fullscreen layout and edge stimulus must remain separate")
        }
        let edgeStimulus = fullscreen && !nativeFullscreenLayout ? (warpOnly ? "warpOnly" : "warpAndSelfWindowEvent") : "nativeToggle"
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
                "eventWindow":eventWindow.windowNumber,"rootWindow":window.windowNumber,"edgeStimulus":edgeStimulus,
                "windowFrame":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height]])
            if !FileManager.default.fileExists(atPath:trace.path) { _ = FileManager.default.createFile(atPath:trace.path,contents:nil) }
            let file = try FileHandle(forWritingTo:trace); try file.seekToEnd(); try file.write(contentsOf:line + Data([10])); try file.close()
            // Deliver movement only to this app's own window; no global CGEvent
            // injection, accessibility grant, external app or private API.
            if !warpOnly, let event = NSEvent.mouseEvent(with:.mouseMoved,location:eventWindow.convertPoint(fromScreen:point),modifierFlags:[],
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
            if fullscreen && !nativeFullscreenLayout {
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
                "sameRootController":split(content) === controller,"fullscreen":fullscreen,"edgeStimulus":edgeStimulus,
                "pointerAfterReveal":[NSEvent.mouseLocation.x,NSEvent.mouseLocation.y],
                "sidebarWidth":sidebar.viewController.view.bounds.width,"sidebarCollapsed":sidebar.isCollapsed,
                "sidebarEvents":WorkspaceSidebarDiagnostics.events,
                "ownWindows":NSApp.windows.map { ["number":$0.windowNumber,"visible":$0.isVisible,"frame":[ $0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height]] as [String:Any] }])
                .write(to:root.appending(path:"reveal-geometry.json"),options:.atomic)
            try check(near(before,frame(terminal,in:content)),"reveal must overlay actual hc terminal, not resize it")
            try check(grid(terminal) == beforeGrid,"reveal must preserve actual hc grid")
            try check(terminals(content).first.map { ObjectIdentifier($0) == originalTerminal } == true,"reveal must preserve terminal identity")
            try check(sidebar.viewController.view.bounds.width >= WorkspaceSidebarMetrics.preferred,"native revealed width must be at least360")
            if nativeFullscreenLayout {
                // Separate API-driven native layout evidence. Do not call this
                // edge-hover/retention or physical gesture qualification.
                for cycle in 1...3 {
                    controller.toggleSidebar(nil)
                    try await wait("native fullscreen dismissal \(cycle)") { sidebar.isCollapsed }
                    try await settleGeometry(terminal,content:content)
                    try check(near(before,frame(terminal,in:content)) && grid(terminal) == beforeGrid && terminals(content).first === terminal,
                              "native fullscreen dismissal preserves terminal geometry/grid/identity")
                    controller.toggleSidebar(nil)
                    try await wait("native fullscreen reveal \(cycle)") {
                        !sidebar.isCollapsed && sidebar.viewController.view.bounds.width >= WorkspaceSidebarMetrics.preferred
                    }
                    try await settleGeometry(terminal,content:content)
                    try check(!sidebar.isCollapsed && near(before,frame(terminal,in:content)) && grid(terminal) == beforeGrid && terminals(content).first === terminal,
                              "native fullscreen repeat reveal preserves terminal geometry/grid/identity")
                }
            }
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
            guard let originalTitle = model.selectedTab?.name else { throw Failure.assertion("selected title") }
            let titleFrame = window.frame
            let originalLayout = model.selectedTab?.layout
            try await editNativeTitle("Audited 한글 title",cancel:false,window:window,root:root)
            try await wait("native title edit persisted by hc CAS") { model.selectedTab?.name == "Audited 한글 title" }
            try check(model.selectedTab?.layout == originalLayout && near(window.frame,titleFrame),"title double-click does not zoom or replace pane layout")
            let cancelledDocument = model.document
            try await editNativeTitle("Do not save this title",cancel:true,window:window,root:root)
            try check(model.document == cancelledDocument,"native title Escape leaves workspace unchanged")
            try await editNativeTitle(originalTitle,cancel:false,window:window,root:root)
            try await wait("original title restored through native field") { model.selectedTab?.name == originalTitle }
            checks += 1
            try await editNativeTitle("Stale title must not save",cancel:false,window:window,root:root) {
                // A separate subscribed store supplies an actual competing CAS;
                // it is not the UI's rename action and cannot launch/kill/input.
                try await competingWorkspaceRename("Competing layout edit",workspace:workspace,model:model,connection:connection)
            }
            try await hcFixtureWait("hc.rename.unconfirmed.ok",present:true,enabled:true,window:window)
            try check(model.selectedTab?.name == originalTitle && model.selectedTab?.layout == originalLayout,
                      "stale title submit refuses retarget/rebase after competing CAS")
            let refusedDocument = model.document
            try hcFixturePress("hc.rename.unconfirmed.ok")
            try await wait("rename refusal dismissed") { window.attachedSheet == nil && window.isKeyWindow }
            try check(model.document == refusedDocument,"dismissing rename refusal never replays it")
            // Plain Unicode typing above is not a physical IME qualification.
            // Real preview reader/panel on the selected hc pane. Opening uses
            // the production file-gesture callback; expansion/return use the
            // actual panel control and must not detach the live terminal.
            guard let openFile = activeTerminal.onOpenFileGesture else { throw Failure.assertion("actual file gesture") }
            let previewURL = root.appending(path:"owned-preview.md").absoluteString
            openFile(previewURL,.unknown)
            try await wait("actual preview file contents") { hcAccessibilityText(content).contains("HC-FILE-PREVIEW-CONTENT") }
            try check(terminals(content).first === activeTerminal,"preview opening retains native terminal")
            try press("hc.preview.toggle",content:content)
            try await wait("native Hide Preview keeps terminal without showing cached contents") {
                !hcAccessibilityText(content).contains("HC-FILE-PREVIEW-CONTENT") && terminals(content).first === activeTerminal
            }
            let previewFile = root.appending(path:"owned-preview.md")
            let originalPreview = try Data(contentsOf:previewFile)
            try (originalPreview + Data("\nHC-FILE-PREVIEW-REOPENED\n".utf8)).write(to:previewFile,options:.atomic)
            try press("hc.preview.toggle",content:content)
            try await wait("native Show Preview rereads retained file request") {
                hcAccessibilityText(content).contains("HC-FILE-PREVIEW-REOPENED") && terminals(content).first === activeTerminal
            }
            checks += 2
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
            let beforeSwitchFocus = model.focus
            try hcNativeFixtureCommand("p",code:35,label:"audit-switcher-cancel",window:window,root:root)
            try await wait("actual pane switcher sheet") {
                ownedSheetContent(window).map { elements($0)["workspace.switcher.search"] != nil } == true
            }
            guard let sheet = ownedSheetContent(window) else { throw Failure.assertion("owned switcher sheet") }
            try press("workspace.switcher.cancel",content:sheet)
            try await wait("switcher cancel restores main key window") { ownedSheetContent(window) == nil && window.isKeyWindow }
            try check(model.focus == beforeSwitchFocus && terminals(content).first === activeTerminal,"switcher cancel preserves selection/terminal")
            try hcNativeFixtureCommand("p",code:35,label:"audit-switcher-choose",window:window,root:root)
            try await wait("actual switcher editor ready") {
                ownedSheetContent(window)?.window?.isKeyWindow == true
                    && (ownedSheetContent(window).map { elements($0)["workspace.switcher.search"] != nil } == true)
            }
            guard let choosing = ownedSheetContent(window)?.window else { throw Failure.assertion("switcher key sheet") }
            try returnKey(in:choosing)
            try await wait("switcher selection dismisses before keyboard return") { ownedSheetContent(window) == nil && window.isKeyWindow && window.firstResponder === activeTerminal }
            try check(model.focus == beforeSwitchFocus,"same scoped pane selected without retarget")
            let beforeLaunchTabs = model.document?.workspaces.flatMap(\.tabs).map(\.id)
            let beforeLaunchPrograms = try await HcTerminalBoard(connection:connection).list(all:true)
            try hcNativeFixtureCommand("n",code:45,label:"audit-original-launcher",window:window,root:root)
            try await wait("actual original Spotlight launcher field") {
                let field = launcherField(in:window)
                let facts: [String:Any] = ["found":field != nil,"placeholder":field?.placeholderString ?? "nil",
                    "fieldWindow":field?.window?.windowNumber ?? -1,"fieldKey":field?.window?.isKeyWindow ?? false,
                    "editor":field?.currentEditor().map { String(describing:type(of:$0)) } ?? "nil",
                    "firstResponder":window.firstResponder.map { String(describing:type(of:$0)) } ?? "nil",
                    "editorIsFirstResponder":field?.currentEditor() === field?.window?.firstResponder]
                try? JSONSerialization.data(withJSONObject:facts).write(to:root.appending(path:"launcher-focus-audit.json"),options:.atomic)
                guard let field, let editor = field.currentEditor(), field.window === window else { return false }
                return window.firstResponder === editor
            }
            try returnKey(in:window) // Choose the existing workspace; do not launch.
            try await wait("original launcher tab-name step") { launcherField(in:window)?.placeholderString == String(localized:"Tab Name") }
            try key("\u{1b}",code:53,in:window)
            try await wait("actual launcher Esc cancellation") { elements(content)["workspace.launcher.field"] == nil }
            let afterLaunchPrograms = try await HcTerminalBoard(connection:connection).list(all:true)
            try check(model.document?.workspaces.flatMap(\.tabs).map(\.id) == beforeLaunchTabs && afterLaunchPrograms == beforeLaunchPrograms,
                      "launcher navigation/cancel does not create placeholder or program")
            // Create only another view of this exact already-owned program.
            // Actual CmdW + confirmation must hide it, not end/restart it or
            // automatically select a fallback row behind the person's back.
            try await model.showTerminal(reference.terminalID,workspaceID:workspace)
            guard let duplicate = model.selectedTab, duplicate.id != tabID else { throw Failure.assertion("explicit duplicate view") }
            try await wait("actual duplicate view is selected") { elements(content)["hc-workspace.tab.\(duplicate.id)"] != nil && terminals(content).count == 1 }
            guard let external = HcWorkspaceSwitcherCandidates.unplaced(model.terminals,coreID:model.coreID ?? "",document:model.document,snapshotAvailable:true).first else { throw Failure.assertion("known unplaced discovery fixture") }
            let beforeOtherView = try await HcTerminalBoard(connection:connection).get(external.address)
            try hcNativeFixtureCommand("p",code:35,label:"native-other-view-discovery",window:window,root:root)
            try await wait("existing-program switcher search editor") {
                guard let own = ownedSheetContent(window)?.window else { return false }
                return own.isKeyWindow && (own.firstResponder as? NSTextView)?.isFieldEditor == true
            }
            guard let searchWindow = ownedSheetContent(window)?.window, let searchEditor = searchWindow.firstResponder as? NSTextView else { throw Failure.assertion("existing-program search") }
            searchEditor.selectAll(nil); searchEditor.insertText(external.address,replacementRange:NSRange(location:NSNotFound,length:0))
            try await wait("searched canonical terminal is enabled") {
                guard let own = ownedSheetContent(window), let row = elements(own)["workspace.switcher.terminal.\(external.address)"] else { return false }
                return (row as AnyObject).isAccessibilityEnabled?() == true
            }
            let searchContent = ownedSheetContent(window)
            try JSONSerialization.data(withJSONObject:["expectedTerminal":external.address,"editorText":searchEditor.string,
                "keyWindow":searchWindow.isKeyWindow,"editorOwnsKeyboard":searchWindow.firstResponder === searchEditor,
                "identifiers":searchContent.map { Array(elements($0).keys).sorted() } ?? []])
                .write(to:root.appending(path:"native-search-before-return.json"),options:.atomic)
            try returnKey(in:searchWindow)
            try await wait("searched external view selected",seconds:12) {
                ownedSheetContent(window) == nil && model.selectedTab?.layout?.panes.first?.terminal?.terminalID == external.address
            }
            guard let otherView = model.selectedTab, let duplicatePane = duplicate.layout?.panes.first else { throw Failure.assertion("separate current/closing views") }
            try clickRow("hc-workspace.tab.\(duplicate.id)",content:content)
            try await wait("original selection is live before another row closes") {
                model.selectedTab?.id == duplicate.id && HcMigrationRenderProbe.shared.boundView(pane:duplicatePane.id,epoch:model.workspace?.epoch,reference:reference,window:window) != nil
            }
            let selectedBeforeOtherClose = HcMigrationRenderProbe.shared.boundView(pane:duplicatePane.id,epoch:model.workspace?.epoch,reference:reference,window:window)
            try await HcNativeContextMenuAudit.perform("Close Tab",row:"hc-workspace.tab.\(otherView.id)",content:content,root:root,label:"native-context-unselected-close")
            try await hcFixtureWait("hc.close.confirm",present:true,enabled:true,window:window)
            try check(model.selectedTab?.id == duplicate.id,"unselected row context close does not navigate the current detail")
            try hcFixturePress("hc.close.confirm")
            try await wait("unselected context close preserves selected native detail") {
                model.document?.workspaces.flatMap(\.tabs).contains(where:{ $0.id == otherView.id }) == false
                    && model.selectedTab?.id == duplicate.id && terminals(content).first === selectedBeforeOtherClose
                    && window.isKeyWindow
            }
            let afterOtherView = try await HcTerminalBoard(connection:connection).get(external.address)
            try check(afterOtherView.pid == beforeOtherView.pid && afterOtherView.createdMs == beforeOtherView.createdMs && afterOtherView.state == "live",
                      "unselected close keeps its canonical program alive")
            let canceledDocument = model.document, canceledVersion = model.workspace?.snapshot?.version
            let canceledSelection = model.selectedTab?.id, canceledJournalCount = model.recoveryRecords.count
            let cancelPrograms = try await HcTerminalBoard(connection:connection).list(all:true)
            try hcNativeFixtureCommand("w",code:13,label:"native-close-cancel",window:window,root:root)
            try await hcFixtureWait("hc.close.cancel",present:true,enabled:true,window:window)
            try hcFixturePress("hc.close.cancel")
            try await wait("native close Cancel restores unchanged detail") {
                window.isKeyWindow && model.selectedTab?.id == canceledSelection && terminals(content).first === selectedBeforeOtherClose
            }
            let afterCancelPrograms = try await HcTerminalBoard(connection:connection).list(all:true)
            try check(model.document == canceledDocument && model.workspace?.snapshot?.version == canceledVersion && model.recoveryRecords.count == canceledJournalCount,
                      "native close Cancel creates no layout mutation or recovery record")
            try check(afterCancelPrograms.count == cancelPrograms.count && afterCancelPrograms.allSatisfy { after in
                cancelPrograms.contains { $0.address == after.address && $0.pid == after.pid && $0.createdMs == after.createdMs && $0.state == after.state }
            },"native close Cancel preserves every program incarnation/state")
            try hcNativeFixtureCommand("w",code:13,label:"audit-stale-close",window:window,root:root)
            try await hcFixtureWait("hc.close.confirm",present:true,enabled:true,window:window)
            try await competingWorkspaceRename("Competing close edit",workspace:workspace,model:model,connection:connection)
            let afterCompetingClose = model.document
            try hcFixturePress("hc.close.confirm")
            try await hcFixtureWait("hc.workspace.error.ok",present:true,enabled:true,window:window)
            try check(model.document == afterCompetingClose && model.selectedTab?.id == duplicate.id,
                      "stale close confirmation refuses to rebase or remove a changed view")
            try hcFixturePress("hc.workspace.error.ok")
            try await wait("stale close refusal dismissed") { window.attachedSheet == nil && window.isKeyWindow }
            let defaultClosePrograms = try await HcTerminalBoard(connection:connection).list(all:true)
            try hcNativeFixtureCommand("w",code:13,label:"audit-close-confirm",window:window,root:root)
            try await hcFixtureWait("hc.close.confirm",present:true,enabled:true,window:window)
            try hcFixtureDefaultReturn("hc.close.confirm",owner:window,root:root)
            try await wait("closed view is absent and selection stays clear") {
                model.document?.workspaces.flatMap(\.tabs).contains(where: { $0.id == duplicate.id }) == false && terminals(content).isEmpty && window.isKeyWindow
            }
            checks += 1
            let afterClose = try await HcTerminalBoard(connection:connection).list(all:true)
            try check(afterClose.count == beforeLaunchPrograms.count && afterClose.count == defaultClosePrograms.count && afterClose.allSatisfy { after in
                defaultClosePrograms.contains { before in before.address == after.address && before.pid == after.pid && before.createdMs == after.createdMs && before.state == after.state }
            },"native default Return closes only a view and preserves every program incarnation/state")
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("remaining row explicitly restores terminal") { terminals(content).count == 1 }
            checks += 1
            // Hold one exact layout write before dispatch. While its selected
            // close suppresses fallback, choose a different real row. Releasing
            // the original CAS must not clear that newer explicit selection.
            try await model.showTerminal(reference.terminalID,workspaceID:workspace)
            guard let pendingView = model.selectedTab, pendingView.id != tabID,
                  let gate = transports.closeGates.first else { throw Failure.assertion("owned pending-close view/gate") }
            try await wait("pending-close fixture native view selected") { terminals(content).count == 1 && elements(content)["hc-workspace.tab.\(pendingView.id)"] != nil }
            let pendingPrograms = try await HcTerminalBoard(connection:connection).list(all:true)
            let pendingDocument = model.document
            try hcNativeFixtureCommand("w",code:13,label:"native-pending-close",window:window,root:root)
            try await hcFixtureWait("hc.close.confirm",present:true,enabled:true,window:window)
            try await gate.arm()
            try hcFixtureDefaultReturn("hc.close.confirm",owner:window,root:root,label:"native-pending-default-return")
            let gateDeadline = ContinuousClock.now.advanced(by:.seconds(3))
            while !(await gate.snapshot()).entered {
                guard ContinuousClock.now < gateDeadline else { throw Failure.assertion("pending close entered before-dispatch gate") }
                try await Task.sleep(for:.milliseconds(10))
            }
            try await wait("pending selected close suppresses fallback before CAS dispatch") { window.isKeyWindow && terminals(content).isEmpty }
            let heldClose = await gate.snapshot()
            try check(heldClose.forwarded == 0 && !heldClose.released && model.document == pendingDocument,
                      "pending view-only close hides input/detail before any layout write is sent")
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("new explicit row wins while close layout is pending") { model.selectedTab?.id == tabID }
            try await gate.release()
            try await wait("pending close finishes without clearing newer selection") {
                model.canEdit && model.document?.workspaces.flatMap(\.tabs).contains(where:{ $0.id == pendingView.id }) == false
                    && model.selectedTab?.id == tabID && terminals(content).count == 1
            }
            let releasedClose = await gate.snapshot()
            try check(releasedClose.forwarded == 1 && releasedClose.released,"pending close forwards exactly its original layout write once")
            let afterPending = try await HcTerminalBoard(connection:connection).list(all:true)
            try check(afterPending.count == pendingPrograms.count && afterPending.allSatisfy { after in
                pendingPrograms.contains { $0.address == after.address && $0.pid == after.pid && $0.createdMs == after.createdMs && $0.state == after.state }
            },"pending close/newer selection neither restarts nor terminates programs")
            try JSONSerialization.data(withJSONObject:["beforeDispatchHeld":true,"forwardedOnce":releasedClose.forwarded == 1,
                "newerSelectionPreserved":model.selectedTab?.id == tabID,"programIncarnationsPreserved":true,"uncertainReplay":false])
                .write(to:root.appending(path:"native-pending-close.json"),options:.atomic)
            // Multiple panes use one detail-level preview, not a preview split
            // inside an individual pane. Seed the second owned program only;
            // panel expansion still goes through its real UI control.
            guard let firstPane = model.selectedTab?.layout?.panes.first else { throw Failure.assertion("first scoped pane") }
            try await model.launchSplit(paneID:firstPane.id,axis:.horizontal,argv:["/bin/sleep","90"],cwd:root.path)
            let multipleStatus: HcLayoutAuditOwnedStatus = try await connection.call("server.status").result()
            let multipleRecords = try await HcTerminalBoard(connection:connection).list(all:true)
            owned = Array(Set(owned + [multipleStatus.pid] + multipleStatus.holders.map(\.pid) + multipleRecords.compactMap(\.pid))).sorted()
            try JSONSerialization.data(withJSONObject:["ownedPIDs":owned,"auditPending":true]).write(to:root.appending(path:"audit-owned-identities.json"),options:.atomic)
            try model.select(pane:firstPane.id)
            try await wait("actual two-pane tab and retained side preview") { terminals(content).count == 2 && hcAccessibilityText(content).contains("HC-FILE-PREVIEW-CONTENT") }
            let pair = terminals(content)
            try await settleGeometry(pair[0],content:content)
            try await settleGeometry(pair[1],content:content)
            let pairIDs = pair.map(ObjectIdentifier.init), pairFrames = pair.map { frame($0,in:content) }, pairGrids = pair.map(grid)
            try check(pairFrames.allSatisfy { $0.width >= 1 } && pairFrames[0].intersects(pairFrames[1]) == false,"multiple native pane rectangles do not overlap")
            try press("preview.expand",content:content)
            try await settleGeometry(pair[0],content:content)
            try check(terminals(content).map(ObjectIdentifier.init) == pairIDs && pair.enumerated().allSatisfy { near(pairFrames[$0.offset],frame($0.element,in:content)) && grid($0.element) == pairGrids[$0.offset] },
                      "whole-tab preview expansion preserves both native panes and grids")
            try press("preview.expand",content:content)
            try await settleGeometry(pair[0],content:content)
            try check(terminals(content).map(ObjectIdentifier.init) == pairIDs,"whole-tab preview return does not recreate either terminal")
            let beforeZoom = try await HcTerminalBoard(connection:connection).list(all:true)
            try press("workspace.board.group-by-tab",content:content)
            try await wait("pane mode clears selection before context action") { terminals(content).isEmpty }
            try clickRow("hc-workspace.pane.\(firstPane.id)",content:content)
            try await wait("pane row selected for native menu") { terminals(content).count == 1 }
            try await HcNativeContextMenuAudit.perform("Zoom Pane",row:"hc-workspace.pane.\(firstPane.id)",content:content,root:root,label:"native-context-zoom")
            try await wait("native menu sets scoped zoom") { model.focus.zoomByTab[tabID] == firstPane.id }
            try press("workspace.board.group-by-tab",content:content)
            try await wait("tab mode clears selection after zoom") { terminals(content).isEmpty }
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("grouped zoom displays one actual terminal") { terminals(content).count == 1 }
            checks += 1
            try press("workspace.board.group-by-tab",content:content)
            try await wait("pane mode clears zoom view selection") { terminals(content).isEmpty }
            try clickRow("hc-workspace.pane.\(firstPane.id)",content:content)
            try await wait("pane row selected for native unzoom") { terminals(content).count == 1 }
            try await HcNativeContextMenuAudit.perform("Unzoom Pane",row:"hc-workspace.pane.\(firstPane.id)",content:content,root:root,label:"native-context-unzoom")
            try await wait("native menu clears scoped zoom") { model.focus.zoomByTab[tabID] == nil }
            try press("workspace.board.group-by-tab",content:content)
            try await wait("tab mode clears unzoom selection") { terminals(content).isEmpty }
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("unzoom restores both actual terminals") { terminals(content).count == 2 }
            checks += 1
            let afterZoom = try await HcTerminalBoard(connection:connection).list(all:true)
            var zoomProgramsUnchanged = afterZoom.count == beforeZoom.count
            for old in beforeZoom {
                guard let current = afterZoom.first(where:{ $0.address == old.address }) else { zoomProgramsUnchanged = false; break }
                if current.pid != old.pid || current.createdMs != old.createdMs || current.state != old.state { zoomProgramsUnchanged = false }
            }
            try check(zoomProgramsUnchanged,"native zoom/unzoom never starts or terminates a program")
            try press("workspace.board.group-by-tab",content:content)
            try await wait("pane mode ready for native split") { terminals(content).isEmpty }
            try clickRow("hc-workspace.pane.\(firstPane.id)",content:content)
            try await wait("actual pane selected before native split") { terminals(content).count == 1 }
            try await HcNativeContextMenuAudit.perform("New shell to right",row:"hc-workspace.pane.\(firstPane.id)",content:content,root:root,label:"native-context-split")
            try await wait("one native split binds one new shell",seconds:12) {
                !model.operationBusy && model.selectedTab?.layout?.panes.count == 3
                    && model.selectedTab?.layout?.panes.allSatisfy({ $0.terminal != nil }) == true
            }
            let splitStatus: HcLayoutAuditOwnedStatus = try await connection.call("server.status").result()
            let splitPrograms = try await HcTerminalBoard(connection:connection).list(all:true)
            owned = Array(Set(owned + [splitStatus.pid] + splitStatus.holders.map(\.pid) + splitPrograms.compactMap(\.pid))).sorted()
            try JSONSerialization.data(withJSONObject:["ownedPIDs":owned,"auditPending":true]).write(to:root.appending(path:"audit-owned-identities.json"),options:.atomic)
            let added = splitPrograms.filter { candidate in !afterZoom.contains(where:{ $0.address == candidate.address }) }
            try check(splitPrograms.count == afterZoom.count + 1 && added.count == 1 && added[0].state == "live","one native split starts exactly one owned shell")
            try press("workspace.board.group-by-tab",content:content)
            try await wait("tab mode clears split selection") { terminals(content).isEmpty }
            try clickRow("hc-workspace.tab.\(tabID)",content:content)
            try await wait("actual grouped split shows three native terminals") { terminals(content).count == 3 }
            checks += 1
            let filteredTerminalIDs = terminals(content).map(ObjectIdentifier.init)
            try clickRow("workspace.board.filter",content:content)
            try await wait("actual filter editor ready") { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
            guard let filterEditor = window.firstResponder as? NSTextView else { throw Failure.assertion("filter editor") }
            filterEditor.selectAll(nil)
            filterEditor.insertText("NO_MATCH_OWNED_FIXTURE",replacementRange:NSRange(location:NSNotFound,length:0))
            try await wait("actual no-matches overlay") { elements(content)["workspace.board.no-matches"] != nil }
            try check(terminals(content).map(ObjectIdentifier.init) == filteredTerminalIDs,"filtering rows does not close the selected terminal")
            let passiveFocusAllowed = terminals(content).map { $0.keyboardFocusAllowed() }
            try JSONSerialization.data(withJSONObject:["editorIsFirstResponder":window.firstResponder === filterEditor,
                "passiveFocusAllowed":passiveFocusAllowed,"firstResponder":window.firstResponder.map { String(describing:type(of:$0)) } ?? "nil"])
                .write(to:root.appending(path:"filter-typing-focus.json"),options:.atomic)
            try check(window.firstResponder === filterEditor && passiveFocusAllowed.allSatisfy({ !$0 }),"native editor ownership gates passive terminal focus")
            filterEditor.selectAll(nil)
            filterEditor.insertText("",replacementRange:NSRange(location:NSNotFound,length:0))
            try await wait("clearing filter restores rows") {
                let tree = elements(content)
                let field = tree["workspace.board.filter"]
                let valueSelector = NSSelectorFromString("accessibilityValue")
                let filterValue = field.flatMap { object -> String? in
                    guard object.responds(to:valueSelector) else { return nil }
                    return object.perform(valueSelector)?.takeUnretainedValue() as? String
                }
                let facts: [String:Any] = ["editorIsFirstResponder":window.firstResponder === filterEditor,
                    "editorText":filterEditor.string,"editorDelegate":filterEditor.delegate.map { String(describing:type(of:$0)) } ?? "nil",
                    "firstResponder":window.firstResponder.map { String(describing:type(of:$0)) } ?? "nil",
                    "filterClass":field.map { String(describing:type(of:$0)) } ?? "nil",
                    "filterValue":filterValue ?? "nil",
                    "noMatches":tree["workspace.board.no-matches"] != nil,
                    "tabRow":tree["hc-workspace.tab.\(tabID)"] != nil,
                    "groupedPreference":UserDefaults.standard.bool(forKey:BoardDisplayPreferences.showsTabsKey),
                    "modelTabIDs":(model.document?.workspaces.flatMap(\.tabs).map { $0.id.uuidString }) ?? [],
                    "paneRows":tree.keys.filter { $0.hasPrefix("hc-workspace.pane.") }.count]
                try? JSONSerialization.data(withJSONObject:facts).write(to:root.appending(path:"filter-clear-focus.json"),options:.atomic)
                return tree["workspace.board.no-matches"] == nil && tree["hc-workspace.tab.\(tabID)"] != nil
            }
            checks += 1
            try await wait("actual original pane binding after native topology changes") {
                HcMigrationRenderProbe.shared.boundView(pane:firstPane.id,epoch:model.workspace?.epoch,reference:reference,window:window) != nil
            }
            guard let originalNative = HcMigrationRenderProbe.shared.boundView(pane:firstPane.id,epoch:model.workspace?.epoch,reference:reference,window:window),
                  originalNative.isDescendant(of:content) else { throw Failure.assertion("known original fixture view binding") }
            try JSONSerialization.data(withJSONObject:["pane":firstPane.id.uuidString,"core":reference.coreID,"terminal":reference.terminalID,
                "grid":grid(originalNative),"currentText":renderedFlatText(originalNative),"nativeSessionAuthority":false])
                .write(to:root.appending(path:"original-pane-binding.json"),options:.atomic)
            let dropFile = root.appending(path:"drop fixture's.png")
            guard let escaped = TerminalDropPaste.escaped(dropFile.path) else { throw Failure.assertion("safe owned drop path") }
            let expectedDrop = Data((escaped + " ").utf8)
            try expectedDrop.write(to:root.appending(path:"drop-expected.txt"))
            let rowText = firstPane.id.uuidString
            let expectedRow = Data((rowText + " ").utf8)
            try expectedRow.write(to:root.appending(path:"row-drop-expected.txt"))
            _ = try await connection.call("terminal.keys",parameters:JSONSerialization.data(withJSONObject:["terminal":reference.terminalID,"keys":["f","enter"]]))
            try await wait("owned peer raw drop input ready") { renderedFlatText(originalNative).contains("HC-DROP-READY") }
            guard let drop = originalNative.onDropFiles else { throw Failure.assertion("production file-drop callback") }
            drop([dropFile])
            try await wait("exact owned file-drop bytes") { (try? Data(contentsOf:root.appending(path:"drop-received.bin"))) == expectedDrop }
            checks += 1
            // Component integration on the actual renderer/core, NOT a claim
            // that AppKit's physical list dragging gesture has been exercised.
            try await wait("fresh metadata for row reference") { model.workspace?.canWrite == true }
            guard let provider = HcWorkspaceItemDrag.provider(kind:.pane,id:firstPane.id,model:model,machine:store.activeMachine,store:store,isCurrentModel:{ [weak owner] in owner?.model === $0 }),
                  let rowTarget = originalNative.textDrop else { throw Failure.assertion("production row provider/target") }
            try check(provider.registeredTypeIdentifiers.contains(HcWorkspaceItemDrag.typeIdentifier),"row provider owns a private process marker")
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setData(Data(),forType:NSPasteboard.PasteboardType(HcWorkspaceItemDrag.typeIdentifier))
            pasteboard.setString(rowText,forType:.string)
            try check(!originalNative.performDragOperation(HcAuditRowDrag(pasteboard,source:nil)),"foreign-process marked row refused")
            UserDefaults.standard.set(false,forKey:TerminalFileDropFeature.preferenceKey)
            try await wait("row drop independent of file-drop setting") { originalNative.onDropFiles == nil && originalNative.textDrop != nil }
            let rowDrag = HcAuditRowDrag(pasteboard,source:content)
            try check(originalNative.draggingEntered(rowDrag) == .move && originalNative.performDragOperation(rowDrag),"production destination accepts scoped row component")
            try await wait("exact row reference reaches owned PTY") { (try? Data(contentsOf:root.appending(path:"row-drop-received.bin"))) == expectedRow }
            checks += 1
            UserDefaults.standard.set(true,forKey:TerminalFileDropFeature.preferenceKey)
            let beforeCreate = try await HcTerminalBoard(connection:connection).list(all:true)
            try hcNativeFixtureCommand("t",code:17,label:"native-launcher-create",window:window,root:root)
            try await wait("current-workspace launcher has actual editor") {
                guard let field = launcherField(in:window), let editor = field.currentEditor() else { return false }
                return field.placeholderString == String(localized:"Tab Name") && window.firstResponder === editor
            }
            guard let createEditor = launcherField(in:window)?.currentEditor() as? NSTextView else { throw Failure.assertion("native create editor") }
            createEditor.selectAll(nil); createEditor.insertText("Owned launcher shell",replacementRange:NSRange(location:NSNotFound,length:0))
            try returnKey(in:window) // One Return, not a programmatic launch callback.
            try await wait("native launcher binds one shell and dismisses",seconds:12) {
                launcherField(in:window) == nil && !model.operationBusy && model.selectedTab?.name == "Owned launcher shell"
                    && model.selectedTab?.layout?.panes.first?.terminal != nil
            }
            guard let createdPane = model.selectedTab?.layout?.panes.first, let createdRef = createdPane.terminal else { throw Failure.assertion("native created receipt") }
            let createdStatus: HcLayoutAuditOwnedStatus = try await connection.call("server.status").result()
            let afterCreate = try await HcTerminalBoard(connection:connection).list(all:true)
            owned = Array(Set(owned + [createdStatus.pid] + createdStatus.holders.map(\.pid) + afterCreate.compactMap(\.pid))).sorted()
            try JSONSerialization.data(withJSONObject:["ownedPIDs":owned,"auditPending":true]).write(to:root.appending(path:"audit-owned-identities.json"),options:.atomic)
            try check(afterCreate.count == beforeCreate.count+1 && afterCreate.contains(where:{ $0.address == createdRef.terminalID && $0.state == "live" }),"one native launcher Return starts exactly one Shell")
            try await wait("successful launcher hands keyboard to its actual terminal") {
                let target = HcMigrationRenderProbe.shared.boundView(pane:createdPane.id,epoch:model.workspace?.epoch,reference:createdRef,window:window)
                try? JSONSerialization.data(withJSONObject:["boundView":target != nil,"targetIsFirstResponder":target != nil && window.firstResponder === target,
                    "firstResponder":window.firstResponder.map { String(describing:type(of:$0)) } ?? "nil",
                    "passiveFocusAllowed":target?.keyboardFocusAllowed() ?? false,"active":NSApp.isActive,"key":window.isKeyWindow])
                    .write(to:root.appending(path:"native-launcher-handoff.json"),options:.atomic)
                return target != nil && window.firstResponder === target && window.isKeyWindow
            }
            checks += 1
            try await wait("live created shell enables explicit end choice") {
                model.terminals.contains { $0.address == createdRef.terminalID && $0.state == "live" }
            }
            let beforeExplicitEnd = try await HcTerminalBoard(connection:connection).list(all:true)
            try hcNativeFixtureCommand("w",code:13,label:"native-created-program-end",window:window,root:root)
            try await hcFixtureWait("hc.close.end-programs.confirm",present:true,enabled:true,window:window)
            try hcFixturePress("hc.close.end-programs.confirm") // Explicit separate action; default close never kills.
            try await wait("native explicit end closes its view and records completion",seconds:12) {
                !model.operationBusy && model.document?.panes.contains(where:{ $0.id == createdPane.id }) == false
                    && model.recoveryRecords.last?.complete == true && window.isKeyWindow
            }
            let afterExplicitEnd = try await HcTerminalBoard(connection:connection).list(all:true)
            let endedShell = try await HcTerminalBoard(connection:connection).get(createdRef.terminalID)
            var othersPreserved = afterExplicitEnd.count == beforeExplicitEnd.count
            for old in beforeExplicitEnd where old.address != createdRef.terminalID {
                guard let current = afterExplicitEnd.first(where:{ $0.address == old.address }) else { othersPreserved = false; break }
                if old.pid != current.pid || old.createdMs != current.createdMs || old.state != current.state { othersPreserved = false }
            }
            try check(endedShell.state == "finished" && othersPreserved,"native explicit end stops only the consented owned shell")
            try check(model.recoveryRecords.last?.targets.first?.state == .confirmed && terminals(content).isEmpty,
                      "native stop confirmation is durable and selected view stays clear")
            let record = try await HcTerminalBoard(connection:connection).get(reference.terminalID)
            try check(record.pid == originalRecord.pid && record.createdMs == originalRecord.createdMs && record.state == "live",
                      "sidebar does not replace or end actual hc program")
            // End only the app's owned connect client; the independent control
            // channel and core/programs stay live. Never retry the failed client.
            guard transports.transports.count == 1, let screenTransport = transports.transports.first else { throw Failure.assertion("one initial owned connect") }
            let beforeRetry = try await HcTerminalBoard(connection:connection).list(all:true)
            let documentBeforeRetry = model.document
            try await screenTransport.close()
            try await wait("actual disconnected-board retry banner",seconds:10) {
                model.state == .failed && elements(content)["workspace.board.connection-failure"] != nil
            }
            checks += 1
            let afterFailure = try await HcTerminalBoard(connection:connection).get(reference.terminalID)
            try check(afterFailure.pid == originalRecord.pid && afterFailure.createdMs == originalRecord.createdMs && afterFailure.state == "live",
                      "connect failure presents retry without terminating the program")
            try await wait("actual enabled Retry ready") {
                let tree = elements(content)
                let facts = tree.map { key, value in
                    ["id":key,"class":String(describing:type(of:value)),"enabled":(value as AnyObject).isAccessibilityEnabled?() ?? false] as [String:Any]
                }
                try? JSONSerialization.data(withJSONObject:facts).write(to:root.appending(path:"retry-controls.json"),options:.atomic)
                guard let retry = tree["workspace.board.retry"] else { return false }
                return (retry as AnyObject).isAccessibilityEnabled?() == true
            }
            try press("workspace.board.retry", content:content)
            try await wait("native Retry establishes a fresh connected model",seconds:12) {
                owner.model !== model && owner.model?.state == .connected && owner.phase == .connected
                    && elements(content)["workspace.board.connection-failure"] == nil
            }
            try check(transports.transports.count == 2 && owner.model?.document == documentBeforeRetry,
                      "one explicit retry preserves exact workspace metadata")
            let retried = try await HcTerminalBoard(connection:connection).list(all:true)
            var programsUnchanged = retried.count == beforeRetry.count
            for old in beforeRetry {
                guard let current = retried.first(where: { $0.address == old.address }) else { programsUnchanged = false; break }
                if current.pid != old.pid || current.createdMs != old.createdMs || current.state != old.state { programsUnchanged = false }
            }
            try check(programsUnchanged, "explicit retry neither replays a launch nor terminates a program")
            try check(rowTarget.text(rowText) == nil,"retired source epoch cannot supply row text after reconnect")
            let retiredConnect = await screenTransport.snapshot()
            try check(retiredConnect.closed && retiredConnect.reaped,
                      "previous connect child reaped before retry completes")
            guard await restore() else { throw Failure.assertion("owned fullscreen/pointer cleanup") }
            let result: [String:Any] = ["passed":true,"checks":checks,"actualHcRoot":true,"actualCore":true,
                "fullscreenSpaceAndEdgeReveal":fullscreen && !nativeFullscreenLayout,"fullscreenNativeLayout":fullscreen && nativeFullscreenLayout,
                "fullscreenExitRestored":restoreSucceeded,"nativeRevealOnly":!fullscreen || nativeFullscreenLayout,"physicalDividerDrag":"NOTRUN",
                "globalEventInjection":false,"borrowedPermissions":false,"releaseCutover":false,"ownedPIDs":owned,"edgeStimulus":edgeStimulus,
                "rowDragComponentIntegration":true,"physicalRowDragQualified":false]
            try JSONSerialization.data(withJSONObject:result).write(to:root.appending(path:"layout-audit.json"),options:.atomic)
            return result
        } catch {
            let failedPointer = NSEvent.mouseLocation
            try? JSONSerialization.data(withJSONObject:lastPress).write(to:root.appending(path:"native-last-press.json"),options:.atomic)
            let cleanup = await restore()
            try? JSONSerialization.data(withJSONObject:["passed":false,"checks":checks,"error":String(describing:error),"fullscreenRequested":fullscreen,"fullscreenNativeLayoutRequested":nativeFullscreenLayout,"fullscreenExitRestored":cleanup,
                "edgeStimulus":edgeStimulus,"pointerAtFailure":[failedPointer.x,failedPointer.y],
                "pointerAfterCleanup":[NSEvent.mouseLocation.x,NSEvent.mouseLocation.y]])
                .write(to:root.appending(path:"layout-audit.json"),options:.atomic)
            throw error
        }
    }
}
#endif
