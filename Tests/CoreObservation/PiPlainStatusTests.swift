import Foundation
import ShepherdKit
import SwiftTerm

private nonisolated struct PlainPiPlan: Decodable {
    let binary: String
    let home: String
    let work: String
    let output: String
    let environment: [String: String]
}
private nonisolated struct PlainCoreStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let core: CoreHello.Identity
    let pid: UInt32
    let live: Int
    let holders: [Holder]
}
private nonisolated struct PlainStopped: Decodable, Sendable { let stopped: Bool }
private nonisolated enum PlainFailure: Error { case assertion(String) }

@MainActor private final class PlainPiRenderer: @preconcurrency TerminalDelegate {
    var replies: [Data] = []
    var replyBytes = 0
    var failure: String?
    var retiring = false
    var raw = Data()
    lazy var terminal = Terminal(delegate: self)
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard replies.count < 128, replyBytes + data.count <= 65536 else {
            failure = "renderer reply limit"; return
        }
        replies.append(Data(data)); replyBytes += data.count
    }
    func isProcessTrusted(source: Terminal) -> Bool { false }
    func takeReplies() -> [Data] {
        let result = replies; replies.removeAll(); replyBytes = 0; return result
    }
    func text() -> String {
        (0..<terminal.rows).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                                                       characterProvider: terminal.getCharacter)
        }.joined(separator: "\n")
    }
}
@MainActor private final class PlainPiEvents {
    var statuses: [(terminal: String, state: String)] = []
    var failure: String?
    var retiring = false
}

/// Actual unmodified Pi TUI. No extension, settings, prompt, provider, status
/// override or session injection. Only private fixture identity authorizes cleanup.
@main @MainActor private struct PiPlainStatusTests {
    static func require(_ value: Bool, _ name: String) throws {
        guard value else { throw PlainFailure.assertion(name) }
    }
    static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Plain Pi status failed; see private report\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let plan = try JSONDecoder().decode(PlainPiPlan.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let out = URL(fileURLWithPath: plan.output), home = URL(fileURLWithPath: plan.home)
        let report = out.appending(path: "report.json")
        try require(!plan.environment.keys.contains(where: { $0.hasPrefix("PI_") || $0.contains("TOKEN") || $0.contains("API_KEY") }), "no Pi overrides or credentials")
        let transport = try CoreProcessTransport(configuration: .init(executable: URL(fileURLWithPath: plan.binary), environment: plan.environment, directory: home))
        let rpc = try CoreRPCConnection(transport: transport)
        let board = HcTerminalBoard(connection: rpc)
        let renderer = PlainPiRenderer(), events = PlainPiEvents()
        var eventStream: CoreStream?, session: HcTerminalSession?
        var workspaceModel: HcWorkspaceModel?, modelTransport: CoreProcessTransport?
        var eventTask: Task<Void, Never>?, renderTask: Task<Void, Never>?
        var known: HcTerminalRecord?, coreOwned = false, stopped = false
        var pids = Set<UInt32>(), checks = 0
        var values: [String: Any] = ["argv": ["pi"], "modelPrompts": 0, "providerLogin": false,
                                    "appInjection": false, "forcedProgramStatus": false,
                                    "workingBlockedDoneError": "NOTRUN", "guiQualified": false]
        var failure: String?
        func save() throws {
            values["ownedPIDs"] = Array(pids).sorted(); values["checks"] = checks
            try json(values).write(to: report, options: .atomic)
        }
        func check(_ value: Bool, _ name: String) throws { try require(value, name); checks += 1 }
        do {
            let hello = try await rpc.connect()
            let initial: PlainCoreStatus = try await rpc.call("server.status").result()
            try check(hello.version == "0.1.17" && initial.core.id == hello.core.id && initial.pid > 1 && initial.live == 0, "fresh private official core")
            coreOwned = true; pids.insert(initial.pid); pids.formUnion(initial.holders.map(\.pid))
            if let pid = await transport.snapshot().childPID, let unsigned = UInt32(exactly: pid) { pids.insert(unsigned) }
            values["coreID"] = hello.core.id; values["corePID"] = initial.pid
            try save()
            // A separate real product workspace subscriber, not a fixture's
            // manually assigned terminal array. Persistence is inert because
            // this observer performs no workspace/run/recovery mutations.
            let observerTransport = try CoreProcessTransport(configuration: .init(executable: URL(fileURLWithPath: plan.binary), environment: plan.environment, directory: home))
            modelTransport = observerTransport
            let observerRPC = try CoreRPCConnection(transport: observerTransport)
            let observerHello = try await observerRPC.connect()
            let model = HcWorkspaceModel(connection: observerRPC, saveRecovery: { _ in }, saveFocus: { _ in })
            workspaceModel = model
            if let pid = await observerTransport.snapshot().childPID, let unsigned = UInt32(exactly: pid) { pids.insert(unsigned) }
            try save()
            try await model.start()
            try check(observerHello.core.id == hello.core.id && model.state == .connected && model.coreID == hello.core.id && model.terminals.isEmpty,
                      "real product workspace observer on the same empty core")
            let stream = try await rpc.openStream("events.subscribe")
            eventStream = stream
            eventTask = Task { @MainActor in
                do {
                    var lines = try CoreEventLines()
                    while let packet = try await stream.next() {
                        if packet.frame.kind == .close { return }
                        try lines.receive(packet.frame.payload) { bytes in
                            guard let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                                  let params = envelope["params"] as? [String: Any], params["type"] as? String == "status",
                                  let terminal = params["terminal"] as? String, let data = params["data"] as? [String: Any],
                                  let status = data["status"] as? [String: Any], let state = status["state"] as? String else { return }
                            try require(events.statuses.count < 128 && state.utf8.count <= 32, "status event limit")
                            events.statuses.append((terminal, state))
                        }
                        try await stream.acknowledge(packet)
                    }
                } catch { if !events.retiring && !Task.isCancelled { events.failure = String(describing: error) } }
            }
            let run = try await board.run(argv: ["pi"], cwd: plan.work)
            known = run; values["terminalID"] = run.address
            if let pid = run.pid { pids.insert(pid) }
            let running: PlainCoreStatus = try await rpc.call("server.status").result()
            pids.formUnion(running.holders.map(\.pid)); try save()
            try check(CoreTerminalID.isCanonical(run.address) && run.argv == ["pi"] && run.pid != nil, "exact canonical plain-Pi run receipt")
            let attach = board.attach(run.address)
            session = attach
            try await attach.start(columns: 100, rows: 32)
            renderer.terminal.resize(cols: 100, rows: 32)
            renderTask = Task { @MainActor in
                do {
                    while let packet = try await attach.nextOutput() {
                        try require(renderer.raw.count + packet.frame.payload.count <= 2 << 20, "VT output limit")
                        renderer.raw.append(packet.frame.payload)
                        renderer.terminal.feed(buffer: Array(packet.frame.payload)[...])
                        for reply in renderer.takeReplies() { try await attach.writeAndFlush(reply) }
                        try await attach.acknowledgeOutput(packet) // Only after actual product renderer consumption.
                    }
                } catch { if !renderer.retiring && !Task.isCancelled { renderer.failure = String(describing: error) } }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            var observed: HcTerminalRecord?
            repeat {
                let fresh = try await board.get(run.address)
                values["lastLifecycle"] = fresh.state; values["lastReported"] = fresh.reported
                values["lastStatus"] = fresh.status?.state ?? "unreported"
                if fresh.state == "live" && fresh.reported && fresh.status?.state == "idle" { observed = fresh; break }
                if fresh.state != "live" { break }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            try save()
            try check(observed != nil, "plain Pi default OSC idle report")
            let fresh = observed!
            try check(fresh.pid == run.pid && fresh.createdMs == run.createdMs && fresh.argv == ["pi"], "same known program, not status-derived authority")
            let modelDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.terminals.contains(where: { $0.address == run.address && $0.reported && $0.status?.state == "idle" }) && ContinuousClock.now < modelDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let presented = model.terminals.first { $0.address == run.address }
            try check(model.state == .connected && presented?.pid == run.pid && presented?.createdMs == run.createdMs &&
                      HcProgramStatusPresentation.state(reported: presented?.reported == true, word: presented?.status?.state) == .idle,
                      "real product subscription feeds the same sidebar presentation, without injected model state")
            values["workspaceObservationQualified"] = true
            let eventDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !events.statuses.contains(where: { $0.terminal == run.address && $0.state == "idle" }) && ContinuousClock.now < eventDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(events.statuses.contains(where: { $0.terminal == run.address && $0.state == "idle" }) && events.failure == nil, "actual Pi status event consumed")
            let response = try await rpc.call("terminal.get", parameters: json(["terminal": run.address]))
            let attention: CoreAttentionRecord = try response.result()
            var feed = CoreAttentionFeed(coreID: hello.core.id, epoch: rpc.epoch)
            _ = try feed.observe([], epoch: rpc.epoch, sequence: 0, baseline: true)
            let admitted = try feed.observe([attention], epoch: rpc.epoch, sequence: 1)
            let repeated = try feed.observe([attention], epoch: rpc.epoch, sequence: 2)
            try check(attention.reported && attention.status?.state == "idle" && admitted.isEmpty && repeated.isEmpty && feed.pendingCount == 0,
                      "production attention decoder accepts real idle without startup notification")
            try check(renderer.failure == nil && renderer.raw.count > 0, "actual product renderer and lossless attach")
            values["startupStatusQualified"] = true
            values["statusEvents"] = events.statuses.filter { $0.terminal == run.address }.map(\.state)
            renderer.retiring = true
            try await attach.stop(); renderTask?.cancel(); if let renderTask { await renderTask.value }
            session = nil; renderTask = nil
            try await model.disconnect()
            workspaceModel = nil
            let observerRetired = await observerTransport.snapshot()
            try check(observerRetired.closed && observerRetired.reaped, "product model observer retires its own connection")
            let detached = try await board.get(run.address)
            try check(detached.state == "live" && detached.pid == run.pid && detached.createdMs == run.createdMs && detached.status?.state == "idle", "terminal/model detach preserves same Pi and status")
            values["detachPreservesPi"] = true
        } catch { failure = String(describing: error) }
        // Never replay run/kill/input. Fresh exact receipt/incarnation is required
        // even in this private fixture; fallback only stops this isolated core.
        renderer.retiring = true; events.retiring = true
        if let session { do { try await session.stop() } catch { failure = failure ?? "attach retirement" } }
        renderTask?.cancel(); if let renderTask { await renderTask.value }
        if let eventStream { do { try await eventStream.close() } catch { failure = failure ?? "event retirement" } }
        eventTask?.cancel(); if let eventTask { await eventTask.value }
        if let workspaceModel {
            do { try await workspaceModel.disconnect() } catch { failure = failure ?? "product model retirement" }
        }
        if let modelTransport {
            let retired = await modelTransport.snapshot()
            if !retired.closed || !retired.reaped { failure = failure ?? "model transport retirement" }
        }
        if let known {
            do {
                let fresh = try await board.get(known.address)
                try require(fresh.address == known.address && fresh.createdMs == known.createdMs, "cleanup incarnation changed")
                if fresh.state == "live" {
                    try require(fresh.pid == known.pid, "cleanup PID changed")
                    let ended = try await board.kill(known.address)
                    try require(ended.state == "finished", "known terminal kill not confirmed")
                    values["knownTerminalKillCount"] = 1
                }
            } catch { failure = failure ?? "known terminal retirement" }
        }
        if coreOwned {
            let reply: PlainStopped? = try? await rpc.call("server.stop").result()
            stopped = reply?.stopped == true
        }
        do { try await rpc.close() } catch { failure = failure ?? "connection retirement" }
        let retired = await transport.snapshot()
        if !stopped || !retired.closed || !retired.reaped { failure = failure ?? "owned core/connect retirement" }
        try renderer.raw.write(to: out.appending(path: "pi-startup.vt"))
        try Data(renderer.text().utf8).write(to: out.appending(path: "pi-startup-screen.txt"))
        values["rawBytes"] = renderer.raw.count; values["stopAcknowledged"] = stopped
        values["connectChildReaped"] = retired.reaped; values["passed"] = failure == nil
        if let failure { values["failure"] = failure }
        try save()
        if let failure { throw PlainFailure.assertion(failure) }
        print("PASS \(checks) plain Pi startup/status/attach/detach checks; working/blocked/done/error and provider workload NOTRUN")
    }
}
