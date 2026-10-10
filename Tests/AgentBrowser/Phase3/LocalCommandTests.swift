#if os(macOS)
import Foundation
import Darwin

nonisolated struct CommandFailure: Error {
    let status: Int
    let stderr: String
}

@main struct LocalCommandTests {
    static let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    static func command(_ arguments: [String]) -> LocalCommand.Command {
        .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments)
    }
    static func fixture(_ arguments: [String]) -> LocalCommand.Command { .init(executable: executable, arguments: arguments) }
    static func run(_ command: LocalCommand.Command, timeout: TimeInterval = 5, limit: Int = 64 * 1024 * 1024) async throws -> Data {
        try await LocalCommand.run(command, timeout: timeout, maxOutputBytes: limit) { CommandFailure(status: $0, stderr: $1) }
    }
    static func pass(_ name: String) { print("PASS: " + name) }
    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n }
                else if errno != EINTR { _exit(91) }
            }
        }
    }
    static func snapshot(_ path: String) throws {
        var info = proc_bsdinfo()
        precondition(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0)
        var out = stat(); var err = stat()
        precondition(fstat(1, &out) == 0 && fstat(2, &err) == 0)
        let value = "\(getpid()) \(info.pbi_start_tvsec) \(info.pbi_start_tvusec) \(info.pbi_ppid) \(getpgid(0)) \(getsid(0)) \(out.st_mode & S_IFMT) \(err.st_mode & S_IFMT) \(info.pbi_uid)\n"
        try value.write(toFile: path, atomically: true, encoding: .utf8)
    }
    static func spawn(_ arguments: [String]) -> pid_t {
        var pid: pid_t = 0
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let code = argv.withUnsafeBufferPointer { posix_spawn(&pid, executable.path, nil, nil, $0.baseAddress!, [nil]) }
        precondition(code == 0)
        return pid
    }
    static func identity(_ file: URL) throws -> [UInt64] {
        try String(contentsOf: file, encoding: .utf8).split(separator: " ").map { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines))! }
    }
    static func live(_ values: [UInt64]) -> Bool {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(Int32(values[0]), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n > 0 && info.pbi_start_tvsec == values[1] && info.pbi_start_tvusec == values[2] && info.pbi_status != UInt32(SZOMB)
    }
    static func kernelIdentity(_ pid: pid_t) -> [UInt64] {
        var info = proc_bsdinfo()
        precondition(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0)
        return [UInt64(pid), info.pbi_start_tvsec, info.pbi_start_tvusec, UInt64(info.pbi_pgid), UInt64(getsid(pid)), UInt64(info.pbi_uid)]
    }
    static func fdCount() -> Int32 { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0) }
    static func fixtureMain(_ args: [String]) throws {
        switch args[0] {
        case "holder", "holder-ignore":
            if args[0] == "holder-ignore" { signal(SIGTERM, SIG_IGN) }
            try snapshot(args[1]); sleep(30)
        case "orphan", "orphan-ignore", "escaped-root":
            let childMode = args[0] == "escaped-root" ? "escaped-holder" : (args[0] == "orphan" ? "holder" : "holder-ignore")
            try snapshot(args[1]); _ = spawn([childMode, args[2]]); _exit(0)
        case "escaped-holder":
            precondition(setsid() > 0)
            var mask = sigset_t(); sigemptyset(&mask); sigprocmask(SIG_SETMASK, &mask, nil)
            signal(SIGTERM, SIG_DFL)
            try snapshot(args[1]); sleep(10)
        case "daemon-root", "daemon-root-same":
            try snapshot(args[1]); _ = spawn([args[0] == "daemon-root" ? "daemon" : "daemon-same", args[2]]); _exit(0)
        case "daemon", "daemon-same":
            // Closed-pipe servers survive success, whether they create a new
            // session or intentionally retain the launch group.
            if args[0] == "daemon" { precondition(setsid() > 0) }
            close(0); close(1); close(2)
            let fd = open("/dev/null", O_RDWR); precondition(fd == 0)
            precondition(dup2(fd, 1) == 1 && dup2(fd, 2) == 2)
            try snapshot(args[1]); sleep(1); _exit(0)
        case "continuous", "unbounded":
            let block = Data(repeating: 65, count: 16 * 1024)
            let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            while DispatchTime.now().uptimeNanoseconds < end {
                writeAll(1, block); writeAll(2, block)
                if args[0] == "continuous" { usleep(1000) }
            }
        case "finite", "finite-error":
            let block = Data(repeating: 65, count: 16 * 1024)
            for _ in 0..<128 { writeAll(1, block); writeAll(2, block) }
            writeAll(1, Data("trailing".utf8))
            if args[0] == "finite-error" { writeAll(2, Data([0xff, 0x61])); _exit(9) }
        default: preconditionFailure("unknown fixture")
        }
    }
    static func main() async throws {
        if CommandLine.arguments.count > 1 { try fixtureMain(Array(CommandLine.arguments.dropFirst())); return }
        let root = FileManager.default.temporaryDirectory.appending(path: "local-command-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptors = fdCount()
        do { _ = try await run(command(["-c", "exit 0"]), timeout: 0); preconditionFailure("invalid deadline succeeded") }
        catch let error as POSIXError { precondition(error.code == .EINVAL) }
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await run(.init(executable: URL(fileURLWithPath: "/owned/missing/executable")))
        }
        do { _ = try await preCancelled.value; preconditionFailure("pre-cancelled launch succeeded") }
        catch is CancellationError {}
        pass("invalid deadline and pre-launch cancellation retire without executing")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask {
                for _ in 0..<50 {
                    let output = try await run(command(["-c", "printf owned-fast-exit"]))
                    precondition(String(decoding: output, as: UTF8.self) == "owned-fast-exit")
                }
            } }
            try await group.waitForAll()
        }
        pass("400 concurrent fast exits preserve exact stdout and reap roots")
        do { _ = try await run(command(["-c", "printf owned-stderr >&2; exit 7"])); preconditionFailure("nonzero succeeded") }
        catch let error as CommandFailure { precondition(error.status == 7 && error.stderr == "owned-stderr") }
        pass("nonzero exact status and stderr")
        let large = try await run(fixture(["finite"]))
        precondition(large.count == 2 * 1024 * 1024 + 8 && large.suffix(8) == Data("trailing".utf8))
        do { _ = try await run(fixture(["finite-error"])); preconditionFailure("large failure succeeded") }
        catch let error as CommandFailure { precondition(error.status == 9 && error.stderr == String(repeating: "A", count: 2 * 1024 * 1024) + "\u{fffd}a") }
        pass("finite large simultaneous pipes, trailing bytes and replacement UTF8 stderr preserved")
        do { _ = try await run(.init(executable: URL(fileURLWithPath: "/owned/missing/executable"))); preconditionFailure("launch succeeded") }
        catch let error as POSIXError { precondition(error.code == .ENOENT) }
        do { _ = try await run(command(["-c", "kill -TERM $$"])); preconditionFailure("signal succeeded") }
        catch let error as CommandFailure { precondition(error.status == SIGTERM) }
        pass("launch error and actual signal exit status")
        let configured = LocalCommand.Command(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read x || printf '%s|%s|%s' \"$TOKEN\" \"$PWD\" \"$1\"", "argv-zero", "literal ' argument"],
            environment: ["TOKEN": "exact-env", "PATH": "/nonexistent"], currentDirectory: root)
        let configuredOutput = try await run(configured)
        let configuredText = String(decoding: configuredOutput, as: UTF8.self)
        let directoryPointer = realpath(root.path, nil)!
        let expectedDirectory = String(cString: directoryPointer); free(directoryPointer)
        precondition(configuredText == "exact-env|\(expectedDirectory)|literal ' argument", configuredText)
        pass("argv/env/cwd and null stdin without shell reinterpretation or runtime dependency")
        do { _ = try await run(fixture(["finite"]), limit: 32768); preconditionFailure("limit silently succeeded") }
        catch LocalCommand.CommandError.outputLimitExceeded(let limit) { precondition(limit == 32768) }
        do { _ = try await run(fixture(["unbounded"]), limit: 1024 * 1024); preconditionFailure("continuous output succeeded") }
        catch LocalCommand.CommandError.outputLimitExceeded(let limit) { precondition(limit == 1024 * 1024) }
        pass("finite and continuous excessive output fail explicitly, never silently truncate")
        for cancel in [false, true] {
            let began = Date()
            let task = Task { try await run(fixture(["continuous"]), timeout: 0.2) }
            if cancel { try await Task.sleep(for: .milliseconds(100)); task.cancel() }
            do { _ = try await task.value; preconditionFailure("continuous output succeeded") }
            catch is CancellationError { precondition(cancel) }
            catch LocalCommand.CommandError.deadlineExceeded { precondition(!cancel) }
            precondition(Date().timeIntervalSince(began) < 1)
        }
        pass("continuous stdout/stderr deadline and cancellation are fair and bounded")
        let inheritedStart = Date()
        let inherited = try await run(command(["-c", "sleep 0.3 & printf inherited-output; exit 0"]))
        precondition(String(decoding: inherited, as: UTF8.self) == "inherited-output" && Date().timeIntervalSince(inheritedStart) >= 0.25)
        pass("root exit retains trailing pipe lifetime until EOF")
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["20"]
        try unrelated.run()
        let unrelatedIdentity = kernelIdentity(unrelated.processIdentifier), runtimeIdentity = kernelIdentity(getpid())
        print("UNRELATED before=\(unrelatedIdentity) runtime=\(runtimeIdentity)")
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        for cancel in [false, true] {
            let name = cancel ? "cancel" : "timeout"
            let rootFile = root.appending(path: name + "-root"), childFile = root.appending(path: name + "-child")
            let began = Date()
            let task = Task { try await run(fixture(["orphan", rootFile.path, childFile.path]), timeout: 0.2) }
            if cancel { try await Task.sleep(for: .milliseconds(100)); task.cancel() }
            do { _ = try await task.value; preconditionFailure("orphan succeeded") }
            catch is CancellationError { precondition(cancel) }
            catch LocalCommand.CommandError.deadlineExceeded { precondition(!cancel) }
            let parent = try identity(rootFile), child = try identity(childFile)
            print("OWNERSHIP \(name) root=\(parent) child=\(child) liveAfter=\(live(child))")
            precondition(parent[0] == parent[4] && parent[0] == parent[5] && parent[8] == UInt64(getuid()) && child[8] == parent[8])
            precondition(child[4] == parent[4] && child[5] == parent[5] && child[6] == UInt64(S_IFIFO) && child[7] == UInt64(S_IFIFO))
            precondition(!live(child) && !live(parent) && kill(Int32(parent[0]), 0) == -1 && errno == ESRCH)
            precondition(unrelated.isRunning && Date().timeIntervalSince(began) < 1)
        }
        pass("immediate root exit pipe children terminated on timeout/cancel; roots reaped, unrelated process intact; no forced cleanup")
        let stubbornRoot = root.appending(path: "stubborn-root"), stubbornChild = root.appending(path: "stubborn-child")
        do { _ = try await run(fixture(["orphan-ignore", stubbornRoot.path, stubbornChild.path]), timeout: 0.1); preconditionFailure("ignored TERM succeeded") }
        catch LocalCommand.CommandError.deadlineExceeded {}
        let stubbornChildIdentity = try identity(stubbornChild), stubbornRootIdentity = try identity(stubbornRoot)
        precondition(!live(stubbornChildIdentity) && !live(stubbornRootIdentity) && unrelated.isRunning)
        pass("TERM-resistant inherited pipe child escalates to verified-group KILL and retires")
        for mode in ["daemon-root", "daemon-root-same"] {
            let daemonRootFile = root.appending(path: mode), daemonFile = root.appending(path: mode + "-child")
            let daemonStart = Date()
            _ = try await run(fixture([mode, daemonRootFile.path, daemonFile.path]), timeout: 0.2)
            precondition(Date().timeIntervalSince(daemonStart) < 0.5)
            let daemon = try identity(daemonFile), daemonRoot = try identity(daemonRootFile)
            precondition(live(daemon))
            precondition((daemon[4] == daemonRoot[4]) == (mode == "daemon-root-same"))
            precondition((daemon[5] == daemonRoot[5]) == (mode == "daemon-root-same"))
            precondition(daemon[6] == UInt64(S_IFCHR) && daemon[7] == UInt64(S_IFCHR))
            print("DAEMON \(mode) root=\(daemonRoot) child=\(daemon) aliveAfterSuccess=true")
            try await Task.sleep(for: .milliseconds(1100))
            precondition(!live(daemon) && unrelated.isRunning)
        }
        precondition(kernelIdentity(unrelated.processIdentifier) == unrelatedIdentity && kernelIdentity(getpid()) == runtimeIdentity)
        print("UNRELATED after=\(kernelIdentity(unrelated.processIdentifier)) runtime=\(kernelIdentity(getpid()))")
        pass("intentional closed-pipe same-group and detached daemons survive success and exit naturally")
        let escapedRootFile = root.appending(path: "escaped-root"), escapedFile = root.appending(path: "escaped-child")
        let escapedStart = Date()
        do { _ = try await run(fixture(["escaped-root", escapedRootFile.path, escapedFile.path]), timeout: 0.1); preconditionFailure("escaped pipe lifetime succeeded") }
        catch LocalCommand.CommandError.supervisionLost {}
        let escaped = try identity(escapedFile), escapedRoot = try identity(escapedRootFile)
        precondition(live(escaped) && escaped[4] != escapedRoot[4] && escaped[5] != escapedRoot[5])
        precondition(Date().timeIntervalSince(escapedStart) < 5 && !live(escapedRoot))
        print("EXCEPTION supervisionLost root=\(escapedRoot) escapedSurvivor=\(escaped); NOT helper cleanup success")
        // Separately owned failed-fixture cleanup, never evidence of helper
        // supervision success. Recheck kernel start/UID/session before signal.
        let verifiedEscaped = kernelIdentity(Int32(escaped[0]))
        precondition(verifiedEscaped == [escaped[0], escaped[1], escaped[2], escaped[4], escaped[5], escaped[8]])
        precondition(kill(Int32(escaped[0]), SIGTERM) == 0)
        for _ in 0..<50 where live(escaped) { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!live(escaped) && unrelated.isRunning)
        pass("escaped pipe holder produces bounded explicit supervisionLost; separate failed-fixture teardown recorded")
        // Dispatch sources have retired before each continuation; libdispatch
        // may lazily allocate its own descriptors, but command FDs cannot grow.
        let warmedDescriptors = fdCount()
        for _ in 0..<20 {
            _ = try await run(command(["-c", "exit 0"]))
            do { _ = try await run(.init(executable: URL(fileURLWithPath: "/owned/missing/executable"))); preconditionFailure("launch succeeded") }
            catch is POSIXError {}
        }
        precondition(fdCount() == warmedDescriptors)
        print("FD bytes baseline=\(descriptors) warmed=\(warmedDescriptors) final=\(fdCount())")
        pass("repeated command execution does not leak descriptors")
        print("LOCAL COMMAND PASS; explicit command-spec contract, no Foundation Process state promised")
    }
}
#endif
