#if os(macOS) && DEBUG
import AppKit

/// Finite owned app/service fixture, not UI automation or provider validation.
@MainActor enum ShepherdBrowserFeatureFixture {
    static func run() {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["SHEPHERD_BROWSER_FEATURE_FIXTURE"],
              let root = environment["SHEPHERD_BROWSER_TEST_ROOT"],
              root.hasPrefix("/tmp/") || root.hasPrefix("/private/tmp/") else {
            fatalError("Owned temporary fixture paths required")
        }
        Task {
            var checks: [String: Bool] = [:]
            func check(_ name: String, _ value: Bool) { checks[name] = value }
            do {
                let feature = ShepherdBrowserFeature.shared
                let store = BrowserStore.shared
                let proxy = CDPProxy.shared
                let machine = Machine(id: UUID(), displayName: "Owned feature fixture", hostname: "localhost", username: "owned", sessionName: "feature-fixture", isLocal: true)
                let pane = AgentSummary(json: .object(["pane_id": .string("w1:p1"), "terminal_id": .string("feature-terminal")]))!
                let key = BrowserKey(machine: machine, pane: pane)
                let sentinel = store.rootFolder.appending(path: "source-sentinel")
                let source = try Data(contentsOf: sentinel)
                let index = store.rootFolder.appending(path: "browsers.json")
                let originalIndex = try Data(contentsOf: index)
                check("default-off-no-engine", !feature.isEnabled && !BrowserEngine.isRunning)
                store.openBrowser(for: key, terminalID: pane.terminalID)
                await proxy.start(port: 0)
                MachineBrowserService.shared.accept([pane], on: machine)
                check("off-entrypoints-no-engine-listener-browser-route", !BrowserEngine.isRunning && proxy.port == nil && !store.hasBrowser(for: key) && MachineBrowserService.shared.resolve(CDPRoute("/v1/herdr/feature-fixture/pane/w1:p1")!) == nil)
                check("off-index-source-profile-preserved", try Data(contentsOf: index) == originalIndex && Data(contentsOf: sentinel) == source && FileManager.default.fileExists(atPath: store.rootFolder.appending(path: "preserved-profile").path))
                let client = HerdrClient(transport: LocalHerdrTransport(socketPath: store.rootFolder.appending(path: "absent-owned.sock").path))
                do {
                    try await AgentLaunchService.shared.install(using: client, on: machine)
                    check("off-agent-runtime-rejected-before-transport", false)
                } catch AgentRuntimeError.rejected(let reason) {
                    check("off-agent-runtime-rejected-before-transport", reason == "shepherd-browser-disabled")
                }
                let command = LocalCommand.Command(executable: URL(fileURLWithPath: "/bin/sh"),
                                                   arguments: ["-c", "printf normal-shell-without-node"],
                                                   environment: ["PATH": "/nonexistent"])
                let shell = try await LocalCommand.run(command, timeout: 5) { _, _ in ProxyError("Owned shell failed") }
                check("normal-shell-without-node", String(decoding: shell, as: UTF8.self) == "normal-shell-without-node")
                let enabled = await feature.setEnabled(true, canDisable: { false }, transition: { BrowserEngine.prepare() })
                MachineBrowserService.shared.accept([pane], on: machine)
                await proxy.start(port: 0)
                guard let endpoint = proxy.endpoint(for: key) else { throw ProxyError("Owned endpoint unavailable") }
                store.openBrowser(for: key, terminalID: pane.terminalID)
                check("on-browser-and-listener", enabled && BrowserEngine.isRunning && store.hasBrowser(for: key))
                var request = URLRequest(url: endpoint.url)
                request.setValue("Bearer " + (try String(contentsOf: endpoint.tokenFile, encoding: .utf8)), forHTTPHeaderField: "Authorization")
                let session = URLSession(configuration: .ephemeral)
                let socket = session.webSocketTask(with: request)
                socket.resume()
                try await socket.send(.string("{\"id\":1,\"method\":\"Browser.getVersion\"}"))
                let response = try await socket.receive()
                if case let .string(text) = response, let data = text.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    check("actual-authenticated-route", json["result"] != nil && json["id"] as? Int == 1)
                } else { check("actual-authenticated-route", false) }
                await feature.setEnabled(false)
                check("live-connection-refused-old-preference", feature.isEnabled && feature.refusal != nil)
                socket.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
                for _ in 0..<300 {
                    if !proxy.hasBrowserWork { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard !proxy.hasBrowserWork else { throw ProxyError("Owned connection cleanup not confirmed") }
                let urls = store.browser(for: key)?.tabs.map(\.url)
                await feature.setEnabled(false)
                check("inactive-off-blocks-resident-engine-preserves-tabs", !feature.isEnabled && proxy.port == nil && BrowserEngine.isRunning && store.browser(for: key)?.isSuspended == true && store.browser(for: key)?.tabs.map(\.url) == urls)
                await proxy.start(port: 0)
                check("off-resident-engine-no-admission", proxy.port == nil && proxy.endpoint(for: key) == nil)
                check("off-source-profile-still-preserved", try Data(contentsOf: sentinel) == source && FileManager.default.fileExists(atPath: store.rootFolder.appending(path: "preserved-profile").path))
                await feature.setEnabled(true, canDisable: { true }, transition: {})
                await proxy.start(port: 0)
                store.openBrowser(for: key, terminalID: pane.terminalID)
                check("reenable-restores-existing-browser", proxy.port != nil && store.browser(for: key)?.isSuspended == false)
            } catch { checks["fixture-error: \(error.localizedDescription)"] = false }
            try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.01)
        }
    }
}
#endif
