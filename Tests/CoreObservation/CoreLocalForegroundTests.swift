import Foundation
import Darwin

private enum TestFailure: Error { case failed(String) }

@main private struct CoreLocalForegroundTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw TestFailure.failed(message) }
            checks += 1
        }
        func rejects(_ expected: CoreLocalForegroundFailure, _ operation: () throws -> Void) throws {
            do { try operation(); throw TestFailure.failed("accepted invalid observation") }
            catch let failure as CoreLocalForegroundFailure { try check(failure == expected, "wrong rejection: \(failure)") }
        }
        struct Report: Decodable { let anchor: Int32; let group: Int32; let members: [Int32] }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = ["-I", "-S", "-B", CommandLine.arguments[2]]
        process.environment = ["PATH":"/usr/bin:/bin", "HOME":CommandLine.arguments[3], "TMPDIR":CommandLine.arguments[3]]
        process.currentDirectoryURL = URL(fileURLWithPath: CommandLine.arguments[3])
        process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        var stopped = false
        defer {
            if !stopped { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
            try? output.fileHandleForReading.close()
        }
        func read() throws -> Report {
            var bytes = Data()
            while bytes.last != 10 {
                guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, bytes.count < 4096 else {
                    throw TestFailure.failed("fixture EOF/oversized reply")
                }
                bytes.append(byte)
            }
            return try JSONDecoder().decode(Report.self, from: bytes)
        }
        func command(_ value: String) throws -> Report {
            try input.fileHandleForWriting.write(contentsOf: Data(value.utf8)); return try read()
        }
        try rejects(.invalidPID) { _ = try CoreLocalForeground.anchor(programPID: 0) }
        try rejects(.invalidPID) { _ = try CoreLocalForeground.anchor(programPID: 1) }
        try rejects(.invalidPID) { _ = try CoreLocalForeground.anchor(programPID: -1) }
        try rejects(.unavailable) { _ = try CoreLocalForeground.anchor(programPID: Int32.max) }
        let initial = try read()
        var owned = [process.processIdentifier, initial.anchor]
        let anchor = try CoreLocalForeground.anchor(programPID: initial.anchor)
        try check(anchor.sessionID == initial.anchor, "kernel session leader")
        let shell = try CoreLocalForeground.snapshot(for: anchor)
        try check(shell.isAnchorOnlyForeground && shell.members.map(\.pid) == initial.members, "initial anchor-only group")
        try check(shell.processGroupID == initial.group, "initial group matches owned PTY")
        try rejects(.invalidLimit) { _ = try CoreLocalForeground.snapshot(for: anchor, memberLimit: 0) }
        try rejects(.invalidLimit) { _ = try CoreLocalForeground.snapshot(for: anchor, memberLimit: CoreLocalForeground.maximumMembers + 1) }
        let falseStamp = CoreLocalProcessStamp(pid: anchor.program.pid, parentPID: anchor.program.parentPID,
                                              startSeconds: anchor.program.startSeconds + 1, startMicroseconds: anchor.program.startMicroseconds)
        try rejects(.changed) { _ = try CoreLocalForeground.snapshot(for: .init(program: falseStamp, sessionID: anchor.sessionID, ttyDevice: anchor.ttyDevice)) }
        try rejects(.changed) { _ = try CoreLocalForeground.snapshot(for: .init(program: anchor.program, sessionID: anchor.sessionID + 1, ttyDevice: anchor.ttyDevice)) }
        try rejects(.changed) { _ = try CoreLocalForeground.snapshot(for: .init(program: anchor.program, sessionID: anchor.sessionID, ttyDevice: anchor.ttyDevice ^ 1)) }
        let job = try command("f")
        owned += job.members
        let foreground = try CoreLocalForeground.snapshot(for: anchor)
        try check(foreground.members.map(\.pid) == job.members.sorted(), "all pipeline members, not just leader")
        try check(foreground.members.count == 2 && foreground.processGroupID == job.group, "owned job group")
        try check(!foreground.isAnchorOnlyForeground, "not shell just because anchor survives")
        try rejects(.notLocalTerminal) { _ = try CoreLocalForeground.anchor(programPID: job.members[0]) }
        try rejects(.limitExceeded) { _ = try CoreLocalForeground.snapshot(for: anchor, memberLimit: 1) }
        let leaderless = try command("l")
        let survivor = try CoreLocalForeground.snapshot(for: anchor)
        try check(survivor.members.map(\.pid) == leaderless.members && survivor.processGroupID == job.group,
                  "leaderless foreground group retains actual surviving member")
        try check(!survivor.members.contains(where: { $0.pid == survivor.processGroupID }), "no invented leader entry")
        let returned = try command("s")
        let again = try CoreLocalForeground.snapshot(for: anchor)
        try check(again.isAnchorOnlyForeground && again.members.map(\.pid) == returned.members, "private job retired and anchor foreground restored")
        try check(again.anchor == anchor, "same PTY/session anchor across job switches")
        try input.fileHandleForWriting.close(); process.waitUntilExit(); stopped = true
        try check(process.terminationStatus == 0 && process.terminationReason == .exit, "fixture clean exit")
        try rejects(.unavailable) { _ = try CoreLocalForeground.snapshot(for: anchor) }
        for pid in owned { try check(kill(pid, 0) == -1 && errno == ESRCH, "owned PID still alive") }
        let report: [String: Any] = ["passed":true,"checks":checks,"ownedPIDs":owned,"ownedProcessesExited":true,
                                    "argvRead":false,"environmentRead":false,"userCoreUsed":false,"browserAuthorityGranted":false]
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
        print("PASS local foreground observation: \(checks) checks; private PTY, no argv/env or browser authority")
    }
}
