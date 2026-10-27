import Foundation
import Crypto
import AgentProxyProtocol

/// The routes the app has made, one per agent the launcher started through
/// the proxy. A route is found by its token's SHA-256; the token itself is
/// given out once, in the `routes.create` answer, and kept nowhere.
/// `routes.json` (0600) has the hashes and what the app said about the pane,
/// so routes outlive a restart of the proxy.
///
/// Used on the proxy's event loop only.
final class RouteTable {
    struct Entry {
        let routeID: String
        let tokenHash: String
        let kind: AgentProxyRouteKind
        let session: String
        let paneID: String
        let terminalID: String
        let cliVersion: String
        let createdAt: String
        var oauthRejected: Bool
    }

    private struct Stored: Codable {
        var version = 1
        var routes: [StoredRoute]
    }

    private struct StoredRoute: Codable {
        let routeID: String
        let tokenSHA256: String
        let kind: AgentProxyRouteKind
        let session: String
        let paneID: String
        let terminalID: String
        let cliVersion: String
        let createdAt: String
        let oauthRejected: Bool
    }

    static let fileName = "routes.json"
    static let maximumRoutes = 1024

    private let directory: StateDirectory
    private var byHash: [String: Entry] = [:]
    private var order: [String] = []
    private(set) var inFlight: [String: Int] = [:]
    /// Invoked on the owning proxy loop only, after a committed mutation.
    var onAuthorityChanged: (() -> Void)?

    init(directory: StateDirectory, log: (String) -> Void) {
        self.directory = directory
        do {
            if let data = try directory.read(Self.fileName) {
                let stored = try JSONDecoder().decode(Stored.self, from: data)
                for route in stored.routes where byHash[route.tokenSHA256] == nil {
                    byHash[route.tokenSHA256] = Entry(routeID: route.routeID, tokenHash: route.tokenSHA256, kind: route.kind,
                                                      session: route.session, paneID: route.paneID, terminalID: route.terminalID,
                                                      cliVersion: route.cliVersion, createdAt: route.createdAt,
                                                      oauthRejected: route.oauthRejected)
                    order.append(route.tokenSHA256)
                }
            }
        } catch {
            // Starting without them only means those agents' requests are
            // forwarded without a copy; the file is written anew on the next
            // change.
            log("routes: \(Self.fileName) could not be read; starting with none")
        }
    }

    var count: Int { order.count }

    func lookup(token: String) -> Entry? { byHash[Self.hash(token)] }

    func create(_ request: AgentProxyRouteCreate) throws -> (entry: Entry, token: String) {
        for field in [request.session, request.paneID, request.terminalID, request.cliVersion] {
            guard field.utf8.count <= AgentProxyControl.maximumFieldBytes,
                  !field.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw AgentProxyControlError(code: .invalidParams, message: "A field is too long or has control characters.")
            }
        }
        guard order.count < Self.maximumRoutes else {
            throw AgentProxyControlError(code: .unavailable, message: "Too many routes; remove the ones whose panes are gone.")
        }
        var generator = SystemRandomNumberGenerator()
        let token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let entry = Entry(routeID: UUID().uuidString.lowercased(), tokenHash: Self.hash(token), kind: request.kind,
                          session: request.session, paneID: request.paneID, terminalID: request.terminalID,
                          cliVersion: request.cliVersion, createdAt: formatter.string(from: Date()), oauthRejected: false)
        byHash[entry.tokenHash] = entry
        order.append(entry.tokenHash)
        do { try save() } catch {
            byHash[entry.tokenHash] = nil
            order.removeLast()
            throw AgentProxyControlError(code: .unavailable, message: "The route could not be saved.")
        }
        onAuthorityChanged?()
        return (entry, token)
    }

    func remove(routeID: String) throws -> Bool {
        guard let hash = order.first(where: { byHash[$0]?.routeID == routeID }) else { return false }
        let entry = byHash.removeValue(forKey: hash)
        order.removeAll { $0 == hash }
        do { try save() } catch {
            byHash[hash] = entry
            order.append(hash)
            throw AgentProxyControlError(code: .unavailable, message: "The routes could not be saved.")
        }
        onAuthorityChanged?()
        return true
    }

    /// A request of this route was not signed in with a subscription.
    func markRejected(routeID: String, log: (String) -> Void) {
        guard let hash = order.first(where: { byHash[$0]?.routeID == routeID }), byHash[hash]?.oauthRejected == false else { return }
        byHash[hash]?.oauthRejected = true
        do { try save() } catch { log("routes: \(Self.fileName) could not be written") }
        onAuthorityChanged?()
    }

    /// Non-secret current identities only. Rejecting an OAuth route also
    /// revokes its authority, even if recording the rejection failed.
    func recorderAuthority() -> [AgentProxyTeeFrame.RouteSnapshot.Route] {
        order.compactMap { byHash[$0] }.filter { !$0.oauthRejected }.map {
            .init(routeID: $0.routeID,
                  identity: .init(kind: $0.kind, session: $0.session, paneID: $0.paneID,
                                  terminalID: $0.terminalID, cliVersion: $0.cliVersion))
        }
    }

    func began(routeID: String) { inFlight[routeID, default: 0] += 1 }

    func ended(routeID: String) {
        let left = (inFlight[routeID] ?? 1) - 1
        inFlight[routeID] = left > 0 ? left : nil
    }

    func list() -> [AgentProxyRoute] {
        order.compactMap { byHash[$0] }.map {
            AgentProxyRoute(routeID: $0.routeID, kind: $0.kind, session: $0.session, paneID: $0.paneID,
                            terminalID: $0.terminalID, cliVersion: $0.cliVersion, createdAt: $0.createdAt,
                            oauthRejected: $0.oauthRejected, inFlight: inFlight[$0.routeID] ?? 0)
        }
    }

    private func save() throws {
        let stored = Stored(routes: order.compactMap { byHash[$0] }.map {
            StoredRoute(routeID: $0.routeID, tokenSHA256: $0.tokenHash, kind: $0.kind, session: $0.session,
                        paneID: $0.paneID, terminalID: $0.terminalID, cliVersion: $0.cliVersion,
                        createdAt: $0.createdAt, oauthRejected: $0.oauthRejected)
        })
        try directory.write(Self.fileName, try AgentProxyControl.encoder.encode(stored))
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
