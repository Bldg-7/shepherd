import Foundation

#if os(macOS)
import Darwin

/// Finite commands, not interactive terminals. A suspended, isolated-session
/// launch proves ownership before executable code runs. The root is kept
/// waitable until command pipes retire, reserving its PID against group reuse.
/// This is not a sandbox: a descendant that deliberately leaves the session
/// while retaining command pipes cannot be safely killed from this ownership
/// proof. After a four-second stop/drain budget it fails with supervisionLost,
/// as do external reaping or a root that cannot be retired. That error does not
/// claim cleanup; callers must surface it, not treat it as command success.
nonisolated enum LocalCommand {
    struct Command: Sendable {
        let executable: URL
        var arguments: [String] = []
        var environment: [String: String]? = nil
        var currentDirectory: URL? = nil
    }

    enum CommandError: Error, LocalizedError {
        case deadlineExceeded
        case outputLimitExceeded(Int)
        case supervisionLost
        var errorDescription: String? {
            switch self {
            case .deadlineExceeded: String(localized: "The host command exceeded its deadline; the operation did not complete successfully.")
            case .outputLimitExceeded(let limit): "The host command exceeded its \(limit)-byte combined output limit. Reduce output or explicitly raise maxOutputBytes."
            case .supervisionLost: "The host command's owned lifetime could not be verified or retired; the operation did not complete successfully."
            }
        }
    }

    /// CLI JSON and script responses use a combined 64 MiB ceiling, not silent
    /// truncation. Resource installers transfer through files/stdin, not this
    /// returned response; a known larger response may explicitly raise the cap.
    static func run(_ command: Command, timeout: TimeInterval = 60, maxOutputBytes: Int = 64 * 1024 * 1024,
                    failure: @escaping @Sendable (_ status: Int, _ stderr: String) -> any Error) async throws -> Data {
        guard timeout.isFinite, timeout > 0, maxOutputBytes > 0 else { throw POSIXError(.EINVAL) }
        let running = RunningCommand(command: command, timeout: timeout, maxOutputBytes: maxOutputBytes, failure: failure)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { running.start($0) }
        } onCancel: { running.cancel() }
    }

    private final class RunningCommand: @unchecked Sendable {
        private let queue = DispatchQueue(label: "LocalCommand.completion")
        private let command: Command
        private let timeout: TimeInterval
        private let maxOutputBytes: Int
        private let failure: @Sendable (Int, String) -> any Error
        private let stdout = Pipe()
        private let stderr = Pipe()
        private var continuation: CheckedContinuation<Data, Error>?
        private var readers: [DispatchSourceRead] = []
        private var openReaders = 0
        private var output = Data()
        private var errorOutput = Data()
        private var timer: DispatchSourceTimer?
        private var began = DispatchTime.now().uptimeNanoseconds
        private var cancelled = false
        private var failureReason: (any Error)?
        private var pid: pid_t = 0
        private var startSeconds: UInt64 = 0
        private var startMicroseconds: UInt64 = 0
        private var exitStatus: Int?
        private var stoppingAt: UInt64?
        private var escalated = false
        private var closing = false
        private var completion: Result<Data, Error>?

        init(command: Command, timeout: TimeInterval, maxOutputBytes: Int, failure: @escaping @Sendable (Int, String) -> any Error) {
            self.command = command; self.timeout = timeout; self.maxOutputBytes = maxOutputBytes; self.failure = failure
        }
        func start(_ continuation: CheckedContinuation<Data, Error>) { queue.async { self.begin(continuation) } }
        func cancel() {
            queue.async {
                self.cancelled = true
                if self.continuation != nil { self.stop(with: CancellationError()) }
            }
        }
        private func begin(_ continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
            if cancelled { finish(.failure(CancellationError())); return }
            do {
                try addReader(stdout.fileHandleForReading, isError: false)
                try addReader(stderr.fileHandleForReading, isError: true)
                try launch()
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                began = DispatchTime.now().uptimeNanoseconds
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.setEventHandler { [self] in tick() }
                timer.schedule(deadline: .now(), repeating: .milliseconds(20))
                self.timer = timer; timer.activate()
            } catch { finish(.failure(error)) }
        }
        private func checked(_ code: Int32) throws {
            if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        private func launch() throws {
            let path = command.executable.path
            let environment = command.environment ?? ProcessInfo.processInfo.environment
            let strings = [path] + command.arguments + environment.map { "\($0.key)=\($0.value)" }
            guard !strings.contains(where: { $0.utf8.contains(0) }),
                  !environment.keys.contains(where: { $0.isEmpty || $0.contains("=") }),
                  command.currentDirectory?.path.utf8.contains(0) != true else { throw POSIXError(.EINVAL) }
            var attributes: posix_spawnattr_t?
            try checked(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            var actions: posix_spawn_file_actions_t?
            try checked(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
            // GCD workers can block signals; commands must not inherit that
            // mask or the host runtime's dispositions (notably SIGPIPE).
            var mask = sigset_t(); sigemptyset(&mask)
            var defaults = sigset_t(); sigfillset(&defaults)
            sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP)
            try checked(posix_spawnattr_setsigmask(&attributes, &mask))
            try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
            try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            try checked(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
            try checked(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
            if let directory = command.currentDirectory {
                if #available(macOS 26.0, *) { try checked(posix_spawn_file_actions_addchdir(&actions, directory.path)) }
                else { try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
            }
            let argv = ([path] + command.arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { for pointer in argv + envp { free(pointer) } }
            guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
            try argv.withUnsafeBufferPointer { args in
                try envp.withUnsafeBufferPointer { env in
                    try checked(posix_spawn(&pid, path, &actions, &attributes, args.baseAddress!, env.baseAddress!))
                }
            }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_ppid == UInt32(getpid()), info.pbi_uid == getuid(), info.pbi_status == UInt32(SSTOP),
                  info.pbi_pgid == UInt32(pid), getsid(pid) == pid, getpgid(pid) == pid else {
                // posix_spawn returned our unreaped, suspended child. No group
                // signal is allowed until the isolated-session proof succeeds.
                _ = Darwin.kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                pid = 0
                throw CommandError.supervisionLost
            }
            startSeconds = info.pbi_start_tvsec; startMicroseconds = info.pbi_start_tvusec
            if Darwin.kill(pid, SIGCONT) != 0 {
                let resumeError = errno
                _ = Darwin.kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                pid = 0
                throw POSIXError(POSIXErrorCode(rawValue: resumeError) ?? .EIO)
            }
        }
        private func addReader(_ handle: FileHandle, isError: Bool) throws {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in
                var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                // At most 64 KiB / four syscalls per serial turn, including
                // EINTR. Timer/cancellation cannot be starved by a hot pipe.
                for _ in 0..<4 where !closing {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count > 0 {
                        if failureReason == nil {
                            if count > maxOutputBytes - output.count - errorOutput.count {
                                stop(with: CommandError.outputLimitExceeded(maxOutputBytes))
                            } else if isError { errorOutput.append(contentsOf: bytes.prefix(count)) }
                            else { output.append(contentsOf: bytes.prefix(count)) }
                        }
                    } else if count == 0 { source.cancel(); return }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    else { stop(with: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)); source.cancel(); return }
                }
            }
            source.setCancelHandler { [self] in
                source.setEventHandler(handler: nil); source.setCancelHandler(handler: nil)
                try? handle.close(); openReaders -= 1; completeIfReady()
            }
            readers.append(source); openReaders += 1; source.activate()
        }
        /// waitid does not reap. A live child must retain the original kernel
        /// identity; a waitable exit reserves the PID even though Darwin no
        /// longer exposes zombie proc_bsdinfo/getpgid. No ancestry polling.
        private func observeExit() -> Bool {
            guard pid > 0 else { return false }
            var info = siginfo_t()
            var code: Int32
            repeat { code = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) } while code == -1 && errno == EINTR
            guard code == 0 else { return false }
            if info.si_pid == pid {
                guard info.si_code == CLD_EXITED || info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED else { return false }
                exitStatus = Int(info.si_status)
                return true
            }
            var live = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &live, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size {
                return live.pbi_ppid == UInt32(getpid()) && live.pbi_start_tvsec == startSeconds && live.pbi_start_tvusec == startMicroseconds
            }
            // It may have exited between waitid and proc_pidinfo; retry next
            // turn, never signal from an unverified snapshot.
            return false
        }
        private func signalGroup(_ signal: Int32) {
            guard observeExit() else { return }
            _ = Darwin.kill(-pid, signal)
        }
        private func completeIfReady() {
            guard continuation != nil, openReaders == 0 else { return }
            if let completion { resume(completion); return }
            guard let exitStatus else { return }
            if let failureReason { finish(.failure(failureReason)) }
            else if exitStatus == 0 { finish(.success(output)) }
            else { finish(.failure(failure(exitStatus, String(decoding: errorOutput, as: UTF8.self)))) }
        }
        private func tick() {
            guard continuation != nil else { return }
            _ = observeExit()
            completeIfReady()
            guard continuation != nil else { return }
            if let stoppingAt {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - stoppingAt) / 1_000_000_000
                if !escalated && elapsed >= 2 { escalated = true; signalGroup(SIGKILL) }
                if elapsed >= 4 { finish(.failure(CommandError.supervisionLost)); return }
            } else if Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000 >= timeout {
                stop(with: CommandError.deadlineExceeded)
            }
            completeIfReady()
        }
        private func stop(with error: any Error) {
            guard failureReason == nil else { return }
            failureReason = error; stoppingAt = DispatchTime.now().uptimeNanoseconds
            signalGroup(SIGTERM)
            completeIfReady()
        }
        private func finish(_ result: Result<Data, Error>) {
            guard continuation != nil, completion == nil else { return }
            completion = result; closing = true
            timer?.cancel(); timer = nil
            for reader in readers { reader.cancel() }
            if openReaders == 0 { resume(result) }
        }
        private func resume(_ result: Result<Data, Error>) {
            guard let continuation else { return }
            self.continuation = nil; readers.removeAll()
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
            var final = result
            if pid > 0 {
                var status: Int32 = 0
                var reaped: pid_t
                repeat { reaped = waitpid(pid, &status, WNOHANG) } while reaped == -1 && errno == EINTR
                if reaped != pid { final = .failure(CommandError.supervisionLost) }
                pid = 0
            }
            continuation.resume(with: final)
        }
    }
}
#endif
