import Foundation

nonisolated enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, pi
    /// Qualified local-launch capabilities, not a preference or an identity proof.
    /// Pi is authorized only by its native process/session bridge, never copied argv.
    var supportsManagedBrowserLaunch: Bool {
        switch self { case .claude, .codex, .pi: true }
    }
    /// Pi's kernel bridge is independent of legacy argv/session/idle heuristics.
    /// Enabling its launcher must never implicitly enable those contracts.
    var supportsLegacySessionInspection: Bool { self != .pi }
    var title: LocalizedStringResource {
        switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .pi: "Pi" }
    }
}
nonisolated enum AgentInjectionMode: String, Codable, Sendable { case plugin, global }
nonisolated enum AgentHost: Sendable { case thisMac, remote }

nonisolated struct AgentRuntimePreferences: Codable, Equatable, Sendable {
    var mode: AgentInjectionMode = .plugin
    var disableCompetingBrowsers = false
    var competingBrowserServers: [String] = []
    var allowedOrigins: [String] = []
    var blockedOrigins: [String] = []
    /// Pinned MCP evicts older output files above this threshold, not a disk quota.
    var outputMaxSize = 64 * 1024 * 1024
}

nonisolated struct AgentCLIAvailability: Codable, Sendable {
    enum Readiness: String, Codable, Sendable {
        case missing, unsupported, unsupportedPrerequisite, availableAuthenticationUnknown, integrationUnavailable
    }
    let nodeVersion: String
    let nodeSupported: Bool
    let kind: AgentKind
    let executable: String
    let version: String?
    let readiness: Readiness
    let sessionPlugin: Bool
    let sessionConfiguration: Bool
    let hookRewrite: Bool
}

/// Foundation-only copy of the accepted public descriptor. No private CEF state
/// or bearer bytes cross this boundary. Mac adapter consumes BrowserEndpoint.
nonisolated struct AgentBrowserEndpoint: Codable, Sendable {
    let origin: String
    let url: String
    let tokenFile: String
}

nonisolated struct AgentPaneIdentity: Codable, Hashable, Sendable {
    let machineID: String
    let herdrMachineID: String?
    let session: String
    let paneID: String
    let terminalID: String
}

nonisolated struct AgentRuntimeInstallation: Codable, Sendable {
    let version: String
    let resourceDirectory: String
    let mode: AgentInjectionMode
    let globalRegistrationVersion: String?
    var requiresGlobalUpdate: Bool { mode == .global && globalRegistrationVersion != version }
    let codexPluginKey: String?
    let codexPluginReady: Bool
}

/// Allocate before tab/pane creation; its environment contains only an opaque
/// future descriptor path. Bind the actual endpoint with prepare before start.
nonisolated struct AgentLaunchReservation: Codable, Sendable {
    let reservationID: String
    let environment: [String: String]
}

/// Offline resource staging only; the native bridge must separately authorize
/// the exact foreground process before pi-launch imports the CLI.
nonisolated struct PiStagedLaunch: Codable, Sendable {
    let id: String
    let sessionID: String
    let folder: String
    let manifest: String
    let bootstrap: String
    let cli: String
    let node: String
    let entry: String
    let resources: String
    let arguments: [String]
    let environment: [String: String]
}

/// Immutable launch plan. Pass arguments as argv to agent.start, not as shell
/// text. Environment goes in tab/pane creation. Never print this entire value:
/// user developer instructions can themselves contain sensitive information.
nonisolated struct PreparedAgentLaunch: Codable, Sendable {
    enum Injection: String, Codable, Sendable { case plugin, global, codexConfigurationFallback }
    let kind: AgentKind
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let outputFolder: String
    let sessionFolder: String
    let pluginDirectory: String
    let mcpConfiguration: String
    let mcpArguments: [String]
    let codexPluginKey: String?
    let injection: Injection

    /// Process argv is authoritative. A global registration cannot be proven
    /// from argv; return false so UI does not incorrectly show a connection.
    func isInjected(processArguments: [String]) -> Bool {
        guard kind.supportsLegacySessionInspection else { return false }
        switch kind {
        case .pi: return false
        case .claude:
            return zip(processArguments, processArguments.dropFirst()).contains {
                ($0 == "--plugin-dir" && $1 == pluginDirectory) || ($0 == "--mcp-config" && $1 == mcpConfiguration)
            }
        case .codex:
            return zip(processArguments, processArguments.dropFirst()).contains { flag, value in
                guard flag == "-c" || flag == "--config" else { return false }
                if let codexPluginKey, value == codexPluginKey + "=true" { return true }
                return value == "mcp_servers.shepherd-browser.args=" + Self.jsonString(mcpArguments)
            }
        }
    }

    func resuming(sessionID: String) throws -> PreparedAgentLaunch {
        guard kind.supportsLegacySessionInspection else { throw AgentRuntimeError.rejected("pi-resume-unqualified") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !sessionID.isEmpty, sessionID.count <= 128, sessionID.unicodeScalars.allSatisfy(allowed.contains),
              !arguments.contains(where: { ["resume", "--resume", "-r", "--continue"].contains($0) || $0.hasPrefix("--resume=") || (kind == .claude && $0 == "-c") }) else {
            throw AgentRuntimeError.rejected("resume-conflict-or-invalid-session")
        }
        let resumeArguments: [String]
        switch kind {
        case .claude: resumeArguments = ["--resume", sessionID]
        case .codex: resumeArguments = ["resume", sessionID]
        case .pi: throw AgentRuntimeError.rejected("pi-resume-unqualified")
        }
        return PreparedAgentLaunch(kind: kind, executable: executable,
            arguments: arguments + resumeArguments,
            environment: environment, outputFolder: outputFolder, sessionFolder: sessionFolder,
            pluginDirectory: pluginDirectory, mcpConfiguration: mcpConfiguration,
            mcpArguments: mcpArguments, codexPluginKey: codexPluginKey, injection: injection)
    }

    private static func jsonString(_ value: [String]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }
}

nonisolated enum AgentRuntimeError: Error, LocalizedError, Sendable {
    case remoteUnavailable
    case missingBundledResources
    case nodeUnavailable
    case rejected(String)
    var errorDescription: String? {
        switch self {
        case .remoteUnavailable: "Remote browser agent setup is not available yet."
        case .missingBundledResources: "Bundled Shepherd agent resources are unavailable."
        case .nodeUnavailable: String(localized: "Node.js was not found in the app's PATH or supported install locations. Node 20 or newer is required.")
        case .rejected(let code): "Shepherd agent runtime rejected the operation (\(code))."
        }
    }
}

/// Uses the existing runScript seam. Installation is local/offline: the bundle
/// must contain Resources plus pinned node_modules, supplied by npm ci at build
/// time. No public repository, npx, account request or token in shell arguments.
nonisolated struct AgentRuntime: Sendable {
    let root: String
    let resourceDirectory: String
    let nodeExecutable: String
    let executionSearchPath: String?
    private let scriptRunner: @Sendable (String) async throws -> Data

    init(root: String, resourceDirectory: String, nodeExecutable: String = "node", executionSearchPath: String? = nil,
         scriptRunner: @escaping @Sendable (String) async throws -> Data) {
        self.root = root; self.resourceDirectory = resourceDirectory
        self.nodeExecutable = nodeExecutable; self.executionSearchPath = executionSearchPath; self.scriptRunner = scriptRunner
    }

    func install(on host: AgentHost) async throws -> AgentRuntimeInstallation {
        try requireLocal(host)
        return try await run(action: "install", values: [:])
    }

    func installation(on host: AgentHost) async throws -> AgentRuntimeInstallation? {
        try requireLocal(host)
        let status: Status = try await run(action: "status", values: [:])
        return status.installation
    }

    func availability(of kind: AgentKind, executable: String, on host: AgentHost) async throws -> AgentCLIAvailability {
        try requireLocal(host)
        return try await run(action: "detect", values: ["kind": kind.rawValue, "executable": executable])
    }

    func checkScope(claudeSettingsFile: String, claudeSkillDirectory: String, codexHome: String, on host: AgentHost) async throws {
        try requireLocal(host)
        let result: Scope = try await run(action: "checkScope", values: ["claudeSettingsFile": claudeSettingsFile,
            "claudeSkillDirectory": claudeSkillDirectory, "codexHome": codexHome])
        guard result.sessionOnly else { throw AgentRuntimeError.rejected("session-only-policy") }
    }

    func setUpCodex(executable: String, codexHome: String, on host: AgentHost) async throws -> AgentRuntimeInstallation {
        try requireLocal(host)
        return try await run(action: "setupCodex", values: ["executable": executable, "codexHome": codexHome])
    }

    func setMode(_ mode: AgentInjectionMode, claudeSettingsFile: String, claudeSkillDirectory: String,
                 codexHome: String, on host: AgentHost) async throws -> AgentRuntimeInstallation {
        try requireLocal(host)
        return try await run(action: "setMode", values: ["mode": mode.rawValue, "claudeSettingsFile": claudeSettingsFile,
            "claudeSkillDirectory": claudeSkillDirectory, "codexHome": codexHome])
    }

    func stagePi(executable: String = "pi", preferences: AgentRuntimePreferences, on host: AgentHost) async throws -> PiStagedLaunch {
        try requireLocal(host)
        return try await run(action: "stagePi", values: ["executable": executable, "preferences": try object(preferences)])
    }

    func reserveLaunch(on host: AgentHost) async throws -> AgentLaunchReservation {
        try requireLocal(host)
        return try await run(action: "reserveLaunch", values: [:])
    }

    func discardReservation(_ reservation: AgentLaunchReservation, on host: AgentHost) async throws {
        try requireLocal(host)
        let _: Cleanup = try await run(action: "discardReservation", values: ["reservationID": reservation.reservationID])
    }

    /// A nil reservation is an argv-only existing-pane launch: Codex uses a
    /// descriptor-specific MCP configuration, never inherited descriptor env.
    /// Only a bound reservation permits the environment-dependent Codex plugin.
    func prepare(kind: AgentKind, executable: String, pane: AgentPaneIdentity, endpoint: AgentBrowserEndpoint,
                 preferences: AgentRuntimePreferences = .init(), arguments: [String] = [],
                 codexHome: String, claudeSettingsFile: String, profile: String? = nil,
                 reservation: AgentLaunchReservation? = nil, credentialLeaseFile: String? = nil,
                 on host: AgentHost) async throws -> PreparedAgentLaunch {
        try requireLocal(host)
        guard kind.supportsLegacySessionInspection else { throw AgentRuntimeError.rejected("pi-launch-unqualified") }
        var values: [String: Any] = ["kind": kind.rawValue, "executable": executable, "pane": try object(pane),
            "endpoint": try object(endpoint), "preferences": try object(preferences), "arguments": arguments,
            "codexHome": codexHome, "claudeSettingsFile": claudeSettingsFile]
        if let profile { values["profile"] = profile }
        if let reservation { values["reservationID"] = reservation.reservationID }
        if let credentialLeaseFile { values["credentialLeaseFile"] = credentialLeaseFile }
        return try await run(action: "prepare", values: values)
    }

    /// Register each successfully resolved local snapshot pane before a child
    /// command is offered. Hook preparation uses only these accepted descriptors;
    /// unknown/remote/ambiguous targets stay unchanged and are reason-recorded.
    func registerPane(_ pane: AgentPaneIdentity, endpoint: AgentBrowserEndpoint,
                      preferences: AgentRuntimePreferences = .init(), executables: [String: String] = [:],
                      codexHome: String, claudeSettingsFile: String, on host: AgentHost) async throws {
        try requireLocal(host)
        let _: Registration = try await run(action: "registerPane", values: ["pane": try object(pane),
            "endpoint": try object(endpoint), "preferences": try object(preferences), "executables": executables,
            "codexHome": codexHome, "claudeSettingsFile": claudeSettingsFile])
    }

    /// Call only after proven pane disappearance and child MCP termination.
    /// Do not call on failed snapshots, disconnect, app quit or normal agent exit.
    func cleanup(pane: AgentPaneIdentity, on host: AgentHost) async throws {
        try requireLocal(host)
        let _: Cleanup = try await run(action: "cleanup", values: ["pane": try object(pane)])
    }

    private struct Scope: Decodable { let sessionOnly: Bool }
    private struct Status: Decodable { let installation: AgentRuntimeInstallation? }
    private struct Cleanup: Decodable { let removed: Bool }
    private struct Registration: Decodable { let registered: Bool }
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let result: T?; let error: String? }
    private func requireLocal(_ host: AgentHost) throws {
        guard case .thisMac = host else { throw AgentRuntimeError.remoteUnavailable }
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private func run<T: Decodable>(action: String, values: [String: Any]) async throws -> T {
        var request = values; request["action"] = action; request["root"] = root
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
        let input = String(decoding: data, as: UTF8.self)
        if let executionSearchPath, executionSearchPath.utf8.contains(0) {
            throw AgentRuntimeError.rejected("invalid-executable-search-path")
        }
        // Assignment applies only to this Node process and its CLI children;
        // never source rc files or modify the app/global shell environment.
        let environment = executionSearchPath.map { "PATH=" + Self.shellQuote($0) + " " } ?? ""
        let script = "printf '%s' " + Self.shellQuote(input) + " | " + environment + Self.shellQuote(nodeExecutable) + " " +
            Self.shellQuote(resourceDirectory + "/runtime.mjs")
        let output = try await scriptRunner(script)
        // A rejected process may make runScript throw first; do not treat an
        // empty/exit-zero-before-result response as success.
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: output)
        guard envelope.ok, let result = envelope.result else { throw AgentRuntimeError.rejected(envelope.error ?? "missing-result") }
        return result
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
