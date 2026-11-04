import Foundation

private nonisolated struct Status: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32
    let live: Int
    let holders: [Holder]
}
private nonisolated struct RunReceipt: Decodable, Sendable { let address: String; let pid: UInt32? }
private nonisolated struct TerminalRecord: Decodable, Sendable { let cols: UInt16; let rows: UInt16; let state: String }
private nonisolated struct Stopped: Decodable, Sendable { let stopped: Bool }
private enum TestFailure: Error { case assertion(String) }

@main @MainActor private struct HcTerminalSessionTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw TestFailure.assertion(label) }; checks += 1
    }
    static func params(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    static func readUntil(_ stream: AsyncStream<Data>, accumulator: inout Data, needle: String,
                          deadline: ContinuousClock.Instant) async throws {
        let target = Data(needle.utf8)
        while !accumulator.contains(target) {
            guard ContinuousClock.now < deadline else { throw TestFailure.assertion("output missing: \(needle)") }
            for await bytes in stream { accumulator.append(bytes); break }
        }
        checks += 1
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, ["0.1.17"].contains(args[5]) else { throw TestFailure.assertion("missing pinned core version") }
        let binary = URL(fileURLWithPath: args[1]), home = URL(fileURLWithPath: args[2])
        let peer = args[3], report = URL(fileURLWithPath: args[4])
        for part in ["", "state", "config", "runtime"] {
            try FileManager.default.createDirectory(at: home.appending(path: part), withIntermediateDirectories: true)
        }
        let env = ["PATH":"/usr/bin:/bin", "HOME":home.path, "XDG_STATE_HOME":home.appending(path:"state").path,
                   "XDG_CONFIG_HOME":home.appending(path:"config").path, "XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
                   "HC_SESSION":"owned", "HC_SOCKET":home.appending(path:"c.sock").path,
                   "SSH_CONNECTION":"owned-fixture-no-launchd", "DO_NOT_TRACK":"1"]
        let config = CoreProcessTransport.Configuration(executable: binary, environment: env, directory: home)
        let transport = try CoreProcessTransport(configuration: config)
        let connection = try CoreRPCConnection(transport: transport, requiredMethods: ["terminal.run","terminal.attach","terminal.get","terminal.kill","server.status","server.stop"])
        var owned: [UInt32] = []
        var session: HcTerminalSession?
        var failure: (any Error)?
        do {
            let hello = try await connection.connect()
            try check(hello.version == "0.1.17", "pinned official 0.1.17")
            let fresh: Status = try await connection.call("server.status").result()
            owned = [fresh.pid]
            try JSONSerialization.data(withJSONObject: ["corePID": fresh.pid]).write(to: report, options: .atomic)
            try check(fresh.live == 0, "fresh private core")
            let run: RunReceipt = try await connection.call("terminal.run", parameters: try params([
                "argv":["/usr/bin/python3","-I","-S","-B",peer],"cwd":home.path,"keep":false,"no_parent":true,"no_notify":true
            ])).result()
            let status: Status = try await connection.call("server.status").result()
            owned = Array(Set(owned + status.holders.map(\.pid) + [run.pid].compactMap { $0 }))
            try JSONSerialization.data(withJSONObject: ["corePID": fresh.pid, "ownedPIDs": owned]).write(to: report, options: .atomic)
            try check(run.pid != nil, "owned run has a live PID")
            let attach = HcTerminalSession(connection: connection, terminalID: run.address, timeout: .seconds(5))
            session = attach
            let stream = try await attach.start(columns: 80, rows: 24)
            var received = Data()
            try await readUntil(stream, accumulator: &received, needle: "READY", deadline: .now.advanced(by: .seconds(10)))
            try await attach.write(Data("hello\r".utf8))
            try await readUntil(stream, accumulator: &received, needle: "GOT:hello", deadline: .now.advanced(by: .seconds(10)))
            try check(received.count < (1 << 20), "bounded attach output")
            try await attach.resize(columns: 100, rows: 30)
            var grid: TerminalRecord = try await connection.call("terminal.get", parameters: try params(["terminal": run.address])).result()
            let gridDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (grid.cols != 100 || grid.rows != 30) && ContinuousClock.now < gridDeadline {
                try await Task.sleep(for: .milliseconds(50))
                grid = try await connection.call("terminal.get", parameters: try params(["terminal": run.address])).result()
            }
            try check(grid.cols == 100 && grid.rows == 30, "resize reached the terminal")
            await attach.stop(); session = nil
            let afterAttach: Status = try await connection.call("server.status").result()
            try check(afterAttach.live == 1, "attach close must not end the program")
            let killed: TerminalRecord = try await connection.call("terminal.kill", parameters: try params(["terminal": run.address])).result()
            try check(killed.state == "finished", "explicit kill of owned program")
        } catch { failure = error }
        if let session { await session.stop() }
        let stop: Stopped? = try? await connection.call("server.stop").result()
        try await connection.close()
        let snapshot = await transport.snapshot()
        let passed = failure == nil && stop?.stopped == true && snapshot.reaped
        var result: [String: Any] = ["passed": passed, "checks": checks, "stopAcknowledged": stop?.stopped == true,
                                   "connectChildReaped": snapshot.reaped, "ownedPIDs": owned]
        if let failure { result["failure"] = String(describing: failure) }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: .atomic)
        guard passed else { throw failure ?? TestFailure.assertion("cleanup unconfirmed") }
        print("PASS hc terminal attach/session: \(checks) checks")
    }
}
