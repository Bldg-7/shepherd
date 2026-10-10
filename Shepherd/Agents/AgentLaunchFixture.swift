#if os(macOS) && DEBUG
import AppKit

/// Owned integration fixture for the real application service, not UI automation.
/// Only caller-created HOME/config/socket/profile paths below one private root.
@MainActor enum AgentLaunchFixture {
    private struct Input: Decodable {
        let root: String
        let socket: String
        let session: String
        let node: String
        let piNative: Bool?
    }

    static func run() {
        guard let output = ProcessInfo.processInfo.environment["SHEPHERD_AGENT_LAUNCH_FIXTURE"],
              let profile = ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_TEST_ROOT"] else { fatalError("Owned fixture bindings required") }
        let folder = URL(fileURLWithPath: output)
        Task {
            do {
                let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: folder.appending(path: "input.json")))
                let root = URL(fileURLWithPath: input.root).resolvingSymlinksInPath().path
                let attributes = try FileManager.default.attributesOfItem(atPath: root)
                guard root.hasPrefix("/private/tmp/") || root.hasPrefix("/tmp/") else { throw AgentRuntimeError.rejected("fixture-root-required") }
                guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                      [input.socket, profile, ProcessInfo.processInfo.environment["HOME"] ?? ""].allSatisfy({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.hasPrefix(root + "/") }),
                      URL(fileURLWithPath: profile).resolvingSymlinksInPath().path == BrowserStore.shared.rootFolder.resolvingSymlinksInPath().path else {
                    throw AgentRuntimeError.rejected("fixture-ownership-mismatch")
                }
                if input.piNative == true {
                    try await PiNativeFixture.run(root: root, folder: folder, socket: input.socket, session: input.session, node: input.node)
                    return
                }
                let home = root + "/home"
                let suite = "com.bldg-7.shepherd.launch-fixture." + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let context = AgentLaunchService.HostContext(root: root + "/runtime", resources: try AgentSkillSetup.bundledResourceDirectory(), node: input.node,
                    claudeSettings: home + "/.claude/settings.json", claudeSkills: home + "/.claude/skills", codexHome: home + "/.codex")
                let machine = Machine(id: UUID(uuidString: "C0CD0000-0000-4000-8000-000000000003")!, displayName: "Owned phase3 launcher", hostname: "localhost", username: "owned", sessionName: input.session, isLocal: true)
                let service = AgentLaunchService(context: { context }, defaults: defaults,
                    makeLocalClient: { _ in HerdrClient(transport: LocalHerdrTransport(socketPath: input.socket)) })
                var resumeEvidence: [[String: Any]] = []
                service.resumeObservation = { observation in
                    resumeEvidence.append(observation)
                    try? write(["observations": resumeEvidence], to: folder.appending(path: "resume-observations.json"))
                }
                service.start(); service.update(machines: [machine])
                MachineBrowserService.shared.update(machines: [machine], localSocketPaths: [machine.id: input.socket])
                await CDPProxy.shared.start(port: 0)
                guard CDPProxy.shared.port != nil else { throw AgentRuntimeError.rejected("fixture-listener-unavailable") }
                let client = HerdrClient(transport: LocalHerdrTransport(socketPath: input.socket))
                try await client.connect()
                try await service.check(using: client, on: machine)
                try await service.install(using: client, on: machine)
                await client.disconnect()
                try write(["ready": true, "pid": ProcessInfo.processInfo.processIdentifier], to: folder.appending(path: "ready.json"))
                var lastCommand = ""
                var created: [AgentSummary] = []
                let deadline = ContinuousClock().now.advanced(by: .seconds(110))
                while ContinuousClock().now < deadline {
                    if let command = try? String(contentsOf: folder.appending(path: "command"), encoding: .utf8), command != lastCommand {
                        lastCommand = command
                        if command == "quit" { break }
                        try await client.connect()
                        var result: [String: Any] = ["command": command]
                        do {
                            if command.hasPrefix("resume-"), let pane = created.last,
                               let current = try await client.agentList().first(where: { $0.terminalID == pane.terminalID }) {
                                resumeEvidence.append(AgentLaunchService.fixtureObservation(current, phase: "before-resume"))
                                try write(["observations": resumeEvidence], to: folder.appending(path: "resume-observations.json"))
                                try await service.resume(current, on: machine, client: client)
                                for row in try await client.agentList() where row.paneID == current.paneID && row.terminalID == current.terminalID {
                                    resumeEvidence.append(AgentLaunchService.fixtureObservation(row, phase: "after-resume"))
                                }
                                try write(["observations": resumeEvidence], to: folder.appending(path: "resume-observations.json"))
                                result["ok"] = true; result["selectedTerminal"] = current.terminalID
                            } else if command == "global" || command == "plugin" {
                                try await service.setMode(command == "global" ? .global : .plugin, using: client, on: machine)
                                result["ok"] = true
                            } else if let kind = AgentKind(rawValue: command) {
                                var selected: AgentSummary?
                                _ = try await service.launch(kind: kind, on: machine, client: client,
                                    create: { environment in try await client.createWorkspace(label: "Owned launcher \(kind.rawValue)", on: nil, environment: environment) },
                                    select: { tab in
                                        selected = tab.pane; created.append(tab.pane)
                                        try? write(["pane": tab.pane.paneID, "terminal": tab.pane.terminalID], to: folder.appending(path: "selection.json"))
                                    })
                                result["ok"] = true
                                result["selectedTerminal"] = selected?.terminalID
                            }
                        } catch {
                            if command.hasPrefix("resume-") {
                                for row in (try? await client.agentList()) ?? [] where row.terminalID == created.last?.terminalID {
                                    resumeEvidence.append(AgentLaunchService.fixtureObservation(row, phase: "resume-failure"))
                                }
                                try? write(["observations": resumeEvidence], to: folder.appending(path: "resume-observations.json"))
                            }
                            result["ok"] = false
                            result["error"] = connectionFailureDescription(error)
                            result["selectedTerminal"] = created.last?.terminalID
                        }
                        await client.disconnect()
                        try write(result, to: folder.appending(path: "result.json"))
                    }
                    try await client.connect()
                    let snapshot = try await client.launchSnapshot()
                    await client.disconnect()
                    let rows: [[String: Any]] = snapshot.panes.map { pane in
                        let key = BrowserKey(machine: machine, pane: pane)
                        let endpoint = CDPProxy.shared.endpoint(for: key)
                        return ["pane": pane.paneID, "terminal": pane.terminalID, "agent": pane.agentName ?? "",
                                "interactiveReady": pane.interactiveReady == true, "pending": pane.launchPending == true,
                                "status": String(localized: service.status(for: pane, on: machine).title), "canResume": service.canResume(pane, on: machine),
                                "endpoint": endpoint?.url.absoluteString ?? "", "socketConnected": BrowserStore.shared.browser(for: key)?.agentSocketConnected == true]
                    }
                    try write(["panes": rows, "modeBlocked": service.modeChangeBlocked, "mode": service.installation?.mode.rawValue ?? "unknown"], to: folder.appending(path: "status.json"))
                    try await Task.sleep(for: .milliseconds(200))
                }
                try write(["phase": "consumer-stop-started"], to: folder.appending(path: "shutdown-progress.json"))
                MachineBrowserService.shared.stop()
                await service.stop()
                try write(["phase": "consumer-stopped"], to: folder.appending(path: "shutdown-progress.json"))
                // No quit dialog automation: agents/MCP must have naturally ended.
                guard CDPProxy.shared.activeConnections == 0, BrowserStore.shared.shutDownNow() else { throw AgentRuntimeError.rejected("fixture-shutdown-not-confirmed") }
                try write(["natural": lastCommand == "quit"], to: folder.appending(path: "finished.json"))
                NSApp.terminate(nil)
            } catch {
                try? write(["failed": true, "error": connectionFailureDescription(error)], to: folder.appending(path: "failed.json"))
                MachineBrowserService.shared.stop()
                if CDPProxy.shared.activeConnections == 0, BrowserStore.shared.shutDownNow() { NSApp.terminate(nil) }
            }
        }
    }

    private static func write(_ object: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
#endif
