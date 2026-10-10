#if os(macOS)
import Foundation
import CFNetwork

// The native integration must prove the ORIGINAL context has no custom proxy,
// and only enable on local routes. A system policy error never means DIRECT.
nonisolated struct CredentialProxyNetworkPolicy: Sendable {
    let isDirect: @Sendable (URL) -> Bool

    static let system = CredentialProxyNetworkPolicy { url in
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]],
              proxies.count == 1,
              proxies[0][kCFProxyTypeKey as String] as? String == kCFProxyTypeNone as String else { return false }
        return true
    }
}

nonisolated final class CredentialProxyRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let policy: CredentialProxyNetworkPolicy
    let destinations: [CredentialDestination]
    let tunnelAuthorities: Set<String>
    let profileID: String
    let authorization: String
    let username: String
    let password: String

    init(profileID: String, local: Bool, originalContextDirect: Bool,
         destinations: [CredentialDestination], tunnelAuthorities: Set<String>,
         policy: CredentialProxyNetworkPolicy = .system) throws {
        guard local, originalContextDirect, !profileID.isEmpty,
              !destinations.isEmpty, destinations.count <= 32, tunnelAuthorities.count <= 128 else { throw CredentialBrokerError.unsupported }
        for authority in tunnelAuthorities { _ = try CredentialProxyHTTP.authority(authority) }
        self.profileID = profileID; self.destinations = destinations
        self.tunnelAuthorities = tunnelAuthorities; self.policy = policy
        username = try credentialOpaqueID(); password = try credentialOpaqueID()
        authorization = "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
        for d in destinations { try check(host: d.host, port: d.effectivePort) }
        for a in tunnelAuthorities {
            let parsed = try CredentialProxyHTTP.authority(a)
            try check(host: parsed.host, port: parsed.port)
        }
    }

    func revoke() { lock.lock(); active = false; lock.unlock() }

    func check(host: String, port: Int) throws {
        lock.lock(); let valid = active; lock.unlock()
        let authority = host + ":" + String(port)
        guard valid, destinations.contains(where: { $0.host == host && $0.effectivePort == port }) || tunnelAuthorities.contains(authority),
              let url = URL(string: "https://" + authority + "/"), policy.isDirect(url) else { throw CredentialBrokerError.unsupported }
        lock.lock(); let stillValid = active; lock.unlock()
        guard stillValid else { throw CredentialBrokerError.cancelled }
    }

    // Revocation and the synchronous secret-write start serialize here. Once a
    // write starts it is not rollback; teardown aborts its owned socket.
    func withWrite(host: String, port: Int, _ write: () throws -> Void) throws {
        try check(host: host, port: port)
        lock.lock(); defer { lock.unlock() }
        guard active else { throw CredentialBrokerError.cancelled }
        try write()
    }

    func destination(authority: String, path: String) throws -> CredentialDestination {
        let matches = destinations.filter { $0.host + ":" + String($0.effectivePort) == authority && $0.path + ($0.query.map { "?" + $0 } ?? "") == path }
        guard matches.count == 1 else { throw CredentialBrokerError.denied }
        return matches[0]
    }
}
#endif
