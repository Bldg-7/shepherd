import Foundation

private nonisolated struct Stopped: Decodable, Sendable { let stopped: Bool }
private nonisolated struct Status: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}
private enum TestFailure: Error { case assertion(String) }

@main @MainActor private struct HcTerminalBoardTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw TestFailure.assertion(label) }; checks += 1
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5, ["0.1.17"].contains(args[4]) else { throw TestFailure.assertion("missing pinned version") }
        let binary = URL(fileURLWithPath: args[1]), scopeRoot = URL(fileURLWithPath: args[2])
        let report = URL(fileURLWithPath: args[3])
        let scope = try HcCoreBootstrap.Scope(root: scopeRoot)
        var transport: CoreProcessTransport?
        var connection: CoreRPCConnection?
        var corePID: UInt32?
        var owned: [UInt32] = []
        var failure: (any Error)?
        do {
            let (t, c, hello) = try await HcCoreBootstrap.connect(binary: binary, scope: scope)
            transport = t; connection = c
            try check(hello.version == "0.1.17", "pinned official 0.1.17")
            let board = HcTerminalBoard(connection: c)
            let status: Status = try await c.call("server.status").result()
            corePID = status.pid; owned = [status.pid]
            try JSONSerialization.data(withJSONObject: ["corePID": status.pid]).write(to: report, options: .atomic)
            try check(try await board.list().isEmpty, "fresh board is empty")
            let argv = ["/bin/sh", "-c", "echo BOARD-READY && sleep 30"]
            let run = try await board.run(argv: argv, cwd: scope.root.path, labels: ["3rdr.operation": "board-test"])
            let running: Status = try await c.call("server.status").result()
            owned += running.holders.map(\.pid) + [run.pid].compactMap { $0 }
            try JSONSerialization.data(withJSONObject: ["corePID":status.pid,"ownedPIDs":owned]).write(to:report,options:.atomic)
            try check(run.state == "live" && run.pid != nil, "run returns a live record")
            try check(run.argv == argv, "run record carries exact argv")
            let live = try await board.list()
            try check(live.count == 1 && live[0].address == run.address, "list sees the run")
            try check(live[0].labels["3rdr.operation"] == "board-test", "label is a correlation fact")
            let got = try await board.get(run.address)
            try check(got == live[0], "get matches list")
            // Poll the screen until the program printed its marker.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var text = ""
            while !text.contains("BOARD-READY") {
                guard ContinuousClock.now < deadline else { throw TestFailure.assertion("board marker missing") }
                text = try await board.read(run.address, lines: 0).text
                if !text.contains("BOARD-READY") { try await Task.sleep(for: .milliseconds(50)) }
            }
            checks += 1
            let killed = try await board.kill(run.address)
            try check(killed.state == "finished", "kill ends the program")
            let removed = try await board.remove(run.address)
            try check(removed, "rm removes the finished terminal")
            try check(try await board.list().isEmpty, "board is empty after rm")
            let attachTarget = try await board.run(argv: ["/bin/sleep", "30"])
            let attachedStatus: Status = try await c.call("server.status").result()
            owned = Array(Set(owned + attachedStatus.holders.map(\.pid) + [attachTarget.pid].compactMap { $0 }))
            try JSONSerialization.data(withJSONObject: ["corePID":status.pid,"ownedPIDs":owned]).write(to:report,options:.atomic)
            let session = board.attach(attachTarget.address)
            try await session.start(columns: 80, rows: 24)
            if let packet = try await session.nextOutput(timeout: .seconds(5)) { try await session.acknowledgeOutput(packet) }
            try await session.stop()
            let afterClose = try await board.get(attachTarget.address)
            try check(afterClose.state == "live", "attach still leaves the program live")
            _ = try await board.kill(attachTarget.address)
        } catch { failure = error }
        var stop: Stopped?
        var reaped = false
        if let connection { stop = try? await connection.call("server.stop").result(); try? await connection.close() }
        if let transport { reaped = await transport.snapshot().reaped }
        let passed = failure == nil && stop?.stopped == true && reaped
        var result: [String: Any] = ["passed": passed, "checks": checks, "stopAcknowledged": stop?.stopped == true,
                                   "connectChildReaped": reaped, "ownedPIDs":owned]
        if let corePID { result["corePID"] = corePID }
        if let failure { result["failure"] = String(describing: failure) }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: .atomic)
        guard passed else { throw failure ?? TestFailure.assertion("cleanup unconfirmed") }
        print("PASS hc terminal board: \(checks) checks")
    }
}
