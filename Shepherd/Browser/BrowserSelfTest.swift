#if os(macOS) && DEBUG
import AppKit
import SwiftUI

/// A development build's check of the browser, run in place of nothing
/// else when the app is started with `SHEPHERD_BROWSER_SELFTEST` set to a
/// file path: it opens browsers for made-up panes — herdr isn't involved —
/// in windows of its own, goes through the plan items of phase 1 in
/// docs/agent-browser-plan.md, and writes what it finds to that file, one
/// "item: result" per line. It needs the internet (example.com and
/// example.org). The app quits when it is done, by way of the same path as
/// any quit (F8).
@MainActor
enum BrowserSelfTest {
    private static var lines: [String] = []
    private static var resultsPath = ""

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SHEPHERD_BROWSER_SELFTEST"] else { return }
        resultsPath = path
        // The made-up Machine isn't one of the app's, and its browsers would
        // otherwise go as soon as the window lists the Machines there are.
        BrowserStore.shared.machineIgnoredByReconcile = machine.id
        let restoring = environment["SHEPHERD_BROWSER_SELFTEST_RESTORE"] == "1"
        Task {
            if restoring {
                await runRestore()
            } else {
                await run()
            }
            record("done", true)
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.01)
        }
    }

    /// The second run, after the first quit: what it left behind came back,
    /// sign-ins included, and then goes.
    private static func runRestore() async {
        let store = BrowserStore.shared
        let paneA = pane("selftest:p1", terminal: "selftest-term-1")
        let paneC = pane("selftest:p3", terminal: "selftest-term-3")
        let browserA = store.browsers[key(paneA)]
        check("F11 restored at launch", browserA != nil && browserA?.isSuspended == true && browserA?.tabs.isEmpty == false,
              browserA.map { "\($0.tabs.map(\.url))" } ?? "none")
        let (window, region) = window("Self test restore", x: 80)
        store.show(key(paneC), in: region, terminalID: paneC.terminalID)
        if let tab = store.browser(for: key(paneC))?.selectedTab, await loaded(tab, containing: "example.com") {
            let cookie = await evaluate(tab, "document.cookie") as? String
            check("F11 isolated profile kept its cookies", cookie?.contains("persist=1") == true, cookie ?? "nil")
        } else {
            check("F11 isolated profile kept its cookies", false, "pane C's browser didn't come back")
        }
        let folder = store.browsers[key(paneC)]?.profile.isolatedFolder.map(store.profileFolder(named:))
        store.remove(region)
        window.close()
        store.reconcile(machineID: machine.id, herdrMachineID: nil, panes: [])
        check("cleanup: browsers closed", store.browsers.keys.allSatisfy { $0.machineID != machine.id })
        try? await Task.sleep(for: .seconds(4))
        check("cleanup: profile folder deleted", folder.map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false,
              folder?.lastPathComponent ?? "no folder")
    }

    private static func record(_ item: String, _ value: Any) {
        lines.append("\(item): \(value)")
        try? lines.joined(separator: "\n").write(toFile: resultsPath, atomically: true, encoding: .utf8)
    }

    private static func check(_ item: String, _ passed: Bool, _ detail: Any = "") {
        record(item, passed ? "PASS \(detail)" : "FAIL \(detail)")
    }

    // MARK: Helpers

    private static let machine = Machine(
        id: UUID(uuidString: "5E1F7E57-0000-4000-8000-000000000001")!,
        displayName: "Self test",
        hostname: "localhost",
        username: "test",
        isLocal: true
    )

    private static func pane(_ id: String, terminal: String) -> AgentSummary {
        AgentSummary(json: .object(["pane_id": .string(id), "terminal_id": .string(terminal)]))!
    }

    private static func key(_ pane: AgentSummary) -> BrowserKey {
        BrowserKey(machine: machine, pane: pane)
    }

    private static func window(_ title: String, x: CGFloat) -> (NSWindow, BrowserRegion) {
        let window = NSWindow(
            contentRect: NSRect(x: x, y: 200, width: 700, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        let region = BrowserRegion()
        region.container.frame = window.contentView!.bounds
        region.container.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(region.container)
        window.orderFront(nil)
        return (window, region)
    }

    private static func wait(_ seconds: Double = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func devTools(_ tab: BrowserTab, _ method: String, _ parameters: [String: Any]? = nil) async -> [String: Any]? {
        guard let page = tab.page else { return nil }
        return await withCheckedContinuation { continuation in
            var finished = false
            page.runDevToolsMethod(method, parameters: parameters) { result, _ in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                guard !finished else { return }
                finished = true
                continuation.resume(returning: nil)
            }
        }
    }

    private static func evaluate(_ tab: BrowserTab, _ expression: String) async -> Any? {
        let response = await devTools(tab, "Runtime.evaluate", [
            "expression": expression, "awaitPromise": true, "returnByValue": true, "userGesture": true,
        ])
        return (response?["result"] as? [String: Any])?["value"]
    }

    // Accessibility elements are views, SwiftUI's nodes and Chromium's, with
    // nothing in common but NSObject and the NSAccessibility methods; they are
    // asked by selector.

    private static func accessibilityChildren(of element: AnyObject) -> [AnyObject] {
        let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        guard element.responds(to: selector),
              let children = element.perform(selector)?.takeUnretainedValue() as? [Any] else { return [] }
        return children.map { $0 as AnyObject }
    }

    private static func accessibilityString(_ element: AnyObject, _ selector: Selector) -> String? {
        guard element.responds(to: selector) else { return nil }
        let value = element.perform(selector)?.takeUnretainedValue()
        return value as? String ?? (value as? NSAccessibility.Role)?.rawValue
    }

    /// An element's role, title, label and value, run together.
    private static func accessibilityText(of element: AnyObject?) -> String {
        guard let element else { return "" }
        let selectors = [
            #selector(NSAccessibilityProtocol.accessibilityRole),
            #selector(NSAccessibilityProtocol.accessibilityTitle),
            #selector(NSAccessibilityProtocol.accessibilityLabel),
            #selector(NSAccessibilityProtocol.accessibilityValue),
        ]
        return selectors.compactMap { accessibilityString(element, $0) }.joined(separator: " ")
    }

    private static func findAccessibilityElement(in root: AnyObject, role: NSAccessibility.Role, named name: String, depth: Int = 0) -> AnyObject? {
        if depth > 40 { return nil }
        if accessibilityString(root, #selector(NSAccessibilityProtocol.accessibilityRole)) == role.rawValue,
           accessibilityText(of: root).contains(name) {
            return root
        }
        for child in accessibilityChildren(of: root) {
            if let found = findAccessibilityElement(in: child, role: role, named: name, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// What an assistive app does to have a Chromium-based app build its
    /// pages' accessibility trees: sets this attribute on the application.
    /// By selector, since the attribute API is deprecated in name only.
    private static func setManualAccessibility(_ enabled: Bool) {
        _ = NSApp.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"),
            with: NSNumber(value: enabled),
            with: "AXEnhancedUserInterface"
        )
    }

    private static func mainFrameID(_ tab: BrowserTab) async -> String? {
        let tree = await devTools(tab, "Page.getFrameTree")
        return ((tree?["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
    }

    private static func loaded(_ tab: BrowserTab, containing text: String) async -> Bool {
        await wait(20) { tab.hasView && !tab.isLoading && tab.url.contains(text) }
    }

    // MARK: The run

    private static func run() async {
        let store = BrowserStore.shared
        let paneA = pane("selftest:p1", terminal: "selftest-term-1")
        let paneB = pane("selftest:p2", terminal: "selftest-term-2")
        let keyA = key(paneA), keyB = key(paneB)
        let (windowOne, regionOne) = window("Self test 1", x: 80)
        let (windowTwo, regionTwo) = window("Self test 2", x: 820)

        // A3, S1/A16: a browser opens for a pane; the engine starts on the way.
        store.openBrowser(for: keyA, terminalID: paneA.terminalID, url: "https://example.com/")
        guard let browserA = store.browser(for: keyA), let tabA = browserA.selectedTab else {
            check("A3 open", false, store.engineError ?? "no browser")
            return
        }
        check("A16 engine running", BrowserEngine.isRunning)
        check("A3 open", await loaded(tabA, containing: "example.com"), tabA.url)
        check("title", await wait { tabA.title == "Example Domain" }, tabA.title)

        // A1: shown in a region, the page's view is in that region.
        store.show(keyA, in: regionOne, terminalID: paneA.terminalID)
        check("A1 in region", tabA.page?.view?.superview === regionOne.container)
        check("A1 sized to region", tabA.page?.view?.frame == regionOne.container.bounds)

        // A4: the same pane chosen in a second window goes there; the first
        // can take it back.
        store.show(keyA, in: regionTwo, terminalID: paneA.terminalID)
        check("A4 last window wins", store.isShown(keyA, in: regionTwo) && tabA.page?.view?.superview === regionTwo.container)
        check("A4 other window told", !store.isShown(keyA, in: regionOne))
        store.bringBrowser(to: regionOne)
        check("A4 show here", tabA.page?.view?.superview === regionOne.container)

        // C15: the main frame's ID (the CDP target ID) across a cross-site
        // navigation.
        let frameBefore = await mainFrameID(tabA)
        tabA.load("https://example.org/")
        _ = await loaded(tabA, containing: "example.org")
        let frameAfterNavigation = await mainFrameID(tabA)
        check("C15 same id after cross-site navigation", frameBefore != nil && frameBefore == frameAfterNavigation,
              "\(frameBefore ?? "nil") -> \(frameAfterNavigation ?? "nil")")

        // A9: JavaScript dialogs wait for the person.
        async let confirmed = evaluate(tabA, "new Promise(r => setTimeout(() => r(confirm('Sure?')), 0))")
        let confirmShown = await wait { !tabA.prompts.isEmpty }
        tabA.prompts.first?.answer(.accept())
        let confirmResult = await confirmed
        check("A9 confirm", confirmShown && (confirmResult as? Bool) == true)
        async let typed = evaluate(tabA, "new Promise(r => setTimeout(() => r(prompt('Name?', 'x')), 0))")
        let promptShown = await wait { !tabA.prompts.isEmpty }
        tabA.prompts.first?.answer(.accept(text: "shepherd"))
        let typedResult = await typed
        check("A9 prompt", promptShown && (typedResult as? String) == "shepherd")

        // A10: a site asking for a permission waits for the person, and is
        // told no when that is the answer.
        async let located = evaluate(tabA, "new Promise(r => navigator.geolocation.getCurrentPosition(() => r('granted'), e => r('error ' + e.code)))")
        let permissionShown = await wait {
            if case .permissions(let asked, _)? = tabA.prompts.first?.kind { return asked.contains(.geolocation) }
            return false
        }
        tabA.prompts.first?.answer(.decline)
        let locationResult = await located
        check("A10 permission prompt", permissionShown && (locationResult as? String) == "error 1", locationResult ?? "nil")

        // A10: HTTP authentication asks for a user name and password.
        tabA.load("https://httpbin.org/basic-auth/shepherd/secret")
        let credentialsShown = await wait(20) {
            if case .credentials? = tabA.prompts.first?.kind { return true }
            return false
        }
        tabA.prompts.first?.answer(.credentials(user: "shepherd", password: "secret"))
        _ = await loaded(tabA, containing: "basic-auth")
        let body = await evaluate(tabA, "document.body.innerText") as? String
        check("A10 sign-in prompt", credentialsShown && body?.contains("authenticated") == true,
              "prompt \(credentialsShown)")
        // The same, for a request the page makes rather than a navigation —
        // as another user, since the first one's sign-in is remembered.
        tabA.load("https://httpbin.org/")
        _ = await loaded(tabA, containing: "httpbin")
        async let fetched = evaluate(tabA, "fetch('/basic-auth/second/other').then(r => r.status, e => 'error ' + e)")
        let fetchPromptShown = await wait(20) {
            if case .credentials? = tabA.prompts.first?.kind { return true }
            return false
        }
        tabA.prompts.first?.answer(.credentials(user: "second", password: "other"))
        let fetchStatus = await fetched
        check("A10 sign-in prompt for a request", fetchPromptShown && (fetchStatus as? Int) == 200, "prompt \(fetchPromptShown), \(fetchStatus ?? "nil")")
        tabA.load("https://example.org/")
        _ = await loaded(tabA, containing: "example.org")

        // G7: the file a download saves is marked as downloaded
        // (quarantined), as any browser's. Saved into a folder of the
        // test's own, without the save panel, which the app can't operate
        // itself (see OnBeforeDownload).
        let downloads = FileManager.default.temporaryDirectory.appending(path: "shepherd-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        setenv("SHEPHERD_BROWSER_SELFTEST_DOWNLOADS", downloads.path(percentEncoded: false), 1)
        tabA.load("data:text/html,<a id=a href='data:text/plain,hello' download='selftest.txt'>file</a>")
        _ = await loaded(tabA, containing: "data:")
        _ = await evaluate(tabA, "document.getElementById('a').click(), true")
        let file = downloads.appending(path: "selftest.txt")
        let saved = await wait(10) { FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) }
        try? await Task.sleep(for: .milliseconds(500))
        let quarantine = getxattr(file.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, 0)
        check("G7 file saved", saved)
        check("G7 file quarantined", quarantine > 0)
        unsetenv("SHEPHERD_BROWSER_SELFTEST_DOWNLOADS")
        try? FileManager.default.removeItem(at: downloads)
        tabA.load("https://example.org/")
        _ = await loaded(tabA, containing: "example.org")

        // C4: window.open becomes another tab of the pane, keeping its opener.
        let tabCount = browserA.tabs.count
        _ = await evaluate(tabA, "window.open('https://example.com/?popup'), true")
        let popupOpened = await wait { browserA.tabs.count == tabCount + 1 }
        let popup = browserA.tabs.last
        check("C4 popup is a tab", popupOpened)
        if let popup, await loaded(popup, containing: "popup") {
            check("C4 popup keeps opener", (await evaluate(popup, "window.opener !== null")) as? Bool == true)
            check("C4 popup selected", browserA.selectedTab === popup)
            check("C4 popup on screen", popup.page?.view?.superview === regionOne.container
                && tabA.page?.view?.superview === store.holderView)
            browserA.close(popup)
            check("tab close", await wait { browserA.tabs.count == tabCount })
            check("tab close selects neighbour", browserA.selectedTab === tabA)
        }

        // A8, C15: a crashed renderer, then a reload.
        let frameBeforeCrash = await mainFrameID(tabA)
        _ = await devTools(tabA, "Page.crash")
        check("A8 crash noticed", await wait { tabA.crashReason != nil }, tabA.crashReason ?? "")
        tabA.reload()
        _ = await wait(20) { !tabA.isLoading && tabA.crashReason == nil }
        try? await Task.sleep(for: .seconds(1))
        let frameAfterCrash = await mainFrameID(tabA)
        check("C15 same id after crash and reload", frameBeforeCrash != nil && frameBeforeCrash == frameAfterCrash,
              "\(frameBeforeCrash ?? "nil") -> \(frameAfterCrash ?? "nil")")

        // Decision 1: panes don't share cookies unless both use the shared profile.
        _ = await evaluate(tabA, "document.cookie = 'selftest=1; max-age=600'; document.cookie")
        store.openBrowser(for: keyB, terminalID: paneB.terminalID, url: "https://example.org/")
        guard let browserB = store.browser(for: keyB), let tabB = browserB.selectedTab else {
            check("isolation", false, "no browser B")
            return
        }
        _ = await loaded(tabB, containing: "example.org")
        check("isolation", (await evaluate(tabB, "document.cookie") as? String)?.contains("selftest") == false)
        // A14: both move to the shared profile, and then share.
        browserA.switchProfile(to: .shared)
        browserB.switchProfile(to: .shared)
        let tabA2 = browserA.selectedTab!, tabB2 = browserB.selectedTab!
        _ = await loaded(tabA2, containing: "example.org")
        _ = await loaded(tabB2, containing: "example.org")
        _ = await evaluate(tabA2, "document.cookie = 'shared=1; max-age=600'; document.cookie")
        check("A14 shared profile shares", (await evaluate(tabB2, "document.cookie") as? String)?.contains("shared=1") == true)
        check("A14 page reopened at its address", tabA2.url.contains("example.org"), tabA2.url)

        // A5, A17: with no window showing it, the page goes to the holder
        // window and keeps running.
        store.remove(regionOne)
        store.remove(regionTwo)
        windowOne.close()
        windowTwo.close()
        check("A5 back to holder", tabA2.page?.view?.superview === store.holderView)
        let frames = await evaluate(tabA2, "new Promise(r => { let n = 0; const f = () => (++n < 10 ? requestAnimationFrame(f) : r(n)); requestAnimationFrame(f); setTimeout(() => r(n), 3000) })")
        // Not a pass or fail: a page off screen with no agent connected
        // gets no animation frames, as a background tab in Chrome doesn't.
        // Timers keep running, and so does everything once an agent is
        // connected (phase 0, S3).
        record("A17 animation frames off screen, no agent", frames ?? "nil")
        let timers = await evaluate(tabA2, "new Promise(r => { let n = 0; const t = setInterval(() => { if (++n == 5) { clearInterval(t); r(n) } }, 100); setTimeout(() => r(n), 3000) })")
        check("A17 timers run off screen", (timers as? Int) == 5, timers ?? "nil")

        // A7: no more than the maximum have their pages open.
        var extraKeys: [BrowserKey] = []
        for index in 0..<BrowserStore.maximumRunningBrowsers {
            let extra = pane("selftest:x\(index)", terminal: "selftest-x\(index)")
            extraKeys.append(key(extra))
            store.openBrowser(for: key(extra), terminalID: extra.terminalID, url: "about:blank")
        }
        let running = store.browsers.values.filter { !$0.isSuspended }.count
        check("A7 suspends the idle ones", running <= BrowserStore.maximumRunningBrowsers, "\(running) running")

        // B3: the same pane ID with another terminal is another pane.
        let (windowThree, regionThree) = window("Self test 3", x: 80)
        store.show(keyB, in: regionThree, terminalID: "another-terminal")
        check("B3 stale browser let go of", store.browser(for: keyB) == nil)
        store.remove(regionThree)
        windowThree.close()

        // F11: a pane browser with its own profile and a sign-in, kept for
        // the next run to find again.
        let paneC = pane("selftest:p3", terminal: "selftest-term-3")
        store.openBrowser(for: key(paneC), terminalID: paneC.terminalID, url: "https://example.com/")
        if let tabC = store.browser(for: key(paneC))?.selectedTab, await loaded(tabC, containing: "example.com") {
            _ = await evaluate(tabC, "document.cookie = 'persist=1; max-age=3600'; document.cookie")
        }

        // F3, F11: the pane is gone; its browser is closed and its profile
        // deleted.
        let folder = extraKeys.last.flatMap { store.browsers[$0]?.profile.isolatedFolder }.map(store.profileFolder(named:))
        try? await Task.sleep(for: .seconds(1))
        let folderExisted = folder.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        store.reconcile(machineID: machine.id, herdrMachineID: nil, panes: [paneA, paneC])
        check("F3 browsers of closed panes closed", store.browsers.keys.allSatisfy { $0 == keyA || $0 == key(paneC) }, store.browsers.count)
        check("F3 browser of a live pane kept", store.browser(for: keyA) != nil)
        try? await Task.sleep(for: .seconds(4))
        let folderGone = folder.map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
        check("F11 profile folder deleted", folderExisted && folderGone, folder?.lastPathComponent ?? "no folder")

        // A18: with an assistive app asking for it, the page's contents are
        // in the accessibility tree — reached the way the app's own windows
        // are, through SwiftUI's hosting of the browser's place.
        setManualAccessibility(true)
        let paneD = pane("selftest:p4", terminal: "selftest-term-4")
        store.openBrowser(for: key(paneD), terminalID: paneD.terminalID, url: "data:text/html,<h1>Accessibility</h1><button>Shepherd test button</button>")
        let accessibilityWindow = NSWindow(
            contentRect: NSRect(x: 80, y: 200, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        accessibilityWindow.isReleasedWhenClosed = false
        let hostedRegion = BrowserRegion()
        let host = NSHostingView(rootView: BrowserRegionView(region: hostedRegion, key: key(paneD), terminalID: paneD.terminalID))
        accessibilityWindow.contentView = host
        accessibilityWindow.orderFront(nil)
        if let tabD = store.browser(for: key(paneD))?.selectedTab, await loaded(tabD, containing: "data:") {
            var button: AnyObject?
            let reached = await wait(10) {
                button = findAccessibilityElement(in: host, role: .button, named: "Shepherd test button")
                return button != nil
            }
            check("A18 page content reachable", reached)
            if let button {
                // As VoiceOver and the accessibility API find an element: by
                // hit-testing the window at its position.
                let frame = (button as? NSAccessibilityElement)?.accessibilityFrame()
                    ?? (button as? NSView)?.accessibilityFrame()
                    ?? (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                let hit = host.accessibilityHitTest(NSPoint(x: frame.midX, y: frame.midY))
                check("A18 hit test reaches the page", accessibilityText(of: hit as AnyObject).contains("Shepherd test button"),
                      accessibilityText(of: hit as AnyObject))
            }
        } else {
            check("A18 page content reachable", false, "the page didn't load")
        }
        setManualAccessibility(false)
        store.remove(hostedRegion)
        accessibilityWindow.close()
        store.reconcile(machineID: machine.id, herdrMachineID: nil, panes: [paneA, paneC])

        // What is left (pane A, shared profile) stays for the next launch's
        // check of restoring.
        record("kept", store.browsers.keys.map(\.paneID).sorted())
    }
}
#endif
