#if os(macOS) && DEBUG
import AppKit

@MainActor final class NativeProbeClient {
    var lease: BrowserNativeLease!
    var messages: [[String: Any]] = []
    var recordMessages = true
    var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    var closed = false
    var eventReceived: (([String: Any]) -> Void)?
    init(page: BrowserPage) {
        lease = page.makeNativeLease { [weak self] text in
            guard let self, let data = text.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if self.recordMessages { self.messages.append(message) }
            if message["method"] != nil { self.eventReceived?(message) }
            if let id = message["id"] as? Int { self.pending.removeValue(forKey: id)?.resume(returning: message) }
        }
    }
    func call(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        let id = BrowserEngine.nextDevToolsMessageID()
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        let data = try JSONSerialization.data(withJSONObject: message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if !lease.sendMessage(String(decoding: data, as: UTF8.self)) { pending.removeValue(forKey: id)?.resume(throwing: ProxyError("Native send failed")) }
            Task { try? await Task.sleep(for: .seconds(10)); self.pending.removeValue(forKey: id)?.resume(throwing: ProxyError("Native timeout: " + method)) }
        }
    }
    func sendNoReply(_ method: String, params: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: ["id": BrowserEngine.nextDevToolsMessageID(), "method": method, "params": params]) {
            _ = lease.sendMessage(String(decoding: data, as: UTF8.self))
        }
    }
    func invalidate() {
        closed = true; lease.invalidate()
        for c in pending.values { c.resume(throwing: ProxyError("Native lease removed")) }
        pending = [:]
    }
}

@MainActor enum NativeBProbe {
    private static func scopedSessions(page: BrowserPage, browser: PaneBrowser, base: String) async throws -> [String: Any] {
        let client = NativeProbeClient(page: page)
        defer { client.invalidate() }
        var e: [String: Any] = [:]
        let browserAttach = try await client.call("Target.attachToBrowserTarget")
        e["attachBrowser"] = browserAttach
        let scope = (browserAttach["result"] as? [String: Any])?["sessionId"] as? String
        let target = browser.selectedTab!.cdpTargetID!
        let attach = try await client.call("Target.attachToTarget", ["targetId": target, "flatten": true], session: scope)
        e["attachPage"] = attach
        guard let session = (attach["result"] as? [String: Any])?["sessionId"] as? String else { return e }
        _ = try await client.call("Runtime.enable", session: session)
        _ = try await client.call("Page.enable", session: session)
        _ = try await client.call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true], session: session)
        e["scriptAdded"] = try await client.call("Page.addScriptToEvaluateOnNewDocument", ["source": "window.scopedMarker='OLD-SCOPED-SCRIPT'"], session: session)
        e["bindingAdded"] = try await client.call("Runtime.addBinding", ["name": "oldScopedBinding"], session: session)
        _ = try await client.call("Runtime.evaluate", ["expression": "window.scopedWorker=new Worker('/worker.js?scope');scopedWorker.onmessage=e=>window.scopeResult=e.data;scopedWorker.postMessage('go');'spawn'", "returnByValue": true], session: session)
        try await Task.sleep(for: .milliseconds(200))
        let paused = client.messages.last { $0["method"] as? String == "Target.attachedToTarget" && $0["sessionId"] as? String == session }
        e["pausedChild"] = paused
        let late = Task { try? await client.call("Runtime.evaluate", ["expression": "new Promise(r=>setTimeout(()=>r('OLD-SCOPED-PENDING'),700))", "awaitPromise": true, "returnByValue": true], session: session) }
        try await Task.sleep(for: .milliseconds(100))
        e["detachOwner"] = try await client.call("Target.detachFromTarget", ["sessionId": scope ?? session])
        let count = client.messages.count
        let replacement = try await client.call("Target.attachToBrowserTarget")
        e["replacementBrowser"] = replacement
        let newScope = (replacement["result"] as? [String: Any])?["sessionId"] as? String
        let newAttach = try await client.call("Target.attachToTarget", ["targetId": target, "flatten": true], session: newScope)
        e["replacementPage"] = newAttach
        guard let newSession = (newAttach["result"] as? [String: Any])?["sessionId"] as? String else { return e }
        _ = try await client.call("Runtime.evaluate", ["expression": "console.log('replacement-no-runtime-enable');typeof window.oldScopedBinding", "returnByValue": true], session: newSession)
        try await Task.sleep(for: .milliseconds(900))
        let after = Array(client.messages.dropFirst(count))
        e["oldRepliesAfterDetach"] = after.filter { String(describing: $0).contains("OLD-SCOPED-PENDING") }
        e["runtimeEventsLeakedIntoReplacement"] = after.contains { $0["method"] as? String == "Runtime.consoleAPICalled" && $0["sessionId"] as? String == newSession }
        e["workerAfterDetach"] = try await client.call("Runtime.evaluate", ["expression": "window.scopeResult??null", "returnByValue": true], session: newSession)
        if let child = (paused?["params"] as? [String: Any])?["sessionId"] as? String {
            e["oldChildAfterDetach"] = try await client.call("Runtime.runIfWaitingForDebugger", session: child)
        }
        e["bindingAfterDetach"] = try await client.call("Runtime.evaluate", ["expression": "typeof window.oldScopedBinding", "returnByValue": true], session: newSession)
        _ = try await client.call("Runtime.enable", session: newSession)
        let bindingCount = client.messages.count
        _ = try await client.call("Runtime.evaluate", ["expression": "window.oldScopedBinding('after-detach-binding')", "returnByValue": true], session: newSession)
        e["oldBindingEventsInNewSession"] = Array(client.messages.dropFirst(bindingCount)).filter { $0["method"] as? String == "Runtime.bindingCalled" }
        e["permissionToOwnedContext"] = try await client.call("Browser.grantPermissions", ["permissions": ["geolocation"], "browserContextId": ((paused?["params"] as? [String: Any])?["targetInfo"] as? [String: Any])?["browserContextId"] ?? "missing"], session: newSession)
        _ = try await client.call("Page.navigate", ["url": base + "/new-scoped-navigation"], session: newSession)
        try await Task.sleep(for: .milliseconds(500))
        e["scriptAfterDetach"] = try await client.call("Runtime.evaluate", ["expression": "window.scopedMarker??null", "returnByValue": true], session: newSession)
        _ = try await client.call("Emulation.setScriptExecutionDisabled", ["value": true], session: newSession)
        e["fetchEnabled"] = try await client.call("Fetch.enable", ["patterns": [["urlPattern": "*", "requestStage": "Request"]]], session: newSession)
        let pausedFetch = Task { try? await client.call("Page.navigate", ["url": base + "/paused-fetch"], session: newSession) }
        for _ in 0..<100 {
            if client.messages.contains(where: { $0["method"] as? String == "Fetch.requestPaused" && $0["sessionId"] as? String == newSession }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        e["fetchActuallyPaused"] = client.messages.contains { $0["method"] as? String == "Fetch.requestPaused" && $0["sessionId"] as? String == newSession }
        e["detachFetchOwner"] = try await client.call("Target.detachFromTarget", ["sessionId": newSession])
        let third = try await client.call("Target.attachToTarget", ["targetId": target, "flatten": true])
        if let thirdSession = (third["result"] as? [String: Any])?["sessionId"] as? String {
            _ = try await client.call("Page.navigate", ["url": base + "/after-fetch-detach"], session: thirdSession)
            try await Task.sleep(for: .milliseconds(500))
            e["emulationAndFetchReset"] = try await client.call("Runtime.evaluate", ["expression": "window.pageScriptRan===true && document.title==='Native B fixture'", "returnByValue": true], session: thirdSession)
            e["fetchEventsInThirdSession"] = client.messages.contains { $0["method"] as? String == "Fetch.requestPaused" && $0["sessionId"] as? String == thirdSession }
            _ = try await client.call("Target.detachFromTarget", ["sessionId": thirdSession])
        }
        _ = await pausedFetch.value
        _ = await late.value
        e["result"] = "scoped-probe-complete"
        return e
    }

    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SHEPHERD_NATIVE_B_PROBE"], let base = env["SHEPHERD_NATIVE_B_HTTP"], env["SHEPHERD_BROWSER_TEST_ROOT"] != nil else { fatalError("Disposable B roots required") }
        let folder = URL(fileURLWithPath: out)
        Task {
            var evidence: [String: Any] = [:]
            var transcript: [[String: Any]] = []
            func save() { try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appending(path: "native-results.json"), options: .atomic) }
            do {
                let machine = Machine(id: UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!, displayName: "B native probe", hostname: "localhost", username: "fixture", isLocal: true)
                let pane = AgentSummary(json: .object(["pane_id": .string("native:p1"), "terminal_id": .string("native-terminal")]))!
                let key = BrowserKey(machine: machine, pane: pane)
                BrowserStore.shared.machineIgnoredByReconcile = machine.id
                BrowserStore.shared.openBrowser(for: key, terminalID: pane.terminalID, url: base + "/")
                let browser = BrowserStore.shared.browser(for: key)!
                for _ in 0..<200 { if browser.selectedTab?.cdpTargetID != nil && browser.selectedTab?.isLoading == false { break }; try await Task.sleep(for: .milliseconds(50)) }
                let page = browser.selectedTab!.page!
                if env["SHEPHERD_NATIVE_B_SESSION"] == "1" {
                    evidence = try await scopedSessions(page: page, browser: browser, base: base)
                    save()
                    try await Task.sleep(for: .seconds(5))
                    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.01)
                    return
                }
                var client = NativeProbeClient(page: page)
                evidence["runtimeEnable"] = try await client.call("Runtime.enable")["error"] == nil
                evidence["pageEnable"] = try await client.call("Page.enable")["error"] == nil
                evidence["frameTree"] = try await client.call("Page.getFrameTree")["result"]
                evidence["autoAttach"] = try await client.call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true])["error"] == nil
                _ = try await client.call("Runtime.evaluate", ["expression": "var f=document.createElement('iframe');f.src='" + base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/frame';document.body.append(f);window.w=new Worker('/worker.js');w.onmessage=e=>window.workerResult=e.data;w.postMessage('go');'spawned'", "returnByValue": true])
                for _ in 0..<100 {
                    let attaches = client.messages.filter { $0["method"] as? String == "Target.attachedToTarget" }
                    for m in attaches {
                        guard let p = m["params"] as? [String: Any], let id = p["sessionId"] as? String else { continue }
                        if !transcript.contains(where: { $0["continued"] as? String == id }) {
                            let result = try await client.call("Runtime.runIfWaitingForDebugger", session: id)
                            transcript.append(["continued": id, "result": result])
                        }
                    }
                    let types = Set(attaches.compactMap { ($0["params"] as? [String: Any])?["targetInfo"] as? [String: Any] }.compactMap { $0["type"] as? String })
                    if types.contains("iframe") && types.contains("worker") { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                evidence["childAttachments"] = client.messages.filter { $0["method"] as? String == "Target.attachedToTarget" }
                for _ in 0..<100 {
                    let value = try await client.call("Runtime.evaluate", ["expression": "window.workerResult??null", "returnByValue": true])
                    if ((value["result"] as? [String: Any])?["result"] as? [String: Any])?["value"] as? String == "native-worker-ok" { evidence["workerResult"] = value; break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                if let m = client.messages.first(where: { (($0["params"] as? [String: Any])?["targetInfo"] as? [String: Any])?["type"] as? String == "iframe" }), let id = (m["params"] as? [String: Any])?["sessionId"] as? String {
                    evidence["iframeEvaluation"] = try await client.call("Runtime.evaluate", ["expression": "document.querySelector('button').textContent", "returnByValue": true], session: id)
                }
                _ = try await client.call("Runtime.evaluate", ["expression": "window.pausedWorker=new Worker('/worker.js?paused');pausedWorker.onmessage=e=>window.pausedResult=e.data;pausedWorker.postMessage('go');'spawned-paused'", "returnByValue": true])
                try await Task.sleep(for: .milliseconds(300))
                let paused = client.messages.last { ($0["method"] as? String) == "Target.attachedToTarget" }
                evidence["pausedBeforeRemoval"] = paused
                _ = try await client.call("Page.addScriptToEvaluateOnNewDocument", ["source": "window.nativeLeaseMarker='old-client-script'"])
                let old = client
                let late = Task { try? await old.call("Runtime.evaluate", ["expression": "new Promise(r=>setTimeout(()=>r('OLD-PENDING-RESULT'),700))", "awaitPromise": true, "returnByValue": true]) }
                try await Task.sleep(for: .milliseconds(100))
                old.invalidate()
                client = NativeProbeClient(page: page)
                _ = try await client.call("Runtime.evaluate", ["expression": "console.log('after-observer-removal');window.pausedResult??null", "returnByValue": true])
                try await Task.sleep(for: .milliseconds(900))
                evidence["lateOldResponsesSeenByReplacement"] = client.messages.filter { String(describing: $0).contains("OLD-PENDING-RESULT") }
                evidence["runtimeDomainStillEnabled"] = client.messages.contains { $0["method"] as? String == "Runtime.consoleAPICalled" }
                evidence["workerStillPaused"] = try await client.call("Runtime.evaluate", ["expression": "window.pausedResult??null", "returnByValue": true])
                if let id = (paused?["params"] as? [String: Any])?["sessionId"] as? String { evidence["oldChildSessionUsableAfterRemoval"] = try await client.call("Runtime.runIfWaitingForDebugger", session: id) }
                _ = await late.value
                // Zero registered observers: removal versus underlying agent state.
                page.setAppDevToolsObserverEnabled(false)
                _ = try await client.call("Runtime.enable")
                _ = try await client.call("Runtime.evaluate", ["expression": "window.zeroWorker=new Worker('/worker.js?zero');zeroWorker.onmessage=e=>window.zeroResult=e.data;zeroWorker.postMessage('go');'zero-spawn'", "returnByValue": true])
                try await Task.sleep(for: .milliseconds(200))
                let zeroAttach = client.messages.last { $0["method"] as? String == "Target.attachedToTarget" }
                evidence["zeroPausedBeforeRemoval"] = zeroAttach
                let zeroOld = client
                let zeroLate = Task { try? await zeroOld.call("Runtime.evaluate", ["expression": "new Promise(r=>setTimeout(()=>r('ZERO-OLD-PENDING'),700))", "awaitPromise": true, "returnByValue": true]) }
                try await Task.sleep(for: .milliseconds(100))
                client.invalidate()
                client = NativeProbeClient(page: page)
                try await Task.sleep(for: .milliseconds(900))
                evidence["lateAfterZeroObservers"] = client.messages.filter { String(describing: $0).contains("ZERO-OLD-PENDING") }
                evidence["zeroWorkerAfterRemoval"] = try await client.call("Runtime.evaluate", ["expression": "window.zeroResult??null", "returnByValue": true])
                if let id = (zeroAttach?["params"] as? [String: Any])?["sessionId"] as? String { evidence["zeroOldChildUsable"] = try await client.call("Runtime.runIfWaitingForDebugger", session: id) }
                _ = await zeroLate.value
                _ = try await client.call("Runtime.evaluate", ["expression": "console.log('after-zero-observers')", "returnByValue": true])
                evidence["runtimeDomainAfterZeroObservers"] = client.messages.contains { $0["method"] as? String == "Runtime.consoleAPICalled" }
                evidence["replacementNativeMessages"] = client.messages
                _ = try await client.call("Page.navigate", ["url": base + "/after-removal"])
                try await Task.sleep(for: .milliseconds(600))
                evidence["scriptSurvivesRemoval"] = try await client.call("Runtime.evaluate", ["expression": "window.nativeLeaseMarker??null", "returnByValue": true])
                _ = try await client.call("Runtime.enable")
                page.closeDevToolsFrontendForProbe()
                client.invalidate()
                client = NativeProbeClient(page: page)
                _ = try await client.call("Runtime.evaluate", ["expression": "console.log('after-CloseDevTools')", "returnByValue": true])
                evidence["runtimeDomainAfterCloseDevTools"] = client.messages.contains { $0["method"] as? String == "Runtime.consoleAPICalled" }
                if let target = browser.selectedTab?.cdpTargetID {
                    evidence["manualAttachSelf"] = try await client.call("Target.attachToTarget", ["targetId": target, "flatten": true])
                }
                let sibling = browser.openTab(url: base + "/sibling", select: false)
                for _ in 0..<100 { if sibling.cdpTargetID != nil { break }; try await Task.sleep(for: .milliseconds(50)) }
                if let target = sibling.cdpTargetID {
                    evidence["manualAttachSibling"] = try await client.call("Target.attachToTarget", ["targetId": target, "flatten": true])
                }
                evidence["permissionCommand"] = try await client.call("Browser.grantPermissions", ["permissions": ["geolocation"]])
                evidence["downloadBrowserCommand"] = try await client.call("Browser.setDownloadBehavior", ["behavior": "deny"])
                client.invalidate()
                page.setAppDevToolsObserverEnabled(true)
                evidence["result"] = "probe-complete"
                save()
            } catch { evidence["failure"] = String(describing: error); save() }
            try? JSONSerialization.data(withJSONObject: transcript, options: [.prettyPrinted]).write(to: folder.appending(path: "native-transcript.json"))
            try? await Task.sleep(for: .seconds(5))
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.01)
        }
    }
}
#endif
