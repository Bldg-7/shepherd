#if os(macOS)
import Foundation
import Darwin

/// Composition with the real pane proxy, not a fake successful native lease.
@MainActor final class PiBrowserLeaseProvider {
    private let proxy: CDPProxy
    private let claim: CDPRouteLeases.Claim
    private let directory: URL
    private let preferences: AgentRuntimePreferences

    init(proxy: CDPProxy, claim: CDPRouteLeases.Claim, directory: URL, preferences: AgentRuntimePreferences) {
        self.proxy = proxy; self.claim = claim; self.directory = directory; self.preferences = preferences
    }
    func acquire(launch: PiBridgeLaunch, identity: PiSessionIdentity, attempt: String) throws -> PiBridgeNativeLease {
        guard UUID(uuidString: attempt) != nil, launch.owner.terminalID == claim.terminalID,
              launch.owner.session == claim.route.session, launch.owner.paneID == claim.route.pane else { throw PiBridgeFailure.identity }
        var parent = stat()
        guard lstat(directory.path, &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR,
              parent.st_uid == getuid(), (parent.st_mode & 0o077) == 0 else { throw PiBridgeFailure.denied }
        let endpoint = try proxy.openRoute(claim)
        let route = CDPRoute(endpoint.path)!
        do {
            let folder = directory.appendingPathComponent(attempt, isDirectory: true)
            guard mkdir(folder.path, 0o700) == 0 else { throw PiBridgeFailure.conflict }
            let output = folder.appendingPathComponent("output", isDirectory: true)
            guard mkdir(output.path, 0o700) == 0 else { throw PiBridgeFailure.conflict }
            let browser = folder.appendingPathComponent("browser.json"), wrapper = folder.appendingPathComponent("mcp.json")
            let pane = try JSONSerialization.jsonObject(with: JSONEncoder().encode(launch.owner))
            try Self.write(["pane":pane,"endpoint":["origin":"thisMac","url":endpoint.url.absoluteString,"tokenFile":endpoint.tokenFile.path],
                            "outputFolder":output.path,"outputMaxSize":preferences.outputMaxSize,
                            "allowedOrigins":preferences.allowedOrigins,"blockedOrigins":preferences.blockedOrigins], to: browser)
            try Self.write(["piBridge":["bootstrap":launch.bootstrap,"attemptID":attempt],"browserDescriptor":browser.path], to: wrapper)
            return PiBridgeNativeLease(descriptor: wrapper.path,
                revoke: { [proxy] in proxy.revokeRoute(route); return true },
                close: { [proxy] in try await proxy.closeRoute(route) },
                isQuiescent: { [proxy] in proxy.routeIsQuiescent(route) })
        } catch {
            proxy.revokeRoute(route)
            throw error
        }
    }
    func retire() { proxy.retireRoute(claim) }
    func releaseAfterHostCleanup() throws { try proxy.releaseRoute(claim) }

    static func write(_ value: [String: Any], to file: URL) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PiBridgeFailure.conflict }
        defer { Darwin.close(fd) }
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { throw PiBridgeFailure.unavailable }
    }
}
#endif
