import Foundation
import Darwin
import AgentProxyCore

/// Recorder-loop admission is elsewhere; this client is used only by that
/// coordinator's serial worker. Its private inherited socketpair identifies
/// one spawned child for its lifetime; it never reconnects or substitutes a
/// pathname peer. This is not authentication against a malicious same-UID actor.
final class ConversationStorageOwnerClient {
    private let socketFD: Int32
    private let child: pid_t
    private var nextID: UInt64 = 0
    private var closed = false

    init(stateDirectory: String, producer: ConversationProducerLease, generation: UInt64) throws {
        try producer.verify()
        guard let executable = Bundle.main.executablePath, executable.hasPrefix("/") else { throw ConversationStorageOwner.Failure.unavailable }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw ConversationStorageOwner.Failure.unavailable }
        let local = pair[0], remote = pair[1]
        let inheritedSocket = fcntl(remote, F_DUPFD_CLOEXEC, 10)
        let inheritedLease = fcntl(producer.descriptor, F_DUPFD_CLOEXEC, 10)
        guard inheritedSocket >= 0, inheritedLease >= 0 else {
            if inheritedSocket >= 0 { Darwin.close(inheritedSocket) }
            if inheritedLease >= 0 { Darwin.close(inheritedLease) }
            Darwin.close(local); Darwin.close(remote); throw ConversationStorageOwner.Failure.unavailable
        }
        defer { Darwin.close(inheritedSocket); Darwin.close(inheritedLease); Darwin.close(remote) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { Darwin.close(local); throw ConversationStorageOwner.Failure.unavailable }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions); Darwin.close(local); throw ConversationStorageOwner.Failure.unavailable
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for fd: Int32 in [0, 1, 2] {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0 else {
                Darwin.close(local); throw ConversationStorageOwner.Failure.unavailable
            }
        }
        guard posix_spawn_file_actions_adddup2(&actions, inheritedSocket, 3) == 0,
              posix_spawn_file_actions_adddup2(&actions, inheritedLease, 4) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            Darwin.close(local); throw ConversationStorageOwner.Failure.unavailable
        }
        let args = [executable, "storage-owner", "--state-dir", stateDirectory, "--producer-fd", "4"].map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { args.forEach { free($0) } }
        guard args.dropLast().allSatisfy({ $0 != nil }) else { Darwin.close(local); throw ConversationStorageOwner.Failure.unavailable }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, args, environment) == 0 else {
            Darwin.close(local); throw ConversationStorageOwner.Failure.unavailable
        }
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard fcntl(local, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(local, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(local, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(local, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            Darwin.close(local); _ = kill(pid, SIGKILL)
            let reapPID = pid
            DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; while waitpid(reapPID, &status, 0) < 0 && errno == EINTR {} }
            throw ConversationStorageOwner.Failure.unavailable
        }
        socketFD = local; child = pid
        do {
            let reply = try request(operation: .begin, generation: generation)
            guard reply.outcome == .success else { throw ConversationStorageOwner.Failure.unavailable }
        } catch { closeOwner(); throw error }
    }

    func request(operation: ConversationStorageOwner.Request.Operation, generation: UInt64,
                 key: ConversationStore.PersistentSnapshot.Key? = nil,
                 record: ConversationStore.PersistentSnapshot.Record? = nil,
                 updatedAt: Date? = nil) throws -> ConversationStorageOwner.Reply {
        guard !closed, nextID < UInt64.max else { throw ConversationStorageOwner.Failure.unavailable }
        nextID += 1
        let request = ConversationStorageOwner.Request(id: nextID, generation: generation, protocolVersion: ConversationStorageOwner.protocolVersion, operation: operation, key: key, record: record, updatedAt: updatedAt)
        do {
            try ConversationStorageOwner.writeMessage(try JSONEncoder().encode(request), descriptor: socketFD)
            guard let data = try ConversationStorageOwner.readMessage(socketFD) else { throw ConversationStorageOwner.Failure.unavailable }
            let reply = try JSONDecoder().decode(ConversationStorageOwner.Reply.self, from: data)
            guard reply.id == nextID, reply.generation == generation, reply.protocolVersion == ConversationStorageOwner.protocolVersion,
                  (operation == .load || reply.record == nil), (reply.outcome == .success || reply.record == nil) else {
                throw ConversationStorageOwner.Failure.invalid
            }
            if operation == .begin && reply.outcome == .unavailable {
                if reply.health == "unsafe" { throw ConversationStorageOwner.Failure.unsafe }
                if reply.health == "retryable" { throw ConversationStorageOwner.Failure.unavailable }
                throw ConversationStorageOwner.Failure.invalid
            }
            guard ["healthy", "degraded"].contains(reply.health) else { throw ConversationStorageOwner.Failure.invalid }
            if let value = reply.record {
                guard let key, Data(value.key.agent.utf8) == Data(key.agent.utf8),
                      Data(value.key.herdrSession.utf8) == Data(key.herdrSession.utf8),
                      Data(value.key.nativeSession.utf8) == Data(key.nativeSession.utf8) else { throw ConversationStorageOwner.Failure.invalid }
            }
            return reply
        } catch {
            closeOwner()
            throw error
        }
    }

    private func closeOwner() {
        guard !closed else { return }
        closed = true
        shutdown(socketFD, SHUT_RDWR); Darwin.close(socketFD)
        // The child remains ours and unreaped here, so this PID cannot be
        // reused. Its lifecycle and owner locks persist until it actually exits.
        _ = kill(child, SIGKILL)
        let pid = child
        DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
    }
    deinit { closeOwner() }
}
