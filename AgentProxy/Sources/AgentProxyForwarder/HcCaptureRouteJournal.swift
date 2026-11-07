import Foundation
import Crypto
import Darwin
import AgentProxyProtocol

/// Serialized, durable hc route provenance only. The owning loop publishes
/// acknowledged metadata through the tagged registry; peer-verified hc control
/// never fabricates legacy identity or proves a provider-native session.
final class HcCaptureRouteJournal {
    struct Entry: Codable, Equatable {
        let routeID: UUID
        let tokenSHA256: String
        var state: AgentProxyHcRouteState
        var oauthRejected: Bool
        init(routeID: UUID, tokenSHA256: String, state: AgentProxyHcRouteState, oauthRejected: Bool = false) {
            self.routeID = routeID; self.tokenSHA256 = tokenSHA256; self.state = state; self.oauthRejected = oauthRejected
        }
        private enum Keys: String, CodingKey { case routeID,tokenSHA256,state,oauthRejected }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy:Keys.self)
            self.init(routeID:try c.decode(UUID.self,forKey:.routeID),tokenSHA256:try c.decode(String.self,forKey:.tokenSHA256),
                      state:try c.decode(AgentProxyHcRouteState.self,forKey:.state),oauthRejected:try c.decodeIfPresent(Bool.self,forKey:.oauthRejected) ?? false)
        }
    }
    enum Failure: Error { case unavailable, invalidStore, limit, duplicateLaunch, unknownRoute }
    private struct Stored: Codable { let schemaVersion: Int; let entries: [Entry] }
    private struct LaunchKey: Hashable {
        let core: String; let launch: UUID
        init(_ intent: AgentProxyHcCaptureIntent) { core = intent.originCoreID; launch = intent.launchID }
    }
    static let filename = "hc-routes.json"
    static let maximumEntries = 512
    static let maximumBytes = 1 << 20
    private var entries: [Entry]
    private var healthy = true
    private var committing = false
    private let persist: (Data) throws -> Void

    convenience init(directory: StateDirectory) throws {
        try self.init(restoring:directory.read(Self.filename,limit:Self.maximumBytes),persist:{ data in
            try directory.write(Self.filename,data)
            // Confirm the renamed file's directory entry too. Failure may be
            // post-commit: the journal latches unavailable, never retries it.
            let fd = open(directory.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw Failure.unavailable }
        })
    }
    init(restoring: Data?, persist: @escaping (Data) throws -> Void) throws {
        self.persist = persist
        guard let restoring else { entries = []; return }
        guard restoring.count <= Self.maximumBytes,
              let stored = try? JSONDecoder().decode(Stored.self,from:restoring), stored.schemaVersion == 1,
              stored.entries.count <= Self.maximumEntries else { throw Failure.invalidStore }
        var ids = Set<UUID>(), hashes = Set<String>(), intents = Set<LaunchKey>()
        for entry in stored.entries {
            guard entry.tokenSHA256.utf8.count == 64,
                  entry.tokenSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  ids.insert(entry.routeID).inserted, hashes.insert(entry.tokenSHA256).inserted,
                  intents.insert(LaunchKey(entry.state.intent)).inserted else { throw Failure.invalidStore }
        }
        entries = stored.entries
    }
    private static func hash(_ token: String) -> String {
        SHA256.hash(data:Data(token.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func commit(_ proposed: [Entry]) throws {
        guard healthy, !committing else { throw Failure.unavailable }
        committing = true; defer { committing = false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Stored(schemaVersion:1,entries:proposed))
        guard data.count <= Self.maximumBytes else { throw Failure.limit }
        do { try persist(data) }
        catch { healthy = false; throw Failure.unavailable }
        entries = proposed
    }
    func create(_ state: AgentProxyHcRouteState) throws -> (entry: Entry, token: String) {
        guard healthy, !committing else { throw Failure.unavailable }
        guard state.binding == nil else { throw Failure.invalidStore }
        guard entries.count < Self.maximumEntries else { throw Failure.limit }
        guard !entries.contains(where:{ LaunchKey($0.state.intent) == LaunchKey(state.intent) }) else { throw Failure.duplicateLaunch }
        var random = SystemRandomNumberGenerator()
        let token = (0..<16).map { _ in String(format:"%02x",UInt8.random(in:0...255,using:&random)) }.joined()
        let entry = Entry(routeID:UUID(),tokenSHA256:Self.hash(token),state:state)
        guard !entries.contains(where:{ $0.routeID == entry.routeID || $0.tokenSHA256 == entry.tokenSHA256 }) else { throw Failure.unavailable }
        try commit(entries + [entry])
        return (entry,token) // secret leaves only after durable acknowledgement
    }
    func bind(routeID: UUID, received: AgentProxyHcCaptureBinding) throws {
        guard healthy, !committing else { throw Failure.unavailable }
        guard let index = entries.firstIndex(where:{ $0.routeID == routeID }) else { throw Failure.unknownRoute }
        var proposed = entries
        try proposed[index].state.bind(received)
        try commit(proposed)
    }
    func markRejected(routeID: UUID) throws {
        guard healthy, !committing else { throw Failure.unavailable }
        guard let index = entries.firstIndex(where:{ $0.routeID == routeID }) else { throw Failure.unknownRoute }
        guard !entries[index].oauthRejected else { return }
        var proposed = entries; proposed[index].oauthRejected = true
        try commit(proposed)
    }
    func remove(routeID: UUID) throws {
        guard healthy, !committing else { throw Failure.unavailable }
        guard entries.contains(where:{ $0.routeID == routeID }) else { throw Failure.unknownRoute }
        try commit(entries.filter { $0.routeID != routeID })
    }
    func snapshot() throws -> [Entry] { guard healthy else { throw Failure.unavailable }; return entries }
    func lookup(token: String) throws -> Entry? {
        guard healthy else { throw Failure.unavailable }
        guard token.utf8.count == 32,token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let hash = Self.hash(token)
        return entries.first { $0.tokenSHA256 == hash }
    }
}
