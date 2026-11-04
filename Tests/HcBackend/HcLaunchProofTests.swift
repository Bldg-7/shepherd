import Foundation
#if os(macOS)

private nonisolated struct Status: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32
    let live: Int
    let holders: [Holder]
}
private nonisolated struct RunReceipt: Decodable, Sendable { let address: String; let pid: UInt32? }
private nonisolated struct TerminalRecord: Decodable, Sendable { let state: String }
private nonisolated struct Stopped: Decodable, Sendable { let stopped: Bool }
private enum TestFailure: Error { case assertion(String) }

@main @MainActor private struct HcLaunchProofTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw TestFailure.assertion(label) }; checks += 1
    }
    static func params(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, ["0.1.17"].contains(args[4]) else { throw TestFailure.assertion("missing pinned version") }
        let binary = URL(fileURLWithPath: args[1]), home = URL(fileURLWithPath: args[2])
        let report = URL(fileURLWithPath: args[3])
        for part in ["", "state", "config", "runtime"] {
            try FileManager.default.createDirectory(at: home.appending(path: part), withIntermediateDirectories: true)
        }
        let env = ["PATH":"/usr/bin:/bin", "HOME":home.path, "XDG_STATE_HOME":home.appending(path:"state").path,
                   "XDG_CONFIG_HOME":home.appending(path:"config").path, "XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
                   "HC_SESSION":"owned", "HC_SOCKET":home.appending(path:"c.sock").path,
                   "SSH_CONNECTION":"owned-fixture-no-launchd", "DO_NOT_TRACK":"1"]
        let transport = try CoreProcessTransport(configuration: .init(executable: binary, environment: env, directory: home))
        let connection = try CoreRPCConnection(transport: transport, requiredMethods: ["terminal.run","terminal.get","terminal.kill","server.status","server.stop"])
        var owned: [UInt32] = []
        var failure: (any Error)?
        do {
            let hello = try await connection.connect()
            try check(hello.version == "0.1.17", "pinned official 0.1.17")
            let fresh: Status = try await connection.call("server.status").result()
            owned = [fresh.pid]
            try JSONSerialization.data(withJSONObject: ["corePID": fresh.pid]).write(to: report, options: .atomic)
            let argv = ["/bin/sleep", "30"]
            let run: RunReceipt = try await connection.call("terminal.run", parameters: try params([
                "argv":argv, "cwd":home.path, "keep":false, "no_parent":true, "no_notify":true
            ])).result()
            let status: Status = try await connection.call("server.status").result()
            owned = Array(Set(owned + status.holders.map(\.pid) + [run.pid].compactMap { $0 }))
            try JSONSerialization.data(withJSONObject: ["corePID": fresh.pid, "ownedPIDs": owned]).write(to: report, options: .atomic)
            let identity = try await HcLaunchProof.verify(connection: connection, address: run.address, requestedArgv: argv)
            try check(identity.pid == Int32(run.pid!), "verified PID is the run's PID")
            try check((identity.executablePath as NSString).lastPathComponent == "sleep", "kernel executable is sleep, not swapped")
            try check(identity.foreground.members.contains(identity.foreground.anchor.program), "anchor is in its own foreground group")
            // Negative controls must be nonzero failures, never silent success.
            do { _ = try await HcLaunchProof.verify(connection: connection, address: run.address, requestedArgv: ["/bin/not-sleep", "30"]); throw TestFailure.assertion("argv mismatch accepted") }
            catch HcLaunchProof.Failure.argvMismatch { checks += 1 }
            let killed: TerminalRecord = try await connection.call("terminal.kill", parameters: try params(["terminal": run.address])).result()
            try check(killed.state == "finished", "explicit kill")
            do { _ = try await HcLaunchProof.verify(connection: connection, address: run.address, requestedArgv: argv); throw TestFailure.assertion("finished terminal accepted") }
            catch HcLaunchProof.Failure.notLive { checks += 1 }
        } catch { failure = error }
        let stop: Stopped? = try? await connection.call("server.stop").result()
        try await connection.close()
        let snapshot = await transport.snapshot()
        let passed = failure == nil && stop?.stopped == true && snapshot.reaped
        var result: [String: Any] = ["passed": passed, "checks": checks, "stopAcknowledged": stop?.stopped == true,
                                   "connectChildReaped": snapshot.reaped, "ownedPIDs": owned]
        if let failure { result["failure"] = String(describing: failure) }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: .atomic)
        guard passed else { throw failure ?? TestFailure.assertion("cleanup unconfirmed") }
        print("PASS hc launch owner proof: \(checks) checks")
    }
}
#endif
