import Foundation

@main
struct AgentRuntimeTests {
    static func main() async throws {
        let launch = PreparedAgentLaunch(kind: .claude, executable: "claude", arguments: ["--plugin-dir", "/owned path/plugin"],
            environment: ["SHEPHERD_AGENT_SESSION": "/owned/session.json"], outputFolder: "/owned/output", sessionFolder: "/owned",
            pluginDirectory: "/owned path/plugin", mcpConfiguration: "/owned/mcp.json", mcpArguments: [], codexPluginKey: nil, injection: .plugin)
        precondition(launch.isInjected(processArguments: ["claude"] + launch.arguments))
        precondition(!launch.isInjected(processArguments: ["claude", "--plugin-dir", "/different/plugin"]))
        let resumedClaude = try launch.resuming(sessionID: "session_1")
        precondition(resumedClaude.arguments.suffix(2) == ["--resume", "session_1"])
        do { _ = try launch.resuming(sessionID: "../bad"); fatalError("invalid resume accepted") } catch {}
        let codex = PreparedAgentLaunch(kind: .codex, executable: "codex", arguments: ["-p", "work", "-c", "plugins.shepherd@local.enabled=true"],
            environment: [:], outputFolder: "/owned/output", sessionFolder: "/owned", pluginDirectory: "/owned/plugin", mcpConfiguration: "/owned/mcp.json",
            mcpArguments: ["/owned path/mcp.mjs", "/owned/session.json"], codexPluginKey: "plugins.shepherd@local.enabled", injection: .plugin)
        precondition(codex.isInjected(processArguments: ["codex"] + codex.arguments))
        let resumedCodex = try codex.resuming(sessionID: "session-1")
        precondition(resumedCodex.arguments.suffix(2) == ["resume", "session-1"])
        let fallback = PreparedAgentLaunch(kind: .codex, executable: "codex", arguments: ["--profile", "work", "-c", "mcp_servers.shepherd-browser.args=[\"/owned/mcp.mjs\",\"/owned/session.json\"]", "-c", "developer_instructions=\"User words\\n\\nShepherd words\""], environment: [:], outputFolder: "/owned/output", sessionFolder: "/owned", pluginDirectory: "/owned/plugin", mcpConfiguration: "/owned/mcp.json", mcpArguments: ["/owned/mcp.mjs", "/owned/session.json"], codexPluginKey: nil, injection: .codexConfigurationFallback)
        let existingResume = try fallback.resuming(sessionID: "owned-existing-session")
        precondition(existingResume.environment.isEmpty && existingResume.arguments.dropLast(2) == fallback.arguments[...])
        precondition(existingResume.isInjected(processArguments: ["codex"] + existingResume.arguments))
        // The server is 3rdr-browser now; a session launched under its earlier name still counts.
        for name in ["3rdr-browser", "shepherd-browser"] {
            precondition(fallback.isInjected(processArguments: ["codex", "-c", "mcp_servers.\(name).args=[\"/owned/mcp.mjs\",\"/owned/session.json\"]"]), name)
        }
        precondition(!fallback.isInjected(processArguments: ["codex", "-c", "mcp_servers.other-browser.args=[\"/owned/mcp.mjs\",\"/owned/session.json\"]"]))
        precondition(!fallback.isInjected(processArguments: ["codex", "-c", "mcp_servers.3rdr-browser.args=[\"/other/mcp.mjs\",\"/owned/session.json\"]"]))
        let oldNode = try JSONDecoder().decode(AgentCLIAvailability.self, from: Data("{\"kind\":\"codex\",\"executable\":\"codex\",\"version\":null,\"nodeVersion\":\"18.20.0\",\"nodeSupported\":false,\"readiness\":\"unsupportedPrerequisite\",\"sessionPlugin\":false,\"sessionConfiguration\":false,\"hookRewrite\":false}".utf8))
        precondition(!oldNode.nodeSupported && oldNode.readiness == .unsupportedPrerequisite)
        let piAvailability = try JSONDecoder().decode(AgentCLIAvailability.self, from: Data("{\"kind\":\"pi\",\"executable\":\"pi\",\"version\":\"1.1.0\",\"nodeVersion\":\"22.19.0\",\"nodeSupported\":true,\"readiness\":\"integrationUnavailable\",\"sessionPlugin\":false,\"sessionConfiguration\":false,\"hookRewrite\":false}".utf8))
        precondition(piAvailability.kind == .pi && piAvailability.readiness == .integrationUnavailable)
        precondition(AgentKind.pi.supportsManagedBrowserLaunch && !AgentKind.pi.supportsLegacySessionInspection)
        let piPlan = PreparedAgentLaunch(kind: .pi, executable: "pi", arguments: fallback.arguments, environment: [:],
            outputFolder: "/owned/output", sessionFolder: "/owned", pluginDirectory: "/owned/plugin", mcpConfiguration: "/owned/mcp.json",
            mcpArguments: fallback.mcpArguments, codexPluginKey: nil, injection: .codexConfigurationFallback)
        precondition(!piPlan.isInjected(processArguments: ["pi"] + fallback.arguments))
        do { _ = try piPlan.resuming(sessionID: "saved-pi"); fatalError("Pi resumed through Codex") }
        catch AgentRuntimeError.rejected(let code) { precondition(code == "pi-resume-unqualified") }
        let value = "path with ' quotes $literal\nnewline"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + AgentRuntime.shellQuote(value)]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        precondition(process.terminationStatus == 0 && String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == value)
        let runtime = AgentRuntime(root: "/owned", resourceDirectory: "/owned/resources", scriptRunner: { _ in
            Data("{\"ok\":true,\"result\":{\"installation\":null}}".utf8)
        })
        try await installationWithoutNode()
        let piBlocked = AgentRuntime(root: "/owned", resourceDirectory: "/owned", scriptRunner: { _ in fatalError("unqualified Pi must not invoke runtime") })
        do {
            _ = try await piBlocked.prepare(kind: .pi, executable: "pi",
                pane: .init(machineID: "m", herdrMachineID: nil, session: "default", paneID: "w1:p1", terminalID: "t"),
                endpoint: .init(origin: "thisMac", url: "ws://127.0.0.1:9333", tokenFile: "/owned/token"),
                codexHome: "/owned/codex", claudeSettingsFile: "/owned/claude/settings.json", on: .thisMac)
            fatalError("unqualified Pi prepared")
        } catch AgentRuntimeError.rejected(let code) { precondition(code == "pi-launch-unqualified") }
        do { _ = try await runtime.install(on: .remote); fatalError("remote accepted") } catch AgentRuntimeError.remoteUnavailable {}
        do { _ = try await runtime.installation(on: .remote); fatalError("remote status accepted") } catch AgentRuntimeError.remoteUnavailable {}
        let missingResult = AgentRuntime(root: "/owned", resourceDirectory: "/owned", scriptRunner: { _ in Data() })
        do { _ = try await missingResult.install(on: .thisMac); fatalError("empty exit-zero accepted") } catch {}
        let rejected = AgentRuntime(root: "/owned", resourceDirectory: "/owned", scriptRunner: { _ in Data("{\"ok\":false,\"error\":\"setup-busy\"}".utf8) })
        do { _ = try await rejected.install(on: .thisMac); fatalError("error accepted") } catch AgentRuntimeError.rejected(let code) { precondition(code == "setup-busy") }
        print("PASS AgentRuntimeTests: argv detection, resume merge, shell quoting, empty result rejection, explicit remote fail-closed, status without Node")
    }

    /// The installation is read the way runtime.mjs's status action read it,
    /// in a private temporary folder, and never runs a script.
    static func installationWithoutNode() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("runtime-status-" + UUID().uuidString)
        try manager.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: base) }
        func runtime(_ root: String) -> AgentRuntime {
            AgentRuntime(root: root, resourceDirectory: "/owned/resources", scriptRunner: { _ in fatalError("status must not run Node") })
        }
        func rejection(_ root: String) async -> String? {
            do { _ = try await runtime(root).installation(on: .thisMac); return nil }
            catch AgentRuntimeError.rejected(let code) { return code }
            catch { return "other: \(error)" }
        }
        func folder(_ name: String, mode: Int = 0o700) throws -> URL {
            let url = base.appendingPathComponent(name)
            try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }
        let missing = base.appendingPathComponent("missing")
        let value1 = try await runtime(missing.path).installation(on: .thisMac)
        precondition(value1 == nil, "missing runtime folder is no installation")
        precondition(!manager.fileExists(atPath: missing.path), "reading the status does not create the runtime folder")
        let empty = try folder("empty")
        let value2 = try await runtime(empty.path).installation(on: .thisMac)
        precondition(value2 == nil, "no installation.json is no installation")
        let installed = try folder("installed")
        let expected = AgentRuntimeInstallation(version: "2.0.0-owned", resourceDirectory: installed.path + "/versions/2.0.0-owned", mode: .plugin,
                                                globalRegistrationVersion: nil, codexPluginKey: nil, codexPluginReady: false)
        try Data("{\"version\":\"2.0.0-owned\",\"resourceDirectory\":\"\(expected.resourceDirectory)\",\"mode\":\"plugin\",\"globalRegistrationVersion\":null,\"codexPluginKey\":null,\"codexPluginReady\":false}".utf8)
            .write(to: installed.appendingPathComponent("installation.json"))
        let value3 = try await runtime(installed.path).installation(on: .thisMac)
        precondition(value3 == expected, "installation.json decoded")
        let value4 = try await runtime(installed.path + "/").installation(on: .thisMac)
        precondition(value4 == expected, "trailing slash joins like path.join")
        let nullFile = try folder("null")
        try Data("null".utf8).write(to: nullFile.appendingPathComponent("installation.json"))
        let value5 = try await runtime(nullFile.path).installation(on: .thisMac)
        precondition(value5 == nil, "a null installation is none")
        let shared = try folder("shared", mode: 0o755)
        try Data("{}".utf8).write(to: shared.appendingPathComponent("installation.json"))
        let value6 = await rejection(shared.path)
        precondition(value6 == "unsafe-directory", "group/other access is unsafe")
        let linked = base.appendingPathComponent("linked")
        try manager.createSymbolicLink(at: linked, withDestinationURL: installed)
        let value7 = await rejection(linked.path)
        precondition(value7 == "unsafe-directory", "a symlinked runtime folder is unsafe")
        let plainFile = base.appendingPathComponent("plain-file")
        try Data().write(to: plainFile)
        let value8 = await rejection(plainFile.path)
        precondition(value8 == "unsafe-directory", "a file is not a runtime folder")
        let broken = try folder("broken")
        try Data("{\"version\":".utf8).write(to: broken.appendingPathComponent("installation.json"))
        let value9 = await rejection(broken.path)
        precondition(value9 == "runtime-failed", "broken JSON fails as Node's JSON.parse did")
        let value10 = await rejection("relative/runtime")
        precondition(value10 == "invalid-runtime-root", "relative root rejected")
        let value11 = await rejection("")
        precondition(value11 == "invalid-runtime-root", "empty root rejected")
    }
}
