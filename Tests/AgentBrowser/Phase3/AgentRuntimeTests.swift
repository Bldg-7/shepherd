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
        let piBlocked = AgentRuntime(root: "/owned", resourceDirectory: "/owned", scriptRunner: { _ in fatalError("unqualified Pi must not invoke runtime") })
        do {
            _ = try await piBlocked.prepare(kind: .pi, executable: "pi",
                pane: .init(machineID: "m", herdrMachineID: nil, session: "default", paneID: "w1:p1", terminalID: "t"),
                endpoint: .init(origin: "thisMac", url: "ws://127.0.0.1:9333", tokenFile: "/owned/token"),
                codexHome: "/owned/codex", claudeSettingsFile: "/owned/claude/settings.json", on: .thisMac)
            fatalError("unqualified Pi prepared")
        } catch AgentRuntimeError.rejected(let code) { precondition(code == "pi-launch-unqualified") }
        let status = try await runtime.installation(on: .thisMac)
        precondition(status == nil)
        do { _ = try await runtime.install(on: .remote); fatalError("remote accepted") } catch AgentRuntimeError.remoteUnavailable {}
        let missingResult = AgentRuntime(root: "/owned", resourceDirectory: "/owned", scriptRunner: { _ in Data() })
        do { _ = try await missingResult.install(on: .thisMac); fatalError("empty exit-zero accepted") } catch {}
        let rejected = AgentRuntime(root: "/owned", resourceDirectory: "/owned", scriptRunner: { _ in Data("{\"ok\":false,\"error\":\"setup-busy\"}".utf8) })
        do { _ = try await rejected.install(on: .thisMac); fatalError("error accepted") } catch AgentRuntimeError.rejected(let code) { precondition(code == "setup-busy") }
        print("PASS AgentRuntimeTests: argv detection, resume merge, shell quoting, empty result rejection, explicit remote fail-closed, status")
    }
}
