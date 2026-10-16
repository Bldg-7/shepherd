import Foundation

/// The subscription against a real herdr: a test server of its own, started
/// and stopped by run-live-update-tests.py with its home, config and
/// sockets in a scratch directory — never the herdr anyone works in. The
/// first argument is that directory; its socket is `t.sock` there.
///
/// Checks what the design rests on: herdr acknowledges the subscription, a
/// terminal title set with OSC 2 comes as `pane_updated`, a split as
/// `pane_created`, and `pane.rename` with no event at all; and a
/// `MachineMonitor` over `LocalHerdrTransport` shows a new title, a new pane
/// and an agent's new status within a second.
@main struct LiveHerdrSubscribeTests {
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        print("PASS: " + name)
    }

    static func eventually(_ name: String, seconds: Double = 5, _ condition: () -> Bool) async -> Duration {
        let start = ContinuousClock.now
        let deadline = start + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() {
                let elapsed = ContinuousClock.now - start
                print("PASS: \(name) (\(elapsed.formatted(.units(allowed: [.milliseconds]))))")
                return elapsed
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        print("FAIL: " + name)
        preconditionFailure(name)
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard CommandLine.arguments.count > 1, FileManager.default.changeCurrentDirectoryPath(CommandLine.arguments[1]) else {
            fatalError("usage: LiveHerdrSubscribeTests <test server directory>")
        }
        let transport = LocalHerdrTransport(socketPath: "t.sock")
        let client = HerdrClient(transport: transport)
        let created = try await transport.send(method: "workspace.create", params: .object(["label": .string("probe"), "focus": .bool(false)]))
        guard let p1 = created["root_pane"]?["pane_id"]?.stringValue else { fatalError("workspace.create named no pane") }

        // The subscription itself.
        let subscription = try await client.subscribeToChanges(statusOf: [])
        check(true, "live: herdr acknowledged the subscription")
        let events = EventLog()
        let reader = Task {
            for try await line in subscription.lines {
                if case .change(let event) = HerdrStreamLine(line) { events.events.append(event) }
            }
        }
        try await Task.sleep(for: .milliseconds(300))

        var mark = events.events.count
        _ = try await transport.send(method: "pane.send_text", params: .object(["pane_id": .string(p1), "text": .string("printf '\\033]2;Live-Title-A\\007'\r")]))
        let titled = await eventually("live: an OSC 2 title comes as pane_updated") { events.events[mark...].contains("pane_updated") }
        check(titled < .seconds(1), "live: within a second")

        mark = events.events.count
        let split = try await transport.send(method: "pane.split", params: .object(["target_pane_id": .string(p1), "direction": .string("right"), "focus": .bool(false)]))
        _ = await eventually("live: a split comes as pane_created") { events.events[mark...].contains("pane_created") }
        let p2 = split["pane"]?["pane_id"]?.stringValue

        try await Task.sleep(for: .milliseconds(500))
        mark = events.events.count
        try await client.renamePane(p1, to: "Renamed", on: nil)
        try await Task.sleep(for: .milliseconds(1500))
        check(events.events.count == mark, "live: pane.rename comes with no event (\(events.events[mark...]))")
        try await client.renamePane(p1, to: nil, on: nil)
        reader.cancel()
        subscription.close()

        // A monitor keeping up with the same herdr.
        let monitor = MachineMonitor(
            makeClient: { HerdrClient(transport: LocalHerdrTransport(socketPath: "t.sock")) },
            pinHostKey: { _ in },
            pollInterval: .seconds(3),
            listener: nil
        )
        let board = Task { await monitor.holdForBoard() }
        _ = await eventually("live monitor: listed") { monitor.hasLoaded }
        try await Task.sleep(for: .milliseconds(800))

        _ = try await transport.send(method: "pane.send_text", params: .object(["pane_id": .string(p1), "text": .string("printf '\\033]2;Live-Title-B\\007'\r")]))
        let title = await eventually("live monitor: a new terminal title shows") {
            monitor.panes.first { $0.paneID == p1 }?.terminalTitle == "Live-Title-B"
        }
        check(title < .seconds(1), "live monitor: within a second")

        let before = Set(monitor.panes.map(\.paneID))
        _ = try await transport.send(method: "pane.split", params: .object(["target_pane_id": .string(p2 ?? p1), "direction": .string("down"), "focus": .bool(false)]))
        let opened = await eventually("live monitor: a new pane shows") { Set(monitor.panes.map(\.paneID)).subtracting(before).count == 1 }
        check(opened < .seconds(1), "live monitor: within a second")

        func report(_ state: String, seq: Int) async throws {
            _ = try await transport.send(method: "pane.report_agent", params: .object([
                "pane_id": .string(p1), "source": .string("custom:probe"), "agent": .string("probe"),
                "state": .string(state), "seq": .number(Double(seq)),
            ]))
        }
        try await report("working", seq: 1)
        _ = await eventually("live monitor: an agent starting shows") { monitor.panes.first { $0.paneID == p1 }?.state == .working }
        try await Task.sleep(for: .milliseconds(800))
        try await report("blocked", seq: 2)
        let blocked = await eventually("live monitor: its status changing shows") { monitor.panes.first { $0.paneID == p1 }?.state == .blocked }
        check(blocked < .seconds(1), "live monitor: within a second")

        board.cancel()
        _ = await eventually("live monitor: stops once the board has gone") { !monitor.isActive }
    }
}

final class EventLog {
    var events: [String] = []
}
