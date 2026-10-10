#if os(macOS)
import Foundation
import Darwin
import Security

nonisolated struct PiSessionIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    let cwd: String
    let sessionID: String
    let sessionFile: String
    let leafID: String?
}

/// Provided by the app, never accepted from a Pi request.
nonisolated struct PiBridgeLaunch: Sendable {
    let id: String
    let owner: AgentPaneIdentity
    let node: String
    let entry: String
    let arguments: [String]
    let cwd: String
    let sessionID: String
    let sessionDirectory: String
    let helper: String
    let wrapper: String
    let bootstrap: String
    /// Only pinned Pi CLI startup may request this; never a client JSON option.
    var permitsPiTitleRewrite = false
}

/// Production must supply real admission/revocation/detach implementations.
/// No default browser provider or implicit "successful" cleanup exists.
@MainActor struct PiBridgeNativeLease {
    let descriptor: String
    let revoke: () -> Bool
    let close: () async throws -> Void
    let isQuiescent: () -> Bool
}

@MainActor final class PiHostBridge {
    private struct Registration {
        let launch: PiBridgeLaunch
        let capability: String
        var process: PiProcessIdentity?
        var lifetime: PiProcessLifetime?
        var retired = false
        var attempts = Set<String>()
    }
    private final class Entry {
        let launchID: String
        let identity: PiSessionIdentity
        let native: PiBridgeNativeLease
        var active = true
        var mcp: PiProcessIdentity?
        var mcpLifetime: PiProcessLifetime?
        var mcpReady = false
        var closing: Task<Bool, Never>?
        var closed = false
        init(launchID: String, identity: PiSessionIdentity, native: PiBridgeNativeLease) {
            self.launchID = launchID; self.identity = identity; self.native = native
        }
    }
    private struct Request: Decodable {
        let version: Int
        let launchID: String
        let capability: String
        let command: String
        let attemptID: String
        let identity: PiSessionIdentity?
        let state: String?
    }
    private var registrations: [String: Registration] = [:]
    private var entries: [String: Entry] = [:]
    private(set) var requestCount = 0
    private(set) var lastFailure: PiBridgeFailure?
    private let admit: (PiBridgeLaunch, PiProcessIdentity) -> Bool
    private let acquire: (PiBridgeLaunch, PiSessionIdentity, String) throws -> PiBridgeNativeLease
    private let inspect: (Int32) throws -> PiProcessIdentity
    private let reportState: ((PiBridgeLaunch, PiSessionIdentity, String) async throws -> Void)?

    init(inspect: @escaping (Int32) throws -> PiProcessIdentity = PiProcessIdentity.capture,
         admit: @escaping (PiBridgeLaunch, PiProcessIdentity) -> Bool,
         acquire: @escaping (PiBridgeLaunch, PiSessionIdentity, String) throws -> PiBridgeNativeLease,
         reportState: ((PiBridgeLaunch, PiSessionIdentity, String) async throws -> Void)? = nil) {
        self.inspect = inspect; self.admit = admit; self.acquire = acquire; self.reportState = reportState
    }

    var hasWork: Bool { entries.values.contains { !$0.closed } }

    /// Native app observation, not a claim supplied by an extension status event.
    func isMcpReady(launchID: String) -> Bool {
        guard let registration = registrations[launchID], !registration.retired, rootIsCurrent(registration) else { return false }
        return entries.values.contains { entry in
            entry.launchID == launchID && entry.active && entry.mcpReady && mcpIsCurrent(entry)
        }
    }

    /// This only registers an expectation. It does not authorize Pi until the
    /// app binds a kernel-inspected foreground process to this launch.
    func provision(_ launch: PiBridgeLaunch, socketPath: String) throws {
        guard registrations.count < 32, UUID(uuidString: launch.id) != nil, UUID(uuidString: launch.sessionID) != nil,
              registrations[launch.id] == nil, launch.owner.herdrMachineID == nil,
              [launch.node, launch.entry, launch.cwd, launch.sessionDirectory, launch.helper, launch.wrapper, launch.bootstrap, socketPath].allSatisfy(Self.absolute),
              launch.arguments.allSatisfy({ !$0.utf8.contains(0) }) else { throw PiBridgeFailure.invalidRequest }
        let directory = URL(fileURLWithPath: launch.bootstrap).deletingLastPathComponent()
        try Self.privateDirectory(directory.path)
        try Self.privateDirectory(launch.sessionDirectory)
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw PiBridgeFailure.unavailable }
        let capability = Data(random).base64EncodedString()
        let payload: [String: Any] = ["version":1,"launchID":launch.id,"capability":capability,"socketPath":socketPath,
                                     "node":launch.node,"helper":launch.helper,"herdrReporting":reportState != nil]
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let fd = Darwin.open(launch.bootstrap, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PiBridgeFailure.conflict }
        defer { Darwin.close(fd) }
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { try? FileManager.default.removeItem(atPath: launch.bootstrap); throw PiBridgeFailure.unavailable }
        registrations[launch.id] = Registration(launch: launch, capability: capability)
    }

    func bindProcess(launchID: String, pid: Int32) throws {
        guard var registration = registrations[launchID], !registration.retired, registration.process == nil else { throw PiBridgeFailure.conflict }
        let lifetime = try PiProcessLifetime(pid: pid)
        let proof = try inspect(pid), launch = registration.launch
        guard proof.matches(node: launch.node, entry: launch.entry, tail: launch.arguments, cwd: launch.cwd),
              admit(launch, proof), try inspect(pid) == proof, lifetime.isUnchanged() else { throw PiBridgeFailure.identity }
        registration.process = proof; registration.lifetime = lifetime; registrations[launchID] = registration
    }

    /// peerPID comes from LOCAL_PEERPID, never a JSON field. Every operation
    /// rechecks the original PID/start/executable/argv and trusted pane admission.
    func receive(peerPID: Int32, data: Data) async -> Data {
        requestCount += 1
        do {
            guard data.count <= 32768,
                  let request = try? JSONDecoder().decode(Request.self, from: data), request.version == 1,
                  UUID(uuidString: request.attemptID) != nil,
                  var registration = registrations[request.launchID], !registration.retired,
                  Self.sameSecret(request.capability, registration.capability) else { throw PiBridgeFailure.denied }
            // Startup may reach IPC before the app's foreground-process proof.
            // This response guarantees that no lease/attempt has been allocated.
            guard let process = registration.process else { throw PiBridgeFailure.notBound }
            let launch = registration.launch
            guard rootIsCurrent(registration) else {
                retire(launchID: launch.id)
                throw PiBridgeFailure.identity
            }
            let peerLifetime = request.command == "mcpAttach" ? try PiProcessLifetime(pid: peerPID) : nil
            let peer = try inspect(peerPID)
            let root = peer.pid == process.pid && (peer == process || (launch.permitsPiTitleRewrite && peer.isSameInstance(afterPiTitleRewrite: process)))
            let helper = peer.parentPID == process.pid && peer.matches(node: launch.node, entry: launch.helper,
                tail: [launch.bootstrap], cwd: launch.cwd)
            let key = launch.id + "/" + request.attemptID
            switch request.command {
            case "herdrState":
                guard root, let reportState, let identity = request.identity, let state = request.state,
                      ["idle", "working", "blocked"].contains(state), Self.matches(identity, launch: launch, process: process) else { throw PiBridgeFailure.denied }
                try await reportState(launch, identity, state)
                guard let latest = registrations[launch.id], !latest.retired, rootIsCurrent(latest) else { throw PiBridgeFailure.identity }
                return Self.reply(["ok":true])
            case "boot":
                guard root, registration.attempts.isEmpty else { throw PiBridgeFailure.denied }
                return Self.reply(["ok":true])
            case "open":
                guard root, let identity = request.identity, Self.matches(identity, launch: launch, process: process),
                      !registration.attempts.contains(request.attemptID), registration.attempts.count < 128,
                      !entries.values.contains(where: { $0.launchID == launch.id && !$0.closed }) else { throw PiBridgeFailure.conflict }
                registration.attempts.insert(request.attemptID); registrations[launch.id] = registration
                let native = try acquire(launch, identity, request.attemptID)
                let entry = Entry(launchID: launch.id, identity: identity, native: native)
                entries[key] = entry
                guard Self.absolute(native.descriptor), rootIsCurrent(registration) else {
                    _ = await close(entry)
                    throw entry.closed ? PiBridgeFailure.identity : PiBridgeFailure.cleanupUnconfirmed
                }
                return Self.reply(["ok":true,"mcp":["command":launch.node,"args":[launch.wrapper,native.descriptor]]])
            case "revoke":
                guard root || helper else { throw PiBridgeFailure.denied }
                // A tombstone also cancels an open whose reply was lost, or an
                // open not yet processed. Never recycle attempt IDs.
                guard registration.attempts.contains(request.attemptID) || registration.attempts.count < 128 else { throw PiBridgeFailure.conflict }
                registration.attempts.insert(request.attemptID); registrations[launch.id] = registration
                let revoked = entries[key].map(revoke) ?? true
                return Self.reply(["ok":revoked])
            case "close":
                guard root || helper else { throw PiBridgeFailure.denied }
                guard let entry = entries[key] else {
                    guard registration.attempts.contains(request.attemptID) else { throw PiBridgeFailure.denied }
                    return Self.reply(["ok":true])
                }
                return Self.reply(["ok":await close(entry)])
            case "mcpAttach", "mcpReady":
                guard let entry = entries[key], entry.active,
                      peer.parentPID == process.pid,
                      peer.matches(node: launch.node, entry: launch.wrapper, tail: [entry.native.descriptor], cwd: launch.cwd),
                      entry.mcp == nil || (entry.mcp == peer && mcpIsCurrent(entry)) else { throw PiBridgeFailure.identity }
                if entry.mcp == nil {
                    guard let peerLifetime, peerLifetime.isUnchanged(), try inspect(peerPID) == peer else { throw PiBridgeFailure.identity }
                    entry.mcpLifetime = peerLifetime
                }
                if request.command == "mcpReady" {
                    guard entry.mcp == peer else { throw PiBridgeFailure.denied }
                    entry.mcpReady = true
                }
                entry.mcp = peer
                return Self.reply(["ok":true])
            case "status":
                guard root, let entry = entries[key], entry.active else { throw PiBridgeFailure.denied }
                let live = mcpIsCurrent(entry)
                let ready = live && entry.mcpReady
                if entry.mcp != nil && !live { _ = revoke(entry) }
                return Self.reply(["ok":true,"ready":ready,"quiescent":ready && entry.native.isQuiescent()])
            default: throw PiBridgeFailure.invalidRequest
            }
        } catch {
            // Neither OS diagnostics, argv, native errors nor capability values escape.
            let failure = (error as? PiBridgeFailure) ?? .unavailable
            lastFailure = failure
            return Self.reply(["ok":false,"error":failure.rawValue])
        }
    }

    private func revoke(_ entry: Entry) -> Bool {
        entry.active = false; entry.mcpReady = false
        return entry.native.revoke()
    }
    private func close(_ entry: Entry) async -> Bool {
        if let closing = entry.closing { return await closing.value }
        let revoked = revoke(entry)
        let task = Task { @MainActor in
            do {
                try await entry.native.close()
                let deadline = ContinuousClock().now.advanced(by: .seconds(6))
                while self.mcpIsCurrent(entry) {
                    guard ContinuousClock().now < deadline else { return false }
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard revoked else { return false }
                entry.closed = true; entry.mcpLifetime = nil; return true
            } catch { return false }
        }
        entry.closing = task
        return await task.value
    }
    func retire(launchID: String) {
        registrations[launchID]?.retired = true
        registrations[launchID]?.lifetime = nil
        // Retire before any await. Physical/native cleanup is still tracked.
        for entry in entries.values where entry.launchID == launchID && !entry.closed {
            _ = revoke(entry)
            Task { @MainActor in _ = await self.close(entry) }
        }
    }
    func sweep() {
        for (id, registration) in registrations where !registration.retired && registration.process != nil {
            if !rootIsCurrent(registration) { retire(launchID: id) }
        }
        for entry in entries.values where entry.active {
            if entry.mcp != nil && !mcpIsCurrent(entry) {
                _ = revoke(entry)
                Task { @MainActor in _ = await self.close(entry) }
            }
        }
    }
    func stop() async -> Bool {
        for id in Array(registrations.keys) { retire(launchID: id) }
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while hasWork && ContinuousClock().now < deadline {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        }
        // Failed/late detach remains retained and visible as work, not discarded.
        return !hasWork
    }

    private func mcpIsCurrent(_ entry: Entry) -> Bool {
        guard let proof = entry.mcp, let lifetime = entry.mcpLifetime, lifetime.isUnchanged(),
              (try? inspect(proof.pid)) == proof, lifetime.isUnchanged() else { return false }
        return true
    }

    private func rootIsCurrent(_ registration: Registration) -> Bool {
        guard let original = registration.process, let lifetime = registration.lifetime, lifetime.isUnchanged(),
              let current = try? inspect(original.pid),
              current == original || (registration.launch.permitsPiTitleRewrite && current.isSameInstance(afterPiTitleRewrite: original)),
              admit(registration.launch, original), lifetime.isUnchanged() else { return false }
        return true
    }

    private static func matches(_ identity: PiSessionIdentity, launch: PiBridgeLaunch, process: PiProcessIdentity) -> Bool {
        guard identity.pid == process.pid, identity.sessionID == launch.sessionID, absolute(identity.cwd),
              PiProcessIdentity.canonical(identity.cwd) == process.cwd,
              absolute(identity.sessionFile), identity.leafID.map({ $0.count <= 128 && !$0.utf8.contains(0) }) ?? true else { return false }
        let file = URL(fileURLWithPath: identity.sessionFile)
        // The app supplies the persistent session directory; no fuzzy lookup,
        // cross-project fallback, file creation or conversation reads occur here.
        return PiProcessIdentity.canonical(file.deletingLastPathComponent().path) == PiProcessIdentity.canonical(launch.sessionDirectory) &&
            file.pathExtension == "jsonl" && file.lastPathComponent.hasSuffix("_" + launch.sessionID + ".jsonl")
    }
    private static func absolute(_ value: String) -> Bool { value.hasPrefix("/") && !value.utf8.contains(0) }
    private static func privateDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else { throw PiBridgeFailure.denied }
    }
    private static func sameSecret(_ supplied: String, _ expected: String) -> Bool {
        let a = Array(supplied.utf8), b = Array(expected.utf8)
        guard a.count == b.count, b.count == 44 else { return false }
        return zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func reply(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8) }
}
#endif
