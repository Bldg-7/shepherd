#if os(macOS) && DEBUG
import AppKit

/// Executable fixture uses the production listener/proxy/CEF, but no normal
/// machine polling, browser profile or herdr connection. Metadata never
/// contains a token; the Node test reads the private file without logging it.
@MainActor
enum BrowserPhase2Fixture {
    static func run() {
        guard let path = ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_PHASE2_FIXTURE"],
              let root = ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_TEST_ROOT"],
              URL(fileURLWithPath: root).resolvingSymlinksInPath().path == BrowserStore.shared.rootFolder.resolvingSymlinksInPath().path else {
            fatalError("A disposable fixture/profile root is required")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        if let socket = ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_HERDR_SOCKET"],
           let session = ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_HERDR_SESSION"] {
            runRealHerdr(folder: folder, socket: socket, session: session)
            return
        }
        let machine = Machine(id: UUID(uuidString: "C0CD0000-0000-4000-8000-000000000001")!,
                              displayName: "Disposable phase2 fixture", hostname: "localhost", username: "fixture",
                              sessionName: "phase2-fixture", isLocal: true)
        func pane(_ id: String, _ terminal: String, previous: String? = nil) -> AgentSummary {
            var json: [String: JSONValue] = ["pane_id": .string(id), "terminal_id": .string(terminal)]
            if let previous { json["previous_pane_id"] = .string(previous) }
            return AgentSummary(json: .object(json))!
        }
        Task {
            let proxy = CDPProxy.shared
            let store = BrowserStore.shared
            var downloads: [[String: Any]] = []
            proxy.downloadDidChange = { key, metadata in
                var event = metadata
                event["pane"] = key.paneID
                downloads = Array((downloads + [event]).suffix(128))
                try? JSONSerialization.data(withJSONObject: downloads).write(to: folder.appending(path: "download-events.json"), options: .atomic)
            }
            var snapshot = [pane("w1:p1", "fixture-term-1"), pane("w1:p2", "fixture-term-2")]
            MachineBrowserService.shared.accept(snapshot, on: machine)
            let requestedPort = ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_TEST_PORT"].flatMap(Int.init) ?? 0
            await proxy.start(port: requestedPort)
            if let error = proxy.error {
                let evidence: [String: Any] = ["error": error, "browserCount": store.browsers.count,
                                              "portUnavailable": proxy.port == nil]
                try JSONSerialization.data(withJSONObject: evidence).write(to: folder.appending(path: "listener-error.json"), options: .atomic)
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.01)
                return
            }
            let keys = snapshot.map { BrowserKey(machine: machine, pane: $0) }
            guard let endpoint = proxy.endpoint(for: keys[0]), let second = proxy.endpoint(for: keys[1]) else {
                fatalError("Fixture listener failed")
            }
            let schemaCases = await validateSnapshotSchema()
            let metadata: [String: Any] = ["snapshotSchemaCasesPassed": schemaCases, "endpointA": endpoint.url.absoluteString, "endpointB": second.url.absoluteString,
                                           "tokenFile": endpoint.tokenFile.path, "pid": ProcessInfo.processInfo.processIdentifier]
            try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appending(path: "ready.json"), options: .atomic)
            var lastCommand = ""
            while true {
                let command = (try? String(contentsOf: folder.appending(path: "command"), encoding: .utf8)) ?? ""
                if command != lastCommand {
                    lastCommand = command
                    switch command {
                    case "delay-next-attach":
                        NativeCDPController.shared.delayNextAttachReplyForTest()
                        try? Data("armed".utf8).write(to: folder.appending(path: "delay-armed.txt"))
                    case "shutdown-error-probe":
                        // No browser column or application window is available.
                        for window in NSApp.windows where window.isVisible { window.close() }
                        let visibleBefore = NSApp.windows.filter(\.isVisible).count
                        let observed = ModalObservation()
                        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                            MainActor.assumeIsolated {
                                guard let window = NSApp.modalWindow, let content = window.contentView else { return }
                                observed.hasModal = window.isVisible
                                let text = textValues(in: content)
                                observed.messagePresented = text.contains(String(localized: "Could not quit safely"))
                                observed.recoveryPresented = store.engineError.map(text.contains) ?? false
                                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                            }
                        }
                        RunLoop.main.add(timer, forMode: .modalPanel)
                        let began = Date()
                        let reply = AppDelegate().applicationShouldTerminate(NSApp)
                        timer.invalidate()
                        try? JSONSerialization.data(withJSONObject: ["canceled": reply == .terminateCancel,
                            "engineRunning": BrowserEngine.isRunning, "visibleWindowsBefore": visibleBefore,
                            "modalObserved": observed.hasModal, "messagePresented": observed.messagePresented,
                            "recoveryPresented": observed.recoveryPresented,
                            "elapsedSeconds": Date().timeIntervalSince(began)]).write(to: folder.appending(path: "shutdown-error.json"))
                    case "shutdown-deadline":
                        if !store.hasBrowser(for: keys[0]) {
                            store.openBrowser(for: keys[0], terminalID: snapshot[0].terminalID)
                        }
                        let acknowledged = BrowserEngine.shutDown(within: 0)
                        try? JSONSerialization.data(withJSONObject: ["acknowledged": acknowledged,
                            "engineRunning": BrowserEngine.isRunning]).write(to: folder.appending(path: "shutdown-deadline.json"))
                    case "controller-failure":
                        NativeCDPController.shared.shutDown()
                    case "user-file-navigation":
                        let file = folder.appending(path: "user-file.html")
                        try? Data("<title>Disposable user file</title>".utf8).write(to: file)
                        // Simulate a trusted user navigation on a still-live page,
                        // not an agent bypass. Production CDP/CEF guards stay intact.
                        if let tab = store.browser(for: keys[0])?.selectedTab {
                            tab.page?.agentControlled = false
                            tab.load(file.absoluteString)
                        }
                    case "user-web-navigation":
                        store.browser(for: keys[0])?.selectedTab?.load("about:blank")
                    case "share-profiles":
                        for key in keys { store.browser(for: key)?.switchProfile(to: .shared) }
                    case "close-user-tab":
                        if let browser = store.browser(for: keys[0]), let tab = browser.tabs.last {
                            browser.close(tab)
                            try? Data(tab.url.utf8).write(to: folder.appending(path: "user-close-url.txt"))
                        }
                    case "move": snapshot[0] = pane("w2:p1", "fixture-term-1", previous: "w1:p1")
                    case "gone": snapshot = snapshot.filter { $0.terminalID != "fixture-term-1" }
                    case "restart": snapshot = [pane("w1:p2", "fixture-restarted-terminal")]
                    case "open-unsafe":
                        let file = folder.appending(path: "private-fixture.html")
                        try? Data("<title>Private fixture file</title><p>synthetic file only</p>".utf8).write(to: file)
                        store.browser(for: keys[0])?.openTab(url: file.absoluteString, select: false)
                    case "quit-cancel":
                        let observed = ModalObservation()
                        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                            MainActor.assumeIsolated {
                                observed.hasModal = NSApp.modalWindow != nil
                                NSApp.stopModal(withCode: .alertSecondButtonReturn)
                            }
                        }
                        RunLoop.main.add(timer, forMode: .modalPanel)
                        let reply = AppDelegate().applicationShouldTerminate(NSApp)
                        timer.invalidate()
                        let evidence = ["modalObserved": observed.hasModal, "canceled": reply == .terminateCancel]
                        try? JSONSerialization.data(withJSONObject: evidence).write(to: folder.appending(path: "quit-evidence.json"), options: .atomic)
                    case "crash":
                        store.browser(for: keys[0])?.selectedTab?.page?.runDevToolsMethod("Page.crash", parameters: nil) { _, _ in }
                    case "reload":
                        store.browser(for: keys[0])?.selectedTab?.reload()
                    case "probe-cef":
                        do {
                            let evidence = try await probeNativeContexts()
                            try JSONSerialization.data(withJSONObject: evidence).write(to: folder.appending(path: "native-probe.json"), options: .atomic)
                        } catch {
                            try? Data("{\"probeFailed\":true}".utf8).write(to: folder.appending(path: "native-probe.json"))
                        }
                    case "suspend-pressure":
                        for index in 3...10 {
                            let extra = pane("pressure:\(index)", "pressure-\(index)")
                            snapshot.append(extra)
                            store.openBrowser(for: BrowserKey(machine: machine, pane: extra), terminalID: extra.terminalID)
                        }
                    case "quit":
                        await proxy.stop()
                        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.01)
                        return
                    default: break
                    }
                    MachineBrowserService.shared.accept(snapshot, on: machine)
                }
                let status: [String: Any] = ["connections": proxy.activeConnections, "attachRepliesDeferred": NativeCDPController.shared.deferredAttachRepliesForTest, "delayedAttachDetachesAcknowledged": NativeCDPController.shared.delayedAttachDetachesAcknowledgedForTest, "appNapPrevented": proxy.isPreventingAppNap, "childTargetTypes": Array(proxy.observedChildTargetTypes),
                    "browsers": store.browsers.values.map { ["pane": $0.key.paneID, "terminal": $0.terminalID,
                        "profile": $0.profile.folderName, "tabs": $0.tabs.count, "connected": $0.agentConnected, "socketConnected": $0.agentSocketConnected,
                        "suspended": $0.isSuspended, "downloadFolder": store.downloadFolder(for: $0).path] as [String: Any] }]
                try? JSONSerialization.data(withJSONObject: status).write(to: folder.appending(path: "status.json"), options: .atomic)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private static func textValues(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { textValues(in: $0) }
    }

    private static func validateSnapshotSchema() async -> Int {
        let pane: JSONValue = .object(["pane_id": .string("w1:p1"), "terminal_id": .string("fixture-terminal")])
        let invalid: [JSONValue] = [
            .object([:]),
            .object(["snapshot": .object([:])]),
            .object(["snapshot": .object(["panes": .array([.object(["pane_id": .string("w1:p1")])])])]),
            .object(["snapshot": .object(["panes": .array([pane, pane])])])
        ]
        var passed = 0
        for response in invalid {
            let client = HerdrClient(transport: SnapshotFixtureTransport(response: response))
            do { _ = try await client.snapshot() }
            catch is HerdrClient.SnapshotSchemaError { passed += 1 }
            catch { }
        }
        let empty = HerdrClient(transport: SnapshotFixtureTransport(response: .object(["snapshot": .object(["panes": .array([])])])))
        if let snapshot = try? await empty.snapshot(), snapshot.panes.isEmpty { passed += 1 }
        return passed
    }

    private static func runRealHerdr(folder: URL, socket: String, session: String) {
        Task {
            let machine = Machine(id: UUID(uuidString: "C0CD0000-0000-4000-8000-000000000002")!,
                                  displayName: "Disposable herdr", hostname: "localhost", username: "fixture",
                                  sessionName: session, isLocal: true)
            let client = HerdrClient(transport: LocalHerdrTransport(socketPath: socket))
            do {
                let snapshot = try await client.snapshot()
                guard snapshot.panes.count >= 2 else { throw ProxyError("Two disposable panes required") }
                MachineBrowserService.shared.accept(snapshot.panes, on: machine)
                MachineBrowserService.shared.update(machines: [machine], localSocketPaths: [machine.id: socket])
                let proxy = CDPProxy.shared
                await proxy.start(port: 0)
                let endpoints = snapshot.panes.compactMap { pane -> [String: String]? in
                    guard let endpoint = proxy.endpoint(for: BrowserKey(machine: machine, pane: pane)) else { return nil }
                    return ["endpoint": endpoint.url.absoluteString, "terminal": pane.terminalID, "pane": pane.paneID]
                }
                let metadata: [String: Any] = ["panes": endpoints, "tokenFile": endpoints.isEmpty ? "" : BrowserStore.shared.rootFolder.appending(path: "agent-token").path]
                try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appending(path: "ready.json"), options: .atomic)
                while true {
                    if (try? String(contentsOf: folder.appending(path: "command"), encoding: .utf8)) == "quit" {
                        await proxy.stop()
                        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.01)
                        return
                    }
                    let status: [String: Any] = ["connections": proxy.activeConnections, "attachRepliesDeferred": NativeCDPController.shared.deferredAttachRepliesForTest, "delayedAttachDetachesAcknowledged": NativeCDPController.shared.delayedAttachDetachesAcknowledgedForTest, "appNapPrevented": proxy.isPreventingAppNap, "childTargetTypes": Array(proxy.observedChildTargetTypes),
                        "pollFailed": MachineBrowserService.shared.errors[machine.id] != nil,
                        "browsers": BrowserStore.shared.browsers.values.map { ["pane": $0.key.paneID, "terminal": $0.terminalID,
                            "profile": $0.profile.folderName, "connected": $0.agentConnected, "socketConnected": $0.agentSocketConnected, "tabs": $0.tabs.count] as [String: Any] }]
                    try JSONSerialization.data(withJSONObject: status).write(to: folder.appending(path: "status.json"), options: .atomic)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } catch { fatalError("Disposable herdr fixture failed") }
        }
    }

    private static func probeNativeContexts() async throws -> [String: Any] {
        let (transport, owner) = try await NativeCDPController.shared.acquire()
        defer { transport.retire(owner) {} }
        let result = try await transport.call(owner, "Target.getTargets", params: ["filter": [[:]]])
        let infos = result["targetInfos"] as? [[String: Any]] ?? []
        return ["targetTypes": Array(Set(infos.compactMap { $0["type"] as? String })),
                "contextPresent": infos.contains { $0["browserContextId"] is String }]
    }

}

@MainActor private final class ModalObservation {
    var hasModal = false
    var messagePresented = false
    var recoveryPresented = false
}

private actor SnapshotFixtureTransport: HerdrTransport {
    let response: JSONValue
    init(response: JSONValue) { self.response = response }
    func connect() async throws {}
    func disconnect() async {}
    func send(method: String, params: JSONValue) async throws -> JSONValue {
        guard method == "session.snapshot" else { throw ProxyError("Unexpected fixture method") }
        return response
    }
    func events() -> AsyncStream<JSONValue> { AsyncStream { $0.finish() } }
    func runHerdr(_ arguments: [String]) async throws -> Data { throw ProxyError("No fixture CLI") }
    func runScript(_ script: String) async throws -> Data { throw ProxyError("No fixture shell") }
}
#endif
