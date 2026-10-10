import Foundation

/// Local packaged skill / pinned MCP installer for Shepherd-managed sessions.
/// User-global registration is not supported.
nonisolated enum AgentSkillSetup {
    static let skillName = "shepherd-browser"

    nonisolated struct Report: Equatable, Sendable {
        enum Registration: String, Sendable { case registered, missing, failed }
        var claude: Registration?
        var codex: Registration?
    }

    /// Construct with a confirmed host context. Resource packaging is owned by
    /// integration: Contents/Resources/AgentRuntime is a copied folder including
    /// pinned node_modules, not a download from a public repository.
    static func runtime(root: String, resources: String, nodeExecutable: String = "node",
                        executionSearchPath: String? = nil, using client: HerdrClient) -> AgentRuntime {
        AgentRuntime(root: root, resourceDirectory: resources, nodeExecutable: nodeExecutable,
                     executionSearchPath: executionSearchPath, scriptRunner: { try await client.runScript($0) })
    }

    static func bundledResourceDirectory(in bundle: Bundle = .main) throws -> String {
        guard let folder = bundle.resourceURL?.appendingPathComponent("AgentRuntime"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("runtime.mjs").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("node_modules/@playwright/mcp/package.json").path) else {
            throw AgentRuntimeError.missingBundledResources
        }
        return folder.path
    }

    /// Retained solely so the separately owned old settings UI still compiles.
    /// Its owner must switch to the explicit host/mode contract. Never infer
    /// local/remote identity from a connection or install global settings here.
    @available(*, deprecated, message: "Use AgentRuntime.install(on:) with an explicit host and packaged resources")
    static func setUp(using client: HerdrClient) async throws -> Report {
        throw AgentRuntimeError.rejected("explicit-host-context-required")
    }

    @available(*, deprecated, message: "Use AgentRuntime.installation(on:) with an explicit host")
    static func isInstalled(using client: HerdrClient) async throws -> Bool {
        throw AgentRuntimeError.rejected("explicit-host-context-required")
    }
}
