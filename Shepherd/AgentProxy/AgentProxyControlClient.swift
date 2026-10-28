#if os(macOS)
import Darwin
import Foundation

/// What the app asks the agent proxy over its control socket, `ap.sock`
/// (`AgentProxyControl`). A stand-in takes the socket's place in view tests.
nonisolated protocol AgentProxyControlling: Sendable {
    func status() async throws -> AgentProxyStatus
    func restartWhenIdle() async throws -> AgentProxyRestartWhenIdle
    func createRoute(_ request: AgentProxyRouteCreate) async throws -> AgentProxyRouteCreated
    func removeRoute(_ routeID: String) async throws -> Bool
    func listRoutes() async throws -> [AgentProxyRoute]
    func clearSavedHistory() async throws
    func historyStatus() async throws -> AgentProxyHistoryStatus
}

extension AgentProxyControlling {
    func clearSavedHistory() async throws { throw AgentProxyControlFailure.unreachable }
    func historyStatus() async throws -> AgentProxyHistoryStatus { throw AgentProxyControlFailure.unreachable }
}

nonisolated enum AgentProxyControlFailure: Error, Equatable, CustomStringConvertible {
    /// Nothing listens on the socket: the proxy isn't running.
    case unreachable
    case timedOut
    /// An answer that isn't one line of the protocol, or answers another request.
    case malformed
    /// The proxy turned the request down.
    case refused(AgentProxyControlError)

    var description: String {
        switch self {
        case .unreachable: "the agent proxy isn't running"
        case .timedOut: "the agent proxy didn't answer in time"
        case .malformed: "the agent proxy's answer couldn't be read"
        case .refused(let error): "the agent proxy refused: \(error.code)"
        }
    }
}

/// `ap.sock` itself: a connection for each request, its line out and one line
/// back, each way within `timeout`. Blocking reads and writes, on a queue of
/// their own rather than the caller's.
nonisolated struct AgentProxyControlClient: AgentProxyControlling {
    let socketPath: String
    var timeout: TimeInterval = 3
    /// Larger than any answer the proxy gives (its route list included).
    static let maximumAnswerBytes = 8 * 1024 * 1024

    func status() async throws -> AgentProxyStatus {
        try await call(.status, EmptyParams(), as: AgentProxyStatus.self)
    }

    func restartWhenIdle() async throws -> AgentProxyRestartWhenIdle {
        try await call(.restartWhenIdle, EmptyParams(), as: AgentProxyRestartWhenIdle.self)
    }

    func createRoute(_ request: AgentProxyRouteCreate) async throws -> AgentProxyRouteCreated {
        try await call(.routesCreate, request, as: AgentProxyRouteCreated.self)
    }

    func removeRoute(_ routeID: String) async throws -> Bool {
        try await call(.routesRemove, AgentProxyRouteRemove(routeID: routeID), as: AgentProxyRouteRemoved.self).removed
    }

    func listRoutes() async throws -> [AgentProxyRoute] {
        try await call(.routesList, EmptyParams(), as: AgentProxyRouteList.self).routes
    }

    func clearSavedHistory() async throws {
        let result = try await call(.clearHistory, AgentProxyHistoryClearRequest(confirmed: true), as: AgentProxyHistoryCleared.self)
        guard result.cleared else { throw AgentProxyControlFailure.malformed }
    }

    func historyStatus() async throws -> AgentProxyHistoryStatus {
        let id = "app_" + UUID().uuidString.prefix(8).lowercased()
        struct Request: Encodable { let id: String; let method = "persistence.status" }
        var line = try AgentProxyControl.encoder.encode(Request(id: id)); line.append(0x0A)
        let path = AgentProxyPaths.recorderSocket(forControlSocket: socketPath), timeout = timeout
        let request = line
        let answer: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Swift.Result { try Self.exchange(request, path: path, timeout: timeout) })
            }
        }
        guard let response = try? AgentProxyControl.decodeResponse(answer, as: AgentProxyHistoryStatus.self),
              response.id == id, response.error == nil, let result = response.result,
              ["off", "volatile", "healthy", "degraded"].contains(result.mode),
              (0...256).contains(result.blockedConversations), (0...256).contains(result.historicalConflicts) else {
            throw AgentProxyControlFailure.malformed
        }
        return result
    }

    private func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: AgentProxyControl.Method, _ params: Params, as type: Result.Type) async throws -> Result {
        let id = "app_" + UUID().uuidString.prefix(8).lowercased()
        let line = try AgentProxyControl.requestLine(id: id, method: method, params: params)
        let path = socketPath, timeout = timeout
        let answer: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Swift.Result { try Self.exchange(line, path: path, timeout: timeout) })
            }
        }
        let response: ResponseEnvelope<Result>
        do { response = try AgentProxyControl.decodeResponse(answer, as: Result.self) }
        catch { throw AgentProxyControlFailure.malformed }
        guard response.id == id else { throw AgentProxyControlFailure.malformed }
        if let error = response.error { throw AgentProxyControlFailure.refused(error) }
        guard let result = response.result else { throw AgentProxyControlFailure.malformed }
        return result
    }

    /// Launch only the bundled maintenance executable with explicit paths and
    /// an empty environment. A timed-out child is signalled only while still
    /// our unreaped child, so its PID cannot have been reused.
    static func clearOffline(executable: String, stateDirectory: String, socketPath: String) async throws {
        guard geteuid() != 0, executable.hasPrefix("/"), stateDirectory.hasPrefix("/"), AgentProxyPaths.socketPathFits(socketPath) else {
            throw AgentProxyControlFailure.unreachable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Swift.Result {
                    var actions: posix_spawn_file_actions_t?
                    var attributes: posix_spawnattr_t?
                    guard posix_spawn_file_actions_init(&actions) == 0 else { throw AgentProxyControlFailure.unreachable }
                    guard posix_spawnattr_init(&attributes) == 0 else { posix_spawn_file_actions_destroy(&actions); throw AgentProxyControlFailure.unreachable }
                    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
                    for fd: Int32 in [0, 1, 2] {
                        guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0 else { throw AgentProxyControlFailure.unreachable }
                    }
                    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw AgentProxyControlFailure.unreachable }
                    let args = [executable, "storage-owner", "--maintenance-clear", "--confirmed", "--state-dir", stateDirectory, "--socket", socketPath].map { strdup($0) } + [nil]
                    let environment: [UnsafeMutablePointer<CChar>?] = [nil]
                    defer { args.forEach { free($0) } }
                    guard args.dropLast().allSatisfy({ $0 != nil }) else { throw AgentProxyControlFailure.unreachable }
                    var child: pid_t = 0
                    guard posix_spawn(&child, executable, &actions, &attributes, args, environment) == 0 else { throw AgentProxyControlFailure.unreachable }
                    let deadline = ProcessInfo.processInfo.systemUptime + 3
                    var status: Int32 = 0
                    while true {
                        let waited = waitpid(child, &status, WNOHANG)
                        if waited == child {
                            guard status == 0 else { throw AgentProxyControlFailure.refused(.init(code: .unavailable, message: "Clear unavailable or incomplete.")) }
                            return
                        }
                        if waited < 0 && errno != EINTR { throw AgentProxyControlFailure.unreachable }
                        if ProcessInfo.processInfo.systemUptime >= deadline { break }
                        usleep(20_000)
                    }
                    // At this point waitpid has not reaped the owned child.
                    _ = kill(child, SIGKILL)
                    let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 1
                    var reaped = false
                    while ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                        let waited = waitpid(child, &status, WNOHANG)
                        if waited == child || (waited < 0 && errno != EINTR) { reaped = true; break }
                        usleep(20_000)
                    }
                    if !reaped {
                        // The caller stays bounded. A stuck owned child retains
                        // admission until exit; reap it if the kernel later ends it.
                        let reapPID = child
                        DispatchQueue.global(qos: .utility).async {
                            var ignored: Int32 = 0
                            while waitpid(reapPID, &ignored, 0) < 0 && errno == EINTR {}
                        }
                    }
                    throw AgentProxyControlFailure.timedOut
                })
            }
        }
    }

    /// One request line out and the answer's line back, without its newline.
    static func exchange(_ line: Data, path: String, timeout: TimeInterval) throws -> Data {
        guard AgentProxyPaths.socketPathFits(path), geteuid() != 0 else { throw AgentProxyControlFailure.unreachable }
        let folder = (path as NSString).deletingLastPathComponent
        var parent = stat(), before = stat()
        guard lstat(folder, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == geteuid(), parent.st_mode & 0o022 == 0,
              lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFSOCK,
              before.st_uid == geteuid(), before.st_mode & 0o077 == 0 else { throw AgentProxyControlFailure.unreachable }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentProxyControlFailure.unreachable }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw AgentProxyControlFailure.unreachable }
        var peerUID: uid_t = 0, peerGID: gid_t = 0, after = stat()
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == geteuid(),
              lstat(path, &after) == 0, after.st_mode & S_IFMT == S_IFSOCK,
              after.st_uid == geteuid(), after.st_mode & 0o077 == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino else { throw AgentProxyControlFailure.unreachable }
        var sent = 0
        while sent < line.count {
            let count = line.withUnsafeBytes { write(descriptor, $0.baseAddress! + sent, line.count - sent) }
            if count > 0 { sent += count; continue }
            if count < 0 && errno == EINTR { continue }
            throw (errno == EAGAIN || errno == EWOULDBLOCK) ? AgentProxyControlFailure.timedOut : AgentProxyControlFailure.unreachable
        }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if let newline = buffer[0..<count].firstIndex(of: 0x0A) {
                    answer.append(contentsOf: buffer[0..<newline])
                    return answer
                }
                answer.append(contentsOf: buffer[0..<count])
                guard answer.count <= maximumAnswerBytes else { throw AgentProxyControlFailure.malformed }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw AgentProxyControlFailure.timedOut }
            throw AgentProxyControlFailure.malformed
        }
    }
}
#endif
