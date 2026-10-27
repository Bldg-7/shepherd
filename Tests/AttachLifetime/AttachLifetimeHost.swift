import Darwin
import Foundation
import NIOCore

// Minimal app-owned declarations let this harness compile the production
// LocalTerminalSession source without loading the app or its configuration.
struct HerdrMachine {}

struct LocalAttachLaunch {
    static let configurationFolder = "unused"
    let executable: String
    let arguments: [String]
    let environment: [String]

    static func make(
        terminalID: String,
        herdrMachine: HerdrMachine?,
        herdrPath: String?,
        configurationPath: String?,
        baseEnvironment: [String],
        inherited: [String: String]
    ) -> LocalAttachLaunch {
        LocalAttachLaunch(
            executable: ProcessInfo.processInfo.environment["ATTACH_LIFETIME_FAKE"]!,
            arguments: [terminalID],
            environment: [
                "ATTACH_LIFETIME_LOG_DIR=\(ProcessInfo.processInfo.environment["ATTACH_LIFETIME_LOG_DIR"]!)",
                "PATH=/usr/bin:/bin"
            ]
        )
    }
}

enum HerdrExecutable {
    static func localPath() -> String { ProcessInfo.processInfo.environment["ATTACH_LIFETIME_FAKE"]! }
    static func localAttachConfiguration(in folder: String) -> String? { nil }
}

enum Terminal {
    static func getEnvironmentVariables(termName: String) -> [String] { ["TERM=\(termName)"] }
}

enum TerminalSessionError: Error { case notStarted, alreadyStarted }

protocol TerminalSessionProviding: AnyObject {
    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer>
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func stop() async
}

@main enum AttachLifetimeHost {
    static let observationDeadline: Duration = .seconds(3)

    static func logDirectory() -> URL {
        guard let path = ProcessInfo.processInfo.environment["ATTACH_LIFETIME_LOG_DIR"] else {
            FileHandle.standardError.write(Data("MISSING LOG DIRECTORY\n".utf8))
            exit(4)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func completedFakePIDs(expectedCount: Int) -> [pid_t] {
        let directory = logDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let pids: [pid_t] = files.compactMap { file in
            guard let contents = try? String(contentsOf: file, encoding: .utf8),
                  contents.contains("\nENUMERATED\n"),
                  let first = contents.split(separator: "\n", maxSplits: 1).first,
                  first.hasPrefix("READY ") else { return nil }
            let fields = Dictionary(uniqueKeysWithValues: first.split(separator: " ").dropFirst().compactMap { field -> (String, String)? in
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return (String(pair[0]), String(pair[1]))
            })
            guard let raw = fields["pid"], let pid = Int32(raw), pid > 0 else { return nil }
            return pid
        }
        guard pids.count == expectedCount, Set(pids).count == expectedCount else {
            FileHandle.standardError.write(Data("INCOMPLETE OWNED FAKE IDENTITIES\n".utf8))
            exit(5)
        }
        return pids
    }

    /// Observes only the known direct fake children with WNOWAIT. It never
    /// reaps them; ECHILD is the evidence that LocalTerminalSession's reaper
    /// consumed the owned child after stop() requested its exit.
    static func waitForProductionReap(_ pids: [pid_t]) async {
        var remaining = Set(pids)
        let deadline = ContinuousClock.now + observationDeadline
        while !remaining.isEmpty {
            for pid in Array(remaining) {
                var info = siginfo_t()
                var result: Int32
                repeat {
                    result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                } while result == -1 && errno == EINTR
                if result == -1 {
                    if errno == ECHILD {
                        remaining.remove(pid)
                        continue
                    }
                    FileHandle.standardError.write(Data("OWNED WAITID FAILED pid=\(pid) errno=\(errno)\n".utf8))
                    exit(6)
                }
                guard info.si_pid == 0 || info.si_pid == pid else {
                    FileHandle.standardError.write(Data("OWNED WAITID IDENTITY MISMATCH\n".utf8))
                    exit(7)
                }
            }
            if remaining.isEmpty { return }
            if ContinuousClock.now >= deadline {
                FileHandle.standardError.write(Data("PRODUCTION REAPER DID NOT CONSUME OWNED FAKES\n".utf8))
                exit(8)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    static func waitForController() async {
        let controller = logDirectory().appendingPathComponent("host-continue")
        let deadline = ContinuousClock.now + observationDeadline
        while !FileManager.default.fileExists(atPath: controller.path) {
            if ContinuousClock.now >= deadline {
                FileHandle.standardError.write(Data("CONTROLLER DID NOT CONFIRM ENUMERATION\n".utf8))
                exit(9)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    static func exerciseFaultGate() async {
        let first = LocalTerminalSession(terminalID: "fault-first")
        let second = LocalTerminalSession(terminalID: "fault-second")
        do {
            _ = try await first.start(columns: 80, rows: 24)
            FileHandle.standardError.write(Data("FAULT FIRST START SUCCEEDED\n".utf8))
            exit(10)
        } catch {}
        let pids = completedFakePIDs(expectedCount: 1)
        do {
            _ = try await second.start(columns: 80, rows: 24)
            FileHandle.standardError.write(Data("FAULT SECOND START SUCCEEDED\n".utf8))
            exit(11)
        } catch {}
        await waitForProductionReap(pids)
        FileHandle.standardOutput.write(Data("FAULT GATE BLOCKED\n".utf8))
    }

    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "hold"
        if mode == "fault" {
            await exerciseFaultGate()
            return
        }

        let sessions = (0..<8).map { LocalTerminalSession(terminalID: "session-\($0)") }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for session in sessions {
                    group.addTask { _ = try await session.start(columns: 80, rows: 24) }
                }
                try await group.waitForAll()
            }
        } catch {
            FileHandle.standardError.write(Data("START FAILED: \(error)\n".utf8))
            exit(1)
        }

        if mode == "stop" {
            FileHandle.standardOutput.write(Data("READY\n".utf8))
            await waitForController()
            let pids = completedFakePIDs(expectedCount: 8)
            for session in sessions { await session.stop() }
            await waitForProductionReap(pids)
            FileHandle.standardOutput.write(Data("STOPPED\n".utf8))
            return
        }

        FileHandle.standardOutput.write(Data("READY\n".utf8))
        while true {
            try? await Task.sleep(for: .seconds(60))
        }
    }
}
