#if os(macOS)
import Foundation
import Darwin

/// A local `hc connect` child, never the core daemon. No shell, PTY, global
/// signal handler, process-group kill, user config writes or implicit env.
/// The supplied executable/environment are an explicit caller policy decision.
public nonisolated final class CoreProcessTransport: CoreByteTransport {
    public struct Configuration: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let environment: [String: String]
        public let directory: URL?
        public let maximumWriteBytes: Int
        public let maximumWrites: Int
        public init(executable: URL, arguments: [String] = ["connect"], environment: [String: String],
                    directory: URL? = nil, maximumWriteBytes: Int = 2 << 20, maximumWrites: Int = 65) {
            self.executable = executable; self.arguments = arguments; self.environment = environment
            self.directory = directory; self.maximumWriteBytes = maximumWriteBytes; self.maximumWrites = maximumWrites
        }
    }
    public struct Snapshot: Sendable {
        public let started: Bool
        public let closed: Bool
        public let childPID: Int32?
        public let reaped: Bool
        public let waitStatus: Int32?
        public let queuedWriteBytes: Int
        public let stderrBytesDiscarded: UInt64
    }
    private let io: IO
    public init(configuration: Configuration) throws {
        let strings = [configuration.executable.path] + configuration.arguments + configuration.environment.flatMap { [$0.key, $0.value] }
        guard configuration.executable.isFileURL, configuration.executable.path.hasPrefix("/"),
              !strings.contains(where: { $0.utf8.contains(0) }),
              !configuration.environment.keys.contains(where: { $0.isEmpty || $0.contains("=") }),
              configuration.directory.map({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) }) ?? true,
              (1...(32 << 20)).contains(configuration.maximumWriteBytes), (1...4096).contains(configuration.maximumWrites) else {
            throw CoreProcessFailure.invalidConfiguration
        }
        io = IO(configuration)
    }
    deinit { io.cancel() }

    public func start() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { io.start($0) }
        } onCancel: { io.cancel() }
    }
    public func read() async throws -> Data? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { io.read($0) }
        } onCancel: { io.cancel() }
    }
    public func write(_ bytes: Data) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { io.write(bytes, $0) }
        } onCancel: { io.cancel() }
    }
    public func close() async throws {
        // Cleanup is not itself canceled by the caller's canceled task.
        try await withCheckedThrowingContinuation { io.close($0) }
    }
    public func snapshot() async -> Snapshot { await withCheckedContinuation { io.snapshot($0) } }

    /// I/O state and every fd syscall live on `queue`. Write admission alone
    /// has a lock so queued GCD closures cannot bypass the byte/count limits.
    /// Dispatch source
    /// cancel handlers alone close installed fds. We own/reap one PID; only an
    /// unreaped direct child may be signaled. The unchecked boundary is GCD's
    /// serial executor, not a claim that its state can be used concurrently.
    private final class IO: @unchecked Sendable {
        private let queue = DispatchQueue(label: "CoreProcessTransport.IO")
        private let configuration: Configuration
        private let admissionLock = NSLock()
        private var admittedBytes = 0
        private var admittedWrites = 0
        private var admissionClosed = false
        private var started = false
        private var closing = false
        private var completed = false
        private var cleanupFailure: (any Error)?
        private var pid: pid_t = 0
        private var childStart: (UInt64, UInt64)?
        private var reaped = false
        private var waitStatus: Int32?
        private var input: DispatchSourceWrite?
        private var output: DispatchSourceRead?
        private var errors: DispatchSourceRead?
        private var child: DispatchSourceProcess?
        private var stopTimer: DispatchSourceTimer?
        private var inputFD: Int32 = -1
        private var outputFD: Int32 = -1
        private var inputSuspended = true
        private var outputSuspended = true
        private var openSources = 0
        private var outputEOF = false
        private var reader: CheckedContinuation<Data?, Error>?
        private var closers: [CheckedContinuation<Void, Error>] = []
        private var discarded: UInt64 = 0
        private var escalated = false
        private struct Write {
            let bytes: Data
            var offset = 0
            let continuation: CheckedContinuation<Void, Error>
        }
        private var writes: [Write] = []
        private var writeBytes = 0

        init(_ configuration: Configuration) { self.configuration = configuration }
        func start(_ c: CheckedContinuation<Void, Error>) { queue.async { self.begin(c) } }
        func read(_ c: CheckedContinuation<Data?, Error>) { queue.async { self.requestRead(c) } }
        func write(_ bytes: Data, _ c: CheckedContinuation<Void, Error>) {
            admissionLock.lock()
            let failure: CoreProcessFailure? = admissionClosed ? .closed :
                (admittedWrites >= configuration.maximumWrites || bytes.count > configuration.maximumWriteBytes - admittedBytes ? .writeLimitExceeded : nil)
            if failure == nil { admittedWrites += 1; admittedBytes += bytes.count }
            admissionLock.unlock()
            if let failure { c.resume(throwing: failure); return }
            queue.async { self.requestWrite(bytes, c) }
        }
        private func releaseWrite(_ bytes: Int) {
            admissionLock.lock(); admittedWrites -= 1; admittedBytes -= bytes; admissionLock.unlock()
        }
        private func closeAdmission() {
            admissionLock.lock(); admissionClosed = true; admissionLock.unlock()
        }
        func cancel() { closeAdmission(); queue.async { self.stop(CancellationError()) } }
        func close(_ c: CheckedContinuation<Void, Error>) {
            closeAdmission()
            queue.async {
                if self.completed {
                    if let error = self.cleanupFailure { c.resume(throwing: error) } else { c.resume() }
                    return
                }
                if self.closing, let error = self.cleanupFailure { c.resume(throwing: error); return }
                // Bound even pathological repeated close callers.
                guard self.closers.count < 128 else { c.resume(throwing: CoreProcessFailure.supervisionLost); return }
                self.closers.append(c)
                self.stop(CoreProcessFailure.closed)
            }
        }
        func snapshot(_ c: CheckedContinuation<Snapshot, Never>) {
            queue.async {
                c.resume(returning: Snapshot(started: self.started, closed: self.completed,
                    childPID: self.pid > 0 ? self.pid : nil, reaped: self.reaped, waitStatus: self.waitStatus,
                    queuedWriteBytes: self.writeBytes, stderrBytesDiscarded: self.discarded))
            }
        }
        private func begin(_ c: CheckedContinuation<Void, Error>) {
            guard !closing else { c.resume(throwing: CoreProcessFailure.closed); return }
            guard !started else { c.resume(throwing: CoreProcessFailure.alreadyStarted); return }
            started = true
            do { try launch(); c.resume() }
            catch { stop(error); c.resume(throwing: error) }
        }
        private func checked(_ result: Int32) throws {
            if result != 0 { throw CoreProcessFailure.system(result) }
        }
        private func makePipe() throws -> [Int32] {
            var fds = [Int32](repeating: -1, count: 2)
            guard Darwin.pipe(&fds) == 0 else { throw CoreProcessFailure.system(errno) }
            for fd in fds {
                if fcntl(fd, F_SETFD, FD_CLOEXEC) == -1 {
                    let code = errno; for fd in fds { Darwin.close(fd) }; throw CoreProcessFailure.system(code)
                }
            }
            return fds
        }
        private func launch() throws {
            var fds: [Int32] = []
            defer { for fd in fds { Darwin.close(fd) } }
            let stdin = try makePipe(); fds += stdin
            let stdout = try makePipe(); fds += stdout
            let stderr = try makePipe(); fds += stderr
            for fd in [stdin[1], stdout[0], stderr[0]] {
                guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw CoreProcessFailure.system(errno) }
            }
            // Never change the application's global SIGPIPE disposition.
            guard fcntl(stdin[1], F_SETNOSIGPIPE, 1) != -1 else { throw CoreProcessFailure.system(errno) }
            var attr: posix_spawnattr_t?
            var actions: posix_spawn_file_actions_t?
            try checked(posix_spawnattr_init(&attr)); defer { posix_spawnattr_destroy(&attr) }
            try checked(posix_spawn_file_actions_init(&actions)); defer { posix_spawn_file_actions_destroy(&actions) }
            try checked(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
            var mask = sigset_t(); sigemptyset(&mask)
            var defaults = sigset_t(); sigfillset(&defaults); sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP)
            try checked(posix_spawnattr_setsigmask(&attr, &mask)); try checked(posix_spawnattr_setsigdefault(&attr, &defaults))
            for (from, to) in [(stdin[0], STDIN_FILENO), (stdout[1], STDOUT_FILENO), (stderr[1], STDERR_FILENO)] {
                try checked(posix_spawn_file_actions_adddup2(&actions, from, to))
            }
            if let directory = configuration.directory {
                if #available(macOS 26.0, *) { try checked(posix_spawn_file_actions_addchdir(&actions, directory.path)) }
                else { try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
            }
            let path = configuration.executable.path
            let argv = ([path] + configuration.arguments).map { strdup($0) } + [nil]
            let envp = configuration.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { for p in argv + envp { free(p) } }
            guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw CoreProcessFailure.system(ENOMEM) }
            var spawned: pid_t = 0
            try argv.withUnsafeBufferPointer { a in
                try envp.withUnsafeBufferPointer { e in
                    try checked(posix_spawn(&spawned, path, &actions, &attr, a.baseAddress!, e.baseAddress!))
                }
            }
            pid = spawned // A failed spawn never supplies authority over a PID.
            // Register exit observation before allowing executable code to run.
            let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            process.setEventHandler { [self] in reap() }
            child = process; process.activate()
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_ppid == UInt32(getpid()), info.pbi_uid == getuid(), info.pbi_status == UInt32(SSTOP) else {
                throw CoreProcessFailure.supervisionLost
            }
            childStart = (info.pbi_start_tvsec, info.pbi_start_tvusec)
            installInput(stdin[1]); installOutput(stdout[0]); installErrors(stderr[0])
            fds.removeAll { [stdin[1], stdout[0], stderr[0]].contains($0) }
            guard Darwin.kill(pid, SIGCONT) == 0 else { throw CoreProcessFailure.system(errno) }
        }
        private func installInput(_ fd: Int32) {
            inputFD = fd; openSources += 1
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in pumpWrites() }
            source.setCancelHandler { [self] in Darwin.close(fd); inputFD = -1; sourceClosed() }
            input = source // stays suspended until a write is waiting
        }
        private func installOutput(_ fd: Int32) {
            outputFD = fd; openSources += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in pumpRead() }
            source.setCancelHandler { [self] in Darwin.close(fd); outputFD = -1; sourceClosed() }
            output = source // no userspace output queue; reading is demand-driven
        }
        private func installErrors(_ fd: Int32) {
            openSources += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in
                var buffer = [UInt8](repeating: 0, count: 16 << 10)
                for _ in 0..<4 where !closing {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n > 0 { discarded = min(UInt64.max - UInt64(n), discarded) + UInt64(n) }
                    else if n == 0 { errors?.cancel(); errors = nil; return }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN { return }
                    else { stop(CoreProcessFailure.system(errno)); return }
                }
            }
            source.setCancelHandler { [self] in Darwin.close(fd); sourceClosed() }
            errors = source; source.activate()
        }
        private func requestRead(_ c: CheckedContinuation<Data?, Error>) {
            guard started else { c.resume(throwing: CoreProcessFailure.notStarted); return }
            guard !closing else { c.resume(throwing: CoreProcessFailure.closed); return }
            if outputEOF { c.resume(returning: nil); return }
            guard reader == nil else { c.resume(throwing: CoreProcessFailure.concurrentRead); return }
            reader = c; pumpRead()
        }
        private func pumpRead() {
            guard !closing, let c = reader else { return }
            var buffer = [UInt8](repeating: 0, count: 16 << 10)
            for _ in 0..<4 {
                let n = Darwin.read(outputFD, &buffer, buffer.count)
                if n > 0 {
                    reader = nil; suspendOutput(); c.resume(returning: Data(buffer.prefix(n))); return
                }
                if n == 0 {
                    reader = nil; outputEOF = true; cancelOutput(); c.resume(returning: nil); return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN { enableOutput(); return }
                stop(CoreProcessFailure.system(errno)); return
            }
            enableOutput()
        }
        private func requestWrite(_ bytes: Data, _ c: CheckedContinuation<Void, Error>) {
            guard started else { releaseWrite(bytes.count); c.resume(throwing: CoreProcessFailure.notStarted); return }
            guard !closing, pid > 0 else { releaseWrite(bytes.count); c.resume(throwing: CoreProcessFailure.closed); return }
            if bytes.isEmpty { releaseWrite(0); c.resume(); return }
            writes.append(Write(bytes: bytes, continuation: c)); writeBytes += bytes.count
            pumpWrites()
        }
        private func pumpWrites() {
            guard !closing else { return }
            for _ in 0..<4 where !writes.isEmpty {
                let n = writes[0].bytes.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: writes[0].offset), min(16 << 10, bytes.count - writes[0].offset))
                }
                if n > 0 {
                    writes[0].offset += n
                    if writes[0].offset == writes[0].bytes.count {
                        let done = writes.removeFirst(); writeBytes -= done.bytes.count
                        releaseWrite(done.bytes.count); done.continuation.resume()
                    }
                } else if n < 0 && errno == EINTR { continue }
                else if n < 0 && errno == EAGAIN { break }
                else { stop(CoreProcessFailure.system(n == 0 ? EIO : errno)); return }
            }
            if writes.isEmpty { suspendInput() } else { enableInput() }
        }
        private func enableInput() { if inputSuspended, let input { inputSuspended = false; input.resume() } }
        private func suspendInput() { if !inputSuspended, let input { inputSuspended = true; input.suspend() } }
        private func enableOutput() { if outputSuspended, let output { outputSuspended = false; output.resume() } }
        private func suspendOutput() { if !outputSuspended, let output { outputSuspended = true; output.suspend() } }
        private func cancelInput() { enableInput(); input?.cancel(); input = nil }
        private func cancelOutput() { enableOutput(); output?.cancel(); output = nil }
        private func sourceClosed() { openSources -= 1; finishIfRetired() }
        private func reap() {
            guard pid > 0 else { return }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                pid = 0; reaped = true; waitStatus = status
                child?.cancel(); child = nil
                // Preserve stdout's final buffered bytes. The reader drains to
                // EOF; exit observation is not permission to drop the last reply.
                for write in writes { releaseWrite(write.bytes.count); write.continuation.resume(throwing: CoreProcessFailure.closed) }
                writes.removeAll(); writeBytes = 0; cancelInput()
                finishIfRetired()
            } else if result < 0 && errno != EINTR {
                // Someone else reaped it: never signal a potentially reused PID.
                pid = 0; child?.cancel(); child = nil
                cleanupFailure = CoreProcessFailure.supervisionLost
                stop(CoreProcessFailure.supervisionLost)
            }
        }
        private func stop(_ error: any Error) {
            guard !closing else { finishIfRetired(); return }
            closing = true; closeAdmission()
            reader?.resume(throwing: error); reader = nil
            for write in writes { releaseWrite(write.bytes.count); write.continuation.resume(throwing: error) }
            writes.removeAll(); writeBytes = 0
            cancelInput(); cancelOutput(); errors?.cancel(); errors = nil
            reap()
            if pid > 0 {
                signalOwned(SIGTERM) // unreaped direct child only, never -pid
                let began = DispatchTime.now().uptimeNanoseconds
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.setEventHandler { [self] in
                    reap()
                    let elapsed = DispatchTime.now().uptimeNanoseconds - began
                    if pid > 0 && !escalated && elapsed >= 250_000_000 {
                        escalated = true; signalOwned(SIGKILL)
                    }
                    if pid > 0 && elapsed >= 2_000_000_000 {
                        cleanupFailure = CoreProcessFailure.supervisionLost
                        for closer in closers { closer.resume(throwing: CoreProcessFailure.supervisionLost) }
                        closers.removeAll(); stopTimer?.cancel(); stopTimer = nil
                        // Keep the process observer alive to reap if it exits
                        // later; do not report successful retirement meanwhile.
                    }
                    finishIfRetired()
                }
                stopTimer = timer; timer.schedule(deadline: .now(), repeating: .milliseconds(20)); timer.activate()
            }
            finishIfRetired()
        }
        private func signalOwned(_ signal: Int32) {
            guard pid > 0 else { return }
            if let childStart {
                var info = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                      info.pbi_ppid == UInt32(getpid()), info.pbi_uid == getuid(),
                      info.pbi_start_tvsec == childStart.0, info.pbi_start_tvusec == childStart.1 else {
                    // A foreign reaper must never turn our saved PID into
                    // permission to signal an unrelated replacement process.
                    reap() // It may simply have exited since the last check.
                    if pid > 0 { cleanupFailure = CoreProcessFailure.supervisionLost }
                    return
                }
            }
            // Before identity capture, only a just-spawned suspended child can
            // reach this path (startup failure); it has never run user code.
            _ = Darwin.kill(pid, signal)
        }
        private func finishIfRetired() {
            guard closing, !completed, pid == 0, openSources == 0 else { return }
            completed = true; stopTimer?.cancel(); stopTimer = nil; child?.cancel(); child = nil
            for closer in closers {
                if let cleanupFailure { closer.resume(throwing: cleanupFailure) } else { closer.resume() }
            }
            closers.removeAll()
        }
    }
}
#endif
