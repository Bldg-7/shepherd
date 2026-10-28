#if os(macOS)
import CFNetwork
import CryptoKit
import Foundation
import ServiceManagement

// What `AgentProxyService` stands on in the app: the build's LaunchAgent and
// control socket, the setting in user defaults, This Mac's herdr and the
// system's proxy settings. Apart from the service, so that tests can build
// it with stand-ins and none of these.

extension AgentProxyService {
    static let shared = AgentProxyService(environment: .system())
}

extension AgentProxyService.Environment {
    /// The app's own: its build's LaunchAgent and control socket, the setting
    /// in user defaults, and This Mac's herdr.
    static func system() -> Self {
        #if DEBUG
        let variant = AgentProxyPaths.Variant.debug
        #else
        let variant = AgentProxyPaths.Variant.release
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let suffix = variant == .debug ? "-Debug" : ""
        let settingKey = "agentProxyEnabled" + suffix, rejectedKey = "agentProxyRejectedKinds" + suffix
        let executable = Bundle.main.bundleURL.appending(path: AgentProxyPaths.bundleProgram).path
        let build = AgentProxyBundledBuild(path: executable)
        return Self(
            launchAgent: SystemAgentProxyLaunchAgent(variant: variant),
            control: AgentProxyControlClient(socketPath: AgentProxyPaths.controlSocket(home: home, variant: variant)),
            loadSetting: { UserDefaults.standard.bool(forKey: settingKey) },
            saveSetting: { UserDefaults.standard.set($0, forKey: settingKey) },
            loadRejectedKinds: { Set(UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []) },
            saveRejectedKinds: { UserDefaults.standard.set($0.sorted(), forKey: rejectedKey) },
            clearOffline: {
                try await AgentProxyControlClient.clearOffline(executable: executable,
                    stateDirectory: AgentProxyPaths.stateDirectory(home: home, variant: variant),
                    socketPath: AgentProxyPaths.recorderSocket(home: home, variant: variant))
            },
            bundledBuild: { await build.value() },
            systemProxyConfigured: { AgentProxySystemSettings.httpProxyConfigured() },
            liveTerminals: { await AgentProxySystemSettings.liveTerminals(session: $0) })
    }
}

/// The SHA-256 of the executable in the app's bundle, read once.
actor AgentProxyBundledBuild {
    private let path: String
    private var read: String??

    init(path: String) { self.path = path }

    func value() async -> String? {
        if let read { return read }
        let path = path
        let hash = await Task.detached(priority: .utility) { () -> String? in
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
        read = .some(hash)
        return hash
    }
}

nonisolated enum AgentProxySystemSettings {
    /// A proxy for HTTP or HTTPS, a PAC file or proxy discovery, or SOCKS, set
    /// in System Settings: the agent proxy connects to the API directly, which
    /// such a network may not allow.
    static func httpProxyConfigured() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        let enables = [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesProxyAutoConfigEnable,
                       kCFNetworkProxiesProxyAutoDiscoveryEnable, kCFNetworkProxiesSOCKSEnable] as [CFString]
        return enables.contains { (settings[$0 as String] as? NSNumber)?.boolValue == true }
    }

    /// The terminals of This Mac's herdr session `session`, as `session.snapshot`
    /// and `agent.list` give them now: empty when no herdr serves it, nil
    /// when it can't be read.
    static func liveTerminals(session: String) async -> Set<String>? {
        guard !session.isEmpty, session.utf8.count <= 128, !session.contains("/"), session != ".", session != ".." else { return nil }
        let base = URL(fileURLWithPath: LocalHerdrTransport.defaultSocketPath)
        let socket = session == "default" ? base.path
            : base.deletingLastPathComponent().appending(path: "sessions").appending(path: session).appending(path: "herdr.sock").path
        guard FileManager.default.fileExists(atPath: socket) else { return [] }
        let client = HerdrClient(transport: LocalHerdrTransport(socketPath: socket))
        do {
            try await client.connect()
            let panes = try await client.launchSnapshot().panes
            let agents = try await client.agentList()
            await client.disconnect()
            return Set(panes.map(\.terminalID)).union(agents.map(\.terminalID))
        } catch {
            await client.disconnect()
            return nil
        }
    }
}
/// `SMAppService.agent` with the build's own plist in the app's
/// Contents/Library/LaunchAgents (`AgentProxyPaths.launchAgentPlistName`).
@MainActor final class SystemAgentProxyLaunchAgent: AgentProxyLaunchAgent {
    private let service: SMAppService

    init(variant: AgentProxyPaths.Variant) {
        service = .agent(plistName: AgentProxyPaths.launchAgentPlistName(variant))
    }

    var state: AgentProxyLaunchAgentState {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
#endif
