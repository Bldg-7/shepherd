#if DEBUG && os(macOS)
import SwiftUI
import AppKit
import SwiftTerm
import Darwin

/// Explicit private integration route while release UI parity is incomplete.
/// Never a user preference/backend fallback; release builds cannot select it.
/// The default app remains unchanged until installation/remote/file parity gates.
struct HcMigrationConfiguration {
    let root: URL
    let binary: URL
    static var requested: Bool { ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_ROOT"] != nil }
    static var current: Self? {
        guard requested else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let root = env["SHEPHERD_HC_UI_ROOT"], root.hasPrefix("/private/tmp/hc-screen-app."),
              let binary = env["SHEPHERD_HC_UI_BINARY"], binary.hasPrefix(root + "/"),
              env["HOME"] == root + "/home" else { preconditionFailure("Explicit private hc UI fixture root/binary/HOME required") }
        return Self(root: URL(fileURLWithPath: root), binary: URL(fileURLWithPath: binary))
    }
    func machineStore() -> MachineStore {
        let defaults = UserDefaults(suiteName: "com.bldg-7.shepherd.hc-ui." + UUID().uuidString)!
        return MachineStore(defaults: defaults, localMachine: MachineStore.localMachine)
    }
}

@MainActor @Observable final class HcMigrationRenderProbe {
    static let shared = HcMigrationRenderProbe()
    private(set) var text = ""
    private(set) var bytes = 0
    func consumed(_ data: Data, rendered: String) {
        guard HcMigrationConfiguration.requested else { return }
        bytes += data.count
        text = String(rendered.suffix(16000))
    }
}

private nonisolated struct HcMigrationStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}

@MainActor private func hcAccessibility(_ view: NSView) -> [String: NSObject] {
    var found: [String: NSObject] = [:]
    var visited = Set<ObjectIdentifier>()
    func walk(_ node: AnyObject, _ depth: Int) {
        guard depth < 60, visited.insert(ObjectIdentifier(node)).inserted else { return }
        if let element = node as? NSAccessibilityElementProtocol, let id = element.accessibilityIdentifier?(), !id.isEmpty,
           let object = node as? NSObject { found[id] = object }
        for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
        if let view = node as? NSView { for child in view.subviews { walk(child, depth + 1) } }
    }
    walk(view, 0)
    return found
}

@MainActor private func hcTerminal(in view: NSView) -> FocusReportingTerminalView? {
    if let terminal = view as? FocusReportingTerminalView { return terminal }
    for child in view.subviews { if let result = hcTerminal(in: child) { return result } }
    return nil
}
@MainActor private func hcAccessibilityText(_ root: NSView) -> String {
    var visited = Set<ObjectIdentifier>(), text: [String] = []
    func walk(_ node: AnyObject, _ depth: Int) {
        guard depth < 60, visited.count < 16000, visited.insert(ObjectIdentifier(node)).inserted else { return }
        if let object = node as? NSObject {
            for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() {
                    if let value = value as? String { text.append(String(value.prefix(16000))) }
                    else if let value = value as? NSAttributedString { text.append(String(value.string.prefix(16000))) }
                }
            }
        }
        for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
        if let view = node as? NSView { for child in view.subviews { walk(child, depth + 1) } }
    }
    walk(root, 0); return text.joined(separator: "\n")
}

@MainActor private func hcNewTabItem(in menu: NSMenu) -> NSMenuItem? { hcCommandItem(in: menu, key: "n") }
@MainActor private func hcCommandItem(in menu: NSMenu, key: String) -> NSMenuItem? {
    menu.update()
    for item in menu.items {
        if item.keyEquivalent == key, item.keyEquivalentModifierMask.intersection([.command,.option,.shift,.control]) == .command { return item }
        if let child = item.submenu, let found = hcCommandItem(in: child, key: key) { return found }
    }
    return nil
}
@MainActor private func hcMenuDiagnostics(_ menu: NSMenu) -> [[String: Any]] {
    menu.items.map { item in
        var value: [String: Any] = ["title":item.title,"key":item.keyEquivalent,"enabled":item.isEnabled,"hidden":item.isHidden,
            "modifiers":item.keyEquivalentModifierMask.rawValue,"action":item.action.map(NSStringFromSelector) ?? "nil",
            "target":item.target.map { String(describing:type(of:$0)) } ?? "nil"]
        if let child = item.submenu { value["children"] = hcMenuDiagnostics(child) }
        return value
    }
}
@MainActor private final class HcVisibleMenuProbe: NSObject {
    let menu: NSMenu
    let key: String
    var inspected = false
    var enabled = false
    var snapshot: [[String: Any]] = []
    init(menu: NSMenu, key: String = "n") { self.menu = menu; self.key = key }
    @objc func finish(_ timer: Timer) {
        inspected = true
        enabled = hcCommandItem(in: menu, key: key)?.isEnabled == true
        snapshot = hcMenuDiagnostics(menu)
        menu.cancelTrackingWithoutAnimation()
    }
}
@MainActor private func hcNativeFixtureCommand(_ key: String, code: UInt16, label: String, window: NSWindow, root: URL) throws {
    guard NSApp.isActive, window.isKeyWindow, let menu = NSApp.mainMenu, let item = hcCommandItem(in: menu, key: key),
          let parent = item.menu, let view = window.contentView else { throw HcWorkspaceModel.Failure.unavailable }
    let probe = HcVisibleMenuProbe(menu: parent, key: key)
    let timer = Timer(timeInterval: 0.2, target: probe, selector: #selector(HcVisibleMenuProbe.finish(_:)), userInfo: nil, repeats: false)
    RunLoop.main.add(timer, forMode: .eventTracking); RunLoop.main.add(timer, forMode: .common)
    _ = parent.popUp(positioning: nil, at: NSPoint(x: 10, y: max(10, view.bounds.height - 20)), in: view)
    timer.invalidate()
    guard probe.inspected, probe.enabled, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { throw HcWorkspaceModel.Failure.unavailable }
    let handled = menu.performKeyEquivalent(with: event)
    try JSONSerialization.data(withJSONObject: ["enabledWhileOpen":probe.enabled,"handled":handled,"menu":probe.snapshot]).write(to: root.appending(path: label + ".json"), options: .atomic)
    guard handled else { throw HcWorkspaceModel.Failure.unavailable }
}
@MainActor private func hcFixtureWait(_ id: String, present: Bool, enabled: Bool = false, window: NSWindow) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while (hcFixtureElement(id) != nil) != present
            || (present && enabled && (hcFixtureElement(id) as AnyObject?)?.isAccessibilityEnabled?() != true)
            || (!present && !window.isKeyWindow) {
        guard ContinuousClock.now < end else { throw HcWorkspaceModel.Failure.unavailable }
        try await Task.sleep(for: .milliseconds(20))
    }
}
@MainActor private func hcFixturePress(_ id: String) throws {
    let control = hcFixtureElement(id)
    let enabled = (control as AnyObject?)?.isAccessibilityEnabled?() == true
    let supported = control?.responds(to: NSSelectorFromString("accessibilityPerformPress")) ?? false
    let handled = enabled && supported ? ((control as AnyObject?)?.accessibilityPerformPress?() ?? false) : false
    if let root = HcMigrationConfiguration.current?.root {
        try JSONSerialization.data(withJSONObject: ["identifier":id,"found":control != nil,"class":control.map { String(describing:type(of:$0)) } ?? "nil",
            "supportsPress":supported,"enabled":enabled,"handled":handled]).write(to: root.appending(path: "last-accessibility-press.json"), options: .atomic)
    }
    guard handled else { throw HcWorkspaceModel.Failure.unavailable }
}
@MainActor private func hcFixtureElement(_ identifier: String) -> NSObject? {
    for window in NSApp.windows { if let content = window.contentView, let element = hcAccessibility(content)[identifier] { return element } }
    return nil
}

@MainActor private func hcNetworkIsDenied() -> Bool {
    guard let text = ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_CANARY_PORT"], let port = UInt16(text) else { return false }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return result < 0 && [EPERM,EACCES].contains(errno)
}

struct HcMigrationHost: View {
    let configuration: HcMigrationConfiguration
    @State private var owner: HcMachineConnection?
    @State private var fixtureStore: MachineStore?
    @State private var fixtureTransport: CoreProcessTransport?
    @State private var failure = false
    var body: some View {
        Group {
            if let owner, let fixtureStore { HcRootView(machineStore: fixtureStore, connection: owner, localTransport: fixtureTransport) }
            else if failure { Text("Private hc integration failed") }
            else { ProgressView("Preparing private hc integration…") }
        }
        .task { await open() }
    }
    private func open() async {
        guard owner == nil else { return }
        let root = configuration.root, report = root.appending(path: "ui-report.json")
        var connection: CoreRPCConnection?, transport: CoreProcessTransport?, workspace: HcWorkspaceModel?
        var owned: [UInt32] = []
        var checks = 0
        do {
            try JSONSerialization.data(withJSONObject: ["appPID":ProcessInfo.processInfo.processIdentifier]).write(to: root.appending(path: "app-identity.json"), options: .atomic)
            guard hcNetworkIsDenied() else { throw HcWorkspaceModel.Failure.unavailable }
            let scope = try HcCoreBootstrap.Scope(root: root.appending(path: "core"))
            let (t, c, _) = try await HcCoreBootstrap.connect(binary: configuration.binary, scope: scope)
            connection = c; transport = t
            let status: HcMigrationStatus = try await c.call("server.status").result()
            owned = [status.pid]
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            UserDefaults.standard.set(true, forKey: TerminalFileDropFeature.preferenceKey) // Only this explicitly isolated HOME.
            let storage = root.appending(path: "workspace-store", directoryHint: .isDirectory)
            let owner = HcMachineConnection(directory: storage)
            let screenTransport = try CoreProcessTransport(configuration: .init(executable: configuration.binary,
                environment: HcCoreBootstrap.environment(for: scope), directory: scope.root))
            fixtureTransport = screenTransport; fixtureStore = configuration.machineStore(); self.owner = owner
            // Let the real product root's .task call the production machine
            // factory and open its model, rather than constructing a model here.
            let openingDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while owner.model == nil {
                guard owner.phase != .failed, ContinuousClock.now < openingDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            let m = owner.model!; workspace = m; checks += 1
            let id = try await m.createWorkspace(name: "Owned UI fixture"); checks += 1
            let peer = root.appending(path: "ui-peer.py").path
            try await m.launchTab(workspaceID: id, name: "Real hc terminal", argv: ["/usr/bin/python3","-I","-S","-B",peer]); checks += 1
            let running: HcMigrationStatus = try await c.call("server.status").result()
            let records = try await HcTerminalBoard(connection: c).list(all: true)
            owned += running.holders.map(\.pid) + records.compactMap(\.pid)
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while !HcMigrationRenderProbe.shared.text.contains("HC-UI-RENDER-DONE") {
                guard ContinuousClock.now < deadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks += 1
            let persisted = FileManager.default.enumerator(at: storage, includingPropertiesForKeys: nil)?.allObjects.compactMap { ($0 as? URL)?.lastPathComponent } ?? []
            guard m.selectedTab != nil, m.focus.paneByTab[m.selectedTab!.id] != nil,
                  persisted.contains("recovery.json"), persisted.contains("focus.json") else { throw HcWorkspaceModel.Failure.unavailable }
            checks += 1
            guard let content = NSApp.windows.first(where: { $0.contentView?.bounds.width ?? 0 > 500 })?.contentView else { throw HcWorkspaceModel.Failure.unavailable }
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
            guard let selectedTab = m.selectedTab else { throw HcWorkspaceModel.Failure.unavailable }
            let axDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            var ax = hcAccessibility(content)
            while ax["hc-workspace.create-workspace"] == nil || ax["hc-workspace.tab.\(selectedTab.id)"] == nil {
                try JSONSerialization.data(withJSONObject: ax.keys.sorted()).write(to: root.appending(path: "accessibility.json"))
                guard ContinuousClock.now < axDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
                ax = hcAccessibility(content)
            }
            try JSONSerialization.data(withJSONObject: ax.keys.sorted()).write(to: root.appending(path: "accessibility.json"))
            checks += 1
            guard let native = hcTerminal(in: content), let target = m.selectedTab?.layout?.panes.first?.terminal?.terminalID else { throw HcWorkspaceModel.Failure.unavailable }
            let dropped = root.appending(path: "drop fixture's.png")
            guard let escaped = TerminalDropPaste.escaped(dropped.path) else { throw HcWorkspaceModel.Failure.unavailable }
            let paste = Data((escaped + " ").utf8)
            try paste.write(to: root.appending(path: "drop-expected.txt"))
            _ = try await c.call("terminal.keys", parameters: JSONSerialization.data(withJSONObject: ["terminal":target,"keys":["f","enter"]]))
            let liveDeadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !HcMigrationRenderProbe.shared.text.contains("HC-DROP-READY") {
                guard ContinuousClock.now < liveDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            let screen = native.getTerminal(), link = root.appending(path: "owned-preview.md").absoluteString
            guard let row = (0..<screen.rows).first(where: { screen.getLine(row: $0)?.translateToString(trimRight: true).contains("Open owned preview") == true }),
                  screen.link(at: .screen(Position(col: 0, row: row)), mode: .explicitOnly) == link else { throw HcWorkspaceModel.Failure.unavailable }
            checks += 1
            guard let drop = native.onDropFiles else { throw HcWorkspaceModel.Failure.unavailable }
            drop([dropped])
            let received = root.appending(path: "drop-received.bin"), dropDeadline = ContinuousClock.now.advanced(by: .seconds(6))
            // The received bytes can exceed one physical terminal row. Verify
            // exact bytes at the owned peer, plus its short rendered marker;
            // never confuse a soft-wrapped line with dropped/changed input.
            while !HcMigrationRenderProbe.shared.text.contains("HC-DROP-RECEIVED") || (try? Data(contentsOf: received)) != paste {
                guard ContinuousClock.now < dropDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks += 1
            guard let open = native.onOpenFileGesture else { throw HcWorkspaceModel.Failure.unavailable }
            open(link, .unknown)
            let previewDeadline = ContinuousClock.now.advanced(by: .seconds(6))
            while !hcAccessibilityText(content).contains("HC-FILE-PREVIEW-CONTENT") {
                guard ContinuousClock.now < previewDeadline else {
                    try Data(hcAccessibilityText(content).utf8).write(to: root.appending(path: "preview-accessibility.txt"))
                    throw HcWorkspaceModel.Failure.unavailable
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks += 1
            guard let rootWindow = content.window else { throw HcWorkspaceModel.Failure.unavailable }
            // Direct executable fixtures do not receive LaunchServices' app
            // activation policy. Set the policy of THIS owned process only.
            let previousPolicy = NSApp.activationPolicy().rawValue
            let policyAccepted = NSApp.setActivationPolicy(.regular)
            rootWindow.makeKeyAndOrderFront(nil)
            let beforeFocus = HcWindowCommandState.shared.actions
            try JSONSerialization.data(withJSONObject: ["modelCanEdit":m.canEdit,"ownerPresent":beforeFocus != nil,
                "ownerCanLaunch":beforeFocus?.canLaunch ?? false,"ownerCanSettings":beforeFocus?.canSettings ?? false]).write(to: root.appending(path: "command-owner-before-focus.json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: ["appPID":ProcessInfo.processInfo.processIdentifier,"renderedAndPreviewed":true]).write(to: root.appending(path: "ui-wants-focus.json"), options: .atomic)
            let humanActivation = ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_HUMAN_ACTIVATION"] == "1"
            let yieldDeadline = ContinuousClock.now.advanced(by: .seconds(humanActivation ? 150 : 4))
            while !FileManager.default.fileExists(atPath: root.appending(path: "activation-yielded.json").path)
                    && !(NSApp.isActive && rootWindow.isKeyWindow) {
                try JSONSerialization.data(withJSONObject: ["isActive":NSApp.isActive,"isKey":rootWindow.isKeyWindow,"humanActivationRequested":humanActivation]).write(to: root.appending(path: "focus-wait.json"), options: .atomic)
                guard ContinuousClock.now < yieldDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let text = ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_PARENT_PID"], let pid = Int32(text),
                  let parent = NSRunningApplication(processIdentifier: pid), HcFixtureBundlePath.matches(parent.bundleURL, expected: root.appending(path: "OwnedUILauncher.app")) else { throw HcWorkspaceModel.Failure.unavailable }
            // Direct user activation of our own child already meets readiness.
            // Only our owned helper can otherwise yield activation to this app.
            let alreadyActive = NSApp.isActive
            let activationAccepted = !alreadyActive && NSRunningApplication.current.activate(from: parent, options: [.activateAllWindows])
            try JSONSerialization.data(withJSONObject: ["previousPolicy":previousPolicy,"policyAccepted":policyAccepted,"activationAlreadyPresent":alreadyActive,"activationAccepted":activationAccepted,"isActive":NSApp.isActive,"isKey":rootWindow.isKeyWindow]).write(to: root.appending(path: "focus-stage.json"))
            let focusDeadline = ContinuousClock.now.advanced(by: .seconds(humanActivation ? 8 : 4))
            while !rootWindow.isKeyWindow || !NSApp.isActive {
                guard ContinuousClock.now < focusDeadline else {
                    try JSONSerialization.data(withJSONObject: ["isActive":NSApp.isActive,"isKey":rootWindow.isKeyWindow,"policy":NSApp.activationPolicy().rawValue]).write(to: root.appending(path: "focus-failure.json"))
                    throw HcWorkspaceModel.Failure.unavailable
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let menu = NSApp.mainMenu else { throw HcWorkspaceModel.Failure.unavailable }
            let menuDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            var item: NSMenuItem?
            repeat {
                item = hcNewTabItem(in: menu)
                let actions = HcWindowCommandState.shared.actions
                try JSONSerialization.data(withJSONObject: ["isActive":NSApp.isActive,"isKey":rootWindow.isKeyWindow,
                    "canEdit":m.canEdit,"ownerPresent":actions != nil,"ownerCanLaunch":actions?.canLaunch ?? false,
                    "ownerCanSettings":actions?.canSettings ?? false,"menuFound":item != nil,"title":item?.title ?? "nil",
                    "enabled":item?.isEnabled ?? false,"menu":hcMenuDiagnostics(menu)]).write(to: root.appending(path: "command-stage.json"), options: .atomic)
                if item?.isEnabled == true { break }
                if ContinuousClock.now >= menuDeadline { break }
                try await Task.sleep(for: .milliseconds(20))
            } while true
            guard NSApp.isActive, rootWindow.isKeyWindow, let item, let fileMenu = item.menu,
                  let menuView = rootWindow.contentView else { throw HcWorkspaceModel.Failure.unavailable }
            // Open the real native menu so SwiftUI's lazy menu delegate has the
            // same opportunity to populate/validate it as a person's menu click.
            let visible = HcVisibleMenuProbe(menu: fileMenu)
            let timer = Timer(timeInterval: 0.2, target: visible, selector: #selector(HcVisibleMenuProbe.finish(_:)), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
            _ = fileMenu.popUp(positioning: nil, at: NSPoint(x: 10, y: max(10, menuView.bounds.height - 20)), in: menuView)
            timer.invalidate()
            try JSONSerialization.data(withJSONObject: ["inspectedWhileOpen":visible.inspected,"enabledWhileOpen":visible.enabled,
                "menu":visible.snapshot]).write(to: root.appending(path: "visible-menu-probe.json"), options: .atomic)
            guard visible.inspected, visible.enabled, NSApp.isActive, rootWindow.isKeyWindow,
                  let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rootWindow.windowNumber, context: nil,
                    characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45) else { throw HcWorkspaceModel.Failure.unavailable }
            // AppKit supports delegate-resolved key equivalents without first
            // populating the visible menu (NSMenuDelegate.menuHasKeyEquivalent).
            // Exercise the real native path once, not a forced enabled flag or
            // direct Swift closure. The actual hc form/cancel must still pass.
            let handled = menu.performKeyEquivalent(with: key)
            try JSONSerialization.data(withJSONObject: ["handled":handled,"cachedEnabled":item.isEnabled,
                "isActive":NSApp.isActive,"isKey":rootWindow.isKeyWindow,"menu":hcMenuDiagnostics(menu)]).write(to: root.appending(path: "native-key-equivalent.json"), options: .atomic)
            guard handled else { throw HcWorkspaceModel.Failure.unavailable }
            let launchDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            while hcFixtureElement("hc.launch.cancel") == nil || hcFixtureElement("hc.launch.program") == nil {
                guard ContinuousClock.now < launchDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let cancel = hcFixtureElement("hc.launch.cancel"), cancel.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { throw HcWorkspaceModel.Failure.unavailable }
            _ = cancel.perform(NSSelectorFromString("accessibilityPerformPress"))
            let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            while hcFixtureElement("hc.launch.cancel") != nil {
                guard ContinuousClock.now < cancelDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            let afterMenu = try await HcTerminalBoard(connection: c).list(all: true)
            guard afterMenu.count == records.count else { throw HcWorkspaceModel.Failure.unavailable }
            checks += 1
            try hcNativeFixtureCommand("p", code: 35, label: "native-switcher", window: rootWindow, root: root)
            try await hcFixtureWait("hc.switcher.done", present: true, window: rootWindow)
            guard hcFixtureElement("hc.switcher.search") != nil else { throw HcWorkspaceModel.Failure.unavailable }
            try hcFixturePress("hc.switcher.done")
            try await hcFixtureWait("hc.switcher.done", present: false, window: rootWindow); checks += 1
            try hcNativeFixtureCommand(",", code: 43, label: "native-settings", window: rootWindow, root: root)
            try await hcFixtureWait("hc.settings.done", present: true, window: rootWindow)
            try hcFixturePress("hc.settings.done")
            try await hcFixtureWait("hc.settings.done", present: false, window: rootWindow); checks += 1
            try hcFixturePress("hc.origins.open")
            try await hcFixtureWait("hc.origins.list", present: true, window: rootWindow)
            guard let origin = m.coreID else { throw HcWorkspaceModel.Failure.unavailable }
            let directoryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                let text = NSApp.windows.compactMap(\.contentView).map(hcAccessibilityText).joined(separator: "\n")
                try Data(text.utf8).write(to: root.appending(path: "directory-accessibility-text.txt"), options: .atomic)
                if text.contains(origin) { break }
                guard ContinuousClock.now < directoryDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            try hcFixturePress("hc.origins.done")
            try await hcFixtureWait("hc.origins.done", present: false, window: rootWindow)
            try JSONSerialization.data(withJSONObject: ["verified":true,"hubID":origin,"readOnly":true]).write(to: root.appending(path: "native-origin-directory.json"), options: .atomic)
            checks += 1
            // NSView bitmap capture proves native terminal output, but may not
            // composite SwiftUI layer-backed/sidebar content. AX above checks
            // those real controls separately, without global accessibility access.
            // Screenshot of the actual SwiftUI sidebar and SwiftTerm pane,
            // rendered in this private app instance, not the user's window.
            if let window = NSApp.windows.first(where: { $0.contentView?.bounds.width ?? 0 > 500 }), let view = window.contentView,
               let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                if let png = image.representation(using: .png, properties: [:]) { try png.write(to: root.appending(path: "workspace.png")); checks += 1 }
            }
            // Show the exact already-owned terminal in a second view. Native
            // Close must remove that view, not end or rerun the program.
            let originalTab = m.selectedTab?.id
            try await m.showTerminal(target, workspaceID: id)
            guard let duplicate = m.selectedTab, duplicate.id != originalTab else { throw HcWorkspaceModel.Failure.unavailable }
            let closeReady = ContinuousClock.now.advanced(by: .seconds(5))
            while HcWindowCommandState.shared.actions?.canClose != true {
                guard ContinuousClock.now < closeReady else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            try hcNativeFixtureCommand("w", code: 13, label: "native-close-view", window: rootWindow, root: root)
            let closeEnd = ContinuousClock.now.advanced(by: .seconds(5))
            while m.document?.workspaces.flatMap(\.tabs).contains(where: { $0.id == duplicate.id }) == true {
                guard ContinuousClock.now < closeEnd else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            let afterClose = try await HcTerminalBoard(connection: c).list(all: true)
            guard afterClose.count == records.count, afterClose.first(where: { $0.address == target })?.state == "live" else { throw HcWorkspaceModel.Failure.unavailable }
            checks += 1
            guard let historyRecord = m.recoveryRecords.first(where: { $0.kind == .launch && $0.complete }) else { throw HcWorkspaceModel.Failure.unavailable }
            let reviewID = "hc.review.open.\(historyRecord.id)", historyCount = m.recoveryRecords.count
            try hcFixturePress("hc.review.history")
            try await hcFixtureWait(reviewID, present: true, enabled: true, window: rootWindow)
            try hcFixturePress(reviewID)
            try await hcFixtureWait("hc.review.cancel", present: true, enabled: true, window: rootWindow)
            guard m.operationReview?.record.id == historyRecord.id, m.operationReview?.canApplyLayout == false,
                  !m.canEdit, HcWindowCommandState.shared.actions?.canLaunch == false else { throw HcWorkspaceModel.Failure.unavailable }
            try hcFixturePress("hc.review.cancel")
            try await hcFixtureWait("hc.review.cancel", present: false, window: rootWindow)
            guard m.operationReview == nil, m.recoveryRecords.count == historyCount else { throw HcWorkspaceModel.Failure.unavailable }
            try JSONSerialization.data(withJSONObject: ["verified":true,"trackingCountUnchanged":true]).write(to: root.appending(path: "native-recovery-cancel.json"), options: .atomic)
            checks += 1
            try await hcFixtureWait(reviewID, present: true, enabled: true, window: rootWindow)
            try hcFixturePress(reviewID)
            try await hcFixtureWait("hc.review.forget", present: true, enabled: true, window: rootWindow)
            try hcFixturePress("hc.review.forget")
            try await hcFixtureWait("hc.review.forget.confirm", present: true, enabled: true, window: rootWindow)
            try hcFixturePress("hc.review.forget.confirm")
            try await hcFixtureWait("hc.review.cancel", present: false, window: rootWindow)
            let afterForget = try await HcTerminalBoard(connection: c).list(all: true)
            guard m.recoveryRecords.count == historyCount - 1, !m.recoveryRecords.contains(where: { $0.id == historyRecord.id }),
                  afterForget.count == records.count, afterForget.first(where: { $0.address == target })?.state == "live" else { throw HcWorkspaceModel.Failure.unavailable }
            checks += 1
            // Only this fixture's explicitly isolated core may be stopped.
            _ = try await c.call("server.stop")
            await owner.close()
            try await c.close()
            let snapshot = await t.snapshot(), screenSnapshot = await screenTransport.snapshot()
            guard owner.phase == .idle, snapshot.reaped, screenSnapshot.reaped else { throw HcWorkspaceModel.Failure.unavailable }; checks += 1
            try JSONSerialization.data(withJSONObject: ["passed":true,"checks":checks,"ownedPIDs":owned,
                "windowCommandsVerified":true,"paneSwitcherVerified":true,"originDirectoryVerified":true,"recoveryReviewVerified":true,"forgetTrackingKeepsProgram":true,"settingsVerified":true,"closeViewKeepsProgram":true,"filePreviewVerified":true,"fileDropVerified":true,"productFactoryVerified":true,"renderedBytes":HcMigrationRenderProbe.shared.bytes,"sidebarAccessibilityVerified":true,"screenshot":FileManager.default.fileExists(atPath: root.appending(path:"workspace.png").path),
                "browserAuthorityUsed":false,"productCutover":false]).write(to: report, options: .atomic)
            NSApp.terminate(nil)
        } catch {
            failure = true
            try? Data(HcMigrationRenderProbe.shared.text.utf8).write(to: root.appending(path: "failed-screen.txt"))
            var ids = Set<String>()
            for window in NSApp.windows { if let content = window.contentView { ids.formUnion(hcAccessibility(content).keys) } }
            try? JSONSerialization.data(withJSONObject: ["identifiers":ids.sorted(),"operationReviewActive":workspace?.operationReview != nil,
                "modelState":workspace.map { String(describing:$0.state) } ?? "none", "operationBusy":workspace?.operationBusy ?? false,
                "modelCanEdit":workspace?.canEdit ?? false,"errorType":String(describing:type(of:error))]).write(to: root.appending(path: "failed-ui-stage.json"), options: .atomic)
            if let connection { _ = try? await connection.call("server.stop") }
            await owner?.close()
            try? await workspace?.disconnect(); try? await connection?.close()
            let reaped = await transport?.snapshot().reaped ?? false
            try? JSONSerialization.data(withJSONObject: ["passed":false,"checks":checks,"ownedPIDs":owned,"reaped":reaped]).write(to: report, options: .atomic)
            exit(1)
        }
    }
}
#endif
