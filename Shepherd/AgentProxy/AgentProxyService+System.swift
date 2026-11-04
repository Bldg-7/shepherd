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

    /// Legacy capture route liveness is unknown across the backend change.
    /// Nil preserves existing routes without making a legacy backend request.
    /// A missing ID in the new core is not proof an old program died.
    static func liveTerminals(session: String) async -> Set<String>? {
        // Existing capture routes were minted by the old injected launch
        // runtime. Absence from a NEW core cannot establish that those old
        // programs died. Do not query herdr or revoke their proxy credentials
        // by comparing incompatible identity namespaces. Explicit user revoke
        // remains available; this does not mint browser/native authority or
        // automatically configure capture for newly launched hc terminals.
        return nil
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
