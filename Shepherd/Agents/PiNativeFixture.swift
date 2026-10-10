#if os(macOS) && DEBUG
import AppKit

/// Public launch-service qualification with private settings and owned PTYs.
/// Entry ownership is checked by AgentLaunchFixture; no launch-gate bypass.
@MainActor enum PiNativeFixture {
    static func run(root: String, folder: URL, socket: String, session: String, node: String) async throws {
        let machine = Machine(id: UUID(), displayName: "Owned Pi native", hostname: "localhost", username: "owned", sessionName: session, isLocal: true)
        let client = HerdrClient(transport: LocalHerdrTransport(socketPath: socket))
        let domain = "com.bldg-7.shepherd.pi-fixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = AgentLaunchService.HostContext(root: root + "/runtime", resources: try AgentSkillSetup.bundledResourceDirectory(), node: node,
            claudeSettings: root + "/home/.claude/settings.json", claudeSkills: root + "/home/.claude/skills", codexHome: root + "/home/.codex",
            executionSearchPath: ProcessInfo.processInfo.environment["PATH"])
        let service = AgentLaunchService(context: { context }, defaults: defaults,
            makeLocalClient: { _ in HerdrClient(transport: LocalHerdrTransport(socketPath: socket)) })
        var coordinator: PiLaunchCoordinator?
        do {
            try await client.connect()
            MachineBrowserService.shared.update(machines: [machine], localSocketPaths: [machine.id: socket])
            MachineBrowserService.shared.accept(try await client.launchSnapshot().panes, on: machine)
            await CDPProxy.shared.start(port: 0)
            guard CDPProxy.shared.port != nil else { throw PiBridgeFailure.unavailable }
            var selections = 0
            let created = try await service.launch(kind: .pi, on: machine, client: client, create: { environment in
                let created = try await client.createWorkspace(label: "Owned Pi native", on: nil, environment: environment)
                try write(["pane":created.pane.paneID,"terminal":created.pane.terminalID], folder.appendingPathComponent("selection.json"))
                // The owned terminal adapter attaches before the create callback
                // completes, mirroring the UI's terminal creation handshake.
                let deadline = ContinuousClock().now.advanced(by: .seconds(15))
                while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("attached").path), ContinuousClock().now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("attached").path) else { throw PiBridgeFailure.unavailable }
                return created
            }, select: { _ in selections += 1 })
            guard selections == 1 else { throw PiBridgeFailure.identity }
            let key = BrowserKey(machine: machine, pane: created.pane)
            let owner = AgentPaneIdentity(key: key, terminalID: created.pane.terminalID)
            guard let run = service.fixturePiCoordinator(for: owner), run.isReady else { throw PiBridgeFailure.unavailable }
            coordinator = run
            guard BrowserStore.shared.browser(for: key)?.agentSocketConnected != true else { throw PiBridgeFailure.conflict }
            try write(["ready":true,"pid":ProcessInfo.processInfo.processIdentifier,"stage":run.stage.folder,"metadataOnly":true,"publicLaunchService":true], folder.appendingPathComponent("ready.json"))
            let stop = folder.appendingPathComponent("stop")
            let until = ContinuousClock().now.advanced(by: .seconds(65))
            while !FileManager.default.fileExists(atPath: stop.path), ContinuousClock().now < until {
                if let browser = BrowserStore.shared.browser(for: key) {
                    try write(["connected":browser.agentSocketConnected,"title":browser.selectedTab?.title ?? "", "url":browser.selectedTab?.url ?? ""], folder.appendingPathComponent("browser.json"))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: stop.path) else { throw PiBridgeFailure.unavailable }
            await service.stop()
            guard !run.hasWork, !CDPProxy.shared.hasBrowserWork else { throw PiBridgeFailure.cleanupUnconfirmed }
            MachineBrowserService.shared.stop()
            await CDPProxy.shared.stop()
            await client.disconnect()
            guard BrowserStore.shared.shutDownNow() else { throw PiBridgeFailure.cleanupUnconfirmed }
            try write(["finished":true,"nativeRetirementConfirmed":true,"publicLaunchService":true], folder.appendingPathComponent("finished.json"))
            NSApp.terminate(nil)
        } catch {
            if let coordinator { try? write(coordinator.fixtureDiagnostics, folder.appendingPathComponent("binding-diagnostics.json")) }
            await service.stop()
            await client.disconnect()
            throw error
        }
    }
    private static func write(_ value: [String: Any], _ file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
#endif
