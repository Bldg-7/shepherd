import Foundation
import Darwin
import ShepherdKit
import SwiftTerm

private nonisolated struct CLIPlan: Decodable {
    struct Case: Decodable { let name: String; let argv: [String]; let cwd: String; let environment: [String:String]; let tracePath: String?; let expectedSessionID: String? }
    let binary: String; let coreHome: String; let output: String; let cases: [Case]
}
private nonisolated struct CLIStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let live: Int; let holders: [Holder]
}
private nonisolated struct CLIRecord: Decodable, Sendable {
    struct Word: Decodable, Sendable { let state: String; let app: String }
    let address: String; let state: String; let pid: UInt32?; let exit_code: Int?; let reason: String?
    let status: Word?; let reported: Bool
}
private nonisolated struct CLIRun: Decodable, Sendable { let address: String; let pid: UInt32? }
private nonisolated struct CLIStop: Decodable, Sendable { let stopped: Bool }
private enum CaptureFailure: Error { case failed(String) }
@MainActor private final class CLISink: @preconcurrency TerminalDelegate {
    var responses = 0
    func send(source: Terminal, data: ArraySlice<UInt8>) { responses += data.count }
    func isProcessTrusted(source: Terminal) -> Bool { false }
}
@MainActor private final class CLICapture {
    let sink = CLISink()
    lazy var model = Terminal(delegate: sink)
    var raw = Data()
    var failure: String?
    var grids = 0
    func text() -> String {
        (0..<model.rows).compactMap {
            model.getLine(row:$0)?.translateToString(trimRight:true, skipNullCellsFollowingWide:true, characterProvider:model.getCharacter)
        }.joined(separator:"\n").replacingOccurrences(of:"\0",with:" ")
    }
}

@main @MainActor private struct CLIStartupCapture {
    static func json(_ value: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value, options:[.prettyPrinted,.sortedKeys]) }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("CLI capture failed; see private report\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let plan = try JSONDecoder().decode(CLIPlan.self, from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let output = URL(fileURLWithPath:plan.output), home = URL(fileURLWithPath:plan.coreHome)
        guard (1...4).contains(plan.cases.count), Set(plan.cases.map(\.name)).count == plan.cases.count,
              plan.cases.allSatisfy({ ["claude-clean","claude-bare","codex","pi"].contains($0.name) }) else { throw CaptureFailure.failed("invalid cases") }
        for name in ["", "state", "config", "runtime"] { try FileManager.default.createDirectory(at:home.appending(path:name),withIntermediateDirectories:true) }
        let env = ["HOME":home.path,"PATH":"/usr/bin:/bin","XDG_STATE_HOME":home.appending(path:"state").path,
                   "XDG_CONFIG_HOME":home.appending(path:"config").path,"XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
                   "HC_SESSION":"owned","HC_SOCKET":home.appending(path:"c.sock").path,"DO_NOT_TRACK":"1","LANG":"en_US.UTF-8"]
        let transport = try CoreProcessTransport(configuration:.init(executable:URL(fileURLWithPath:plan.binary),environment:env,directory:home))
        let connection = try CoreRPCConnection(transport:transport)
        var owned = Set<UInt32>(), rows:[[String:Any]] = [], failure:(any Error)?
        var eventStream:CoreStream?, eventTask:Task<Void,Never>?
        var statuses:[String:[[String:String]]] = [:]
        var eventFailure = false
        let report = output.appending(path:"report.json")
        do {
            _ = try await connection.connect()
            let initial: CLIStatus = try await connection.call("server.status").result()
            guard initial.live == 0 else { throw CaptureFailure.failed("core not fresh") }
            owned.insert(initial.pid)
            try json(["ownedPIDs":Array(owned)]).write(to:report,options:.atomic)
            let events = try await connection.openStream("events.subscribe")
            eventStream = events
            eventTask = Task { @MainActor in
                do {
                    var lines = try CoreEventLines()
                    while let packet = try await events.next() {
                        if packet.frame.kind == .close { break }
                        try lines.receive(packet.frame.payload) { bytes in
                            guard let value=try JSONSerialization.jsonObject(with:bytes) as? [String:Any], value["method"] as? String == "event",
                                  let params=value["params"] as? [String:Any],params["type"] as? String == "status",
                                  let terminal=params["terminal"] as? String,let data=params["data"] as? [String:Any] else { return }
                            guard statuses.values.reduce(0, { $0+$1.count })<128 else { throw CaptureFailure.failed("event limit") }
                            let word=data["status"] as? [String:Any]
                            statuses[terminal,default:[]].append(["state":String((word?["state"] as? String ?? "cleared").prefix(32)),
                                                               "app":String((word?["app"] as? String ?? "none").prefix(32))])
                        }
                        try await events.acknowledge(packet)
                    }
                } catch { if !Task.isCancelled { eventFailure = true } }
            }
            for item in plan.cases {
                print("Capture \(item.name): starting private CLI; no prompt",terminator:"\n")
                let run: CLIRun = try await connection.call("terminal.run",parameters:json([
                    "argv":item.argv,
                    "cwd":item.cwd,"env":item.environment,"keep":false])).result()
                if let pid=run.pid { owned.insert(pid) }
                let status: CLIStatus = try await connection.call("server.status").result()
                owned.formUnion(status.holders.map(\.pid))
                try json(["ownedPIDs":Array(owned),"cases":rows]).write(to:report,options:.atomic)
                var active:CoreStream?, observer:CoreStream?, reader:Task<Void,Never>?
                let capture = CLICapture()
                var row:[String:Any] = ["name":item.name,"terminal":run.address,"modelPrompts":0,
                    "providerAuthenticationQualified":false,"interactiveReadyQualified":false,"browserAuthorityGranted":false]
                do {
                    let typing = try await connection.openStream("terminal.attach",parameters:json(["terminal":run.address,"cols":100,"rows":32,"history":0]))
                    active=typing
                    let stream = try await connection.openStream("terminal.attach",parameters:json(["terminal":run.address,"cols":100,"rows":32,"history":0,"observe":true,"resize_notifications":true]))
                    observer=stream
                    let initialSequence = try CorePassiveScreenSequence(stream:stream)
                    reader = Task { @MainActor in
                        var sequence=initialSequence
                        defer { sequence.retire() }
                        do {
                            while let packet=try await stream.next() {
                                switch try sequence.consume(packet) {
                                case .resize(let cols,let rows): capture.model.resize(cols:Int(cols),rows:Int(rows)); capture.grids += 1
                                case .data(let bytes):
                                    guard capture.raw.count+bytes.count<=2<<20 else { throw CaptureFailure.failed("output limit") }
                                    capture.raw.append(bytes);capture.model.feed(buffer:Array(bytes)[...]);try await stream.acknowledge(packet)
                                case .closed:return
                                }
                            }
                        } catch { if !Task.isCancelled { capture.failure="stream-or-render-failure" } }
                    }
                    // Measurement window only, NOT a readiness or snapshot-complete proof.
                    try await Task.sleep(for:.seconds(6))
                    let before:CLIRecord = try await connection.call("terminal.get",parameters:json(["terminal":run.address])).result()
                    row["lifecycleBeforeCancel"]=before.state
                    row["reported"]=before.reported
                    row["coreReportedState"]=before.status?.state ?? "unreported"
                    row["coreReportedApp"]=before.status?.app ?? "unreported"
                    var capturedAnchor:CoreLocalTerminalAnchor?
                    if let pid=run.pid,let local=Int32(exactly:pid),let anchor=try? CoreLocalForeground.anchor(programPID:local),
                       let sample=try? CoreLocalForeground.snapshot(for:anchor) {
                        row["localAnchorObserved"]=true;row["foregroundMemberCount"]=sample.members.count;capturedAnchor=anchor
                        var path=[CChar](repeating:0,count:4096)
                        if proc_pidpath(local,&path,UInt32(path.count))>0 {
                            row["expectedExecutableObserved"]=URL(fileURLWithPath:String(cString:path)).resolvingSymlinksInPath().path == item.argv.first
                        }
                    } else { row["localAnchorObserved"]=false }
                    try Data(capture.text().utf8).write(to:output.appending(path:item.name+"-screen-before.txt"))
                    if item.name == "pi", let trace=item.tracePath, let expected=item.expectedSessionID {
                        func entries() throws -> [[String:Any]] {
                            let data=try Data(contentsOf:URL(fileURLWithPath:trace))
                            guard data.count<=65536 else { throw CaptureFailure.failed("trace limit") }
                            return try data.split(separator:10).map { try JSONSerialization.jsonObject(with:Data($0)) as? [String:Any] ?? [:] }
                        }
                        let initial=try entries()
                        let startup=initial.first { $0["event"] as? String == "session_start" }
                        let valid=run.pid != nil && startup?["mode"] as? String == "tui" && startup?["sessionID"] as? String == expected &&
                            (startup?["pid"] as? NSNumber)?.uint32Value == run.pid
                        row["nativeSessionStartObserved"]=valid
                        // Only a documented local /new command, no user/model prompt.
                        // The test extension consumes any unexpected ordinary input.
                        if valid, row["expectedExecutableObserved"] as? Bool == true {
                            try await typing.send(Data("/new\r".utf8));try await Task.sleep(for:.seconds(1))
                            let after=try entries()
                            let starts=after.filter { $0["event"] as? String == "session_start" }
                            let ids=starts.compactMap { $0["sessionID"] as? String }
                            row["localNewSessionCommandSent"]=true
                            row["sessionIDChanged"]=ids.count==2 && ids[0] != ids[1]
                            row["oldSessionShutdownObserved"]=after.contains { $0["event"] as? String == "session_shutdown" && $0["sessionID"] as? String == expected }
                            row["unexpectedInputBlocked"]=after.contains { $0["event"] as? String == "unexpected_input_blocked" }
                            if let anchor=capturedAnchor {
                                row["sameProcessAcrossSessionSwitch"]=(try? CoreLocalForeground.snapshot(for:anchor)) != nil
                            }
                        }
                    }
                    if before.state=="live" {
                        try await typing.resize(columns:110,rows:35)
                        try await Task.sleep(for:.seconds(1))
                    }
                    row["observedGrid"]=[capture.model.cols,capture.model.rows]
                    row["resizeFrames"]=capture.grids
                    try Data(capture.text().utf8).write(to:output.appending(path:item.name+"-screen-after.txt"))
                    // Cancel only this owned CLI via its own stream; never submit
                    // text, confirm trust/login/terms, or send input to another pane.
                    for key in [UInt8(3),3,4] {
                        let current:CLIRecord=try await connection.call("terminal.get",parameters:json(["terminal":run.address])).result()
                        if current.state != "live" { break }
                        try await typing.send(Data([key]))
                        try await Task.sleep(for:.milliseconds(300))
                    }
                } catch { row["captureError"]=String(describing:error) }
                let ending:CLIRecord?=try? await connection.call("terminal.get",parameters:json(["terminal":run.address])).result()
                let hadToKill=ending?.state=="live"
                if hadToKill { _ = try await connection.call("terminal.kill",parameters:json(["terminal":run.address])) }
                row["ownedTerminalKillRequired"]=hadToKill
                if let observer { try? await observer.close() }; reader?.cancel(); if let reader { await reader.value }
                if let active { try? await active.close() }
                row["capturedBytes"]=capture.raw.count
                row["discardedReplicaResponseBytes"]=capture.sink.responses
                if let error=capture.failure { row["streamError"]=error }
                if let code=ending?.exit_code { row["exitCodeBeforeKill"]=code }
                try capture.raw.write(to:output.appending(path:item.name+".vt"))
                rows.append(row)
                try json(["ownedPIDs":Array(owned),"cases":rows]).write(to:report,options:.atomic)
            }
        } catch { failure=error }
        if let eventStream { try? await eventStream.close() };eventTask?.cancel();if let eventTask { await eventTask.value }
        for i in rows.indices {
            rows[i]["statusEventsObserved"]=statuses[rows[i]["terminal"] as? String ?? ""] ?? []
            rows[i]["statusHistoryCompleteQualified"]=false
        }
        let stopped:CLIStop?=try? await connection.call("server.stop").result()
        try await connection.close()
        let child=await transport.snapshot()
        let complete=failure==nil && rows.count==plan.cases.count && stopped?.stopped==true && child.reaped
        try json(["captureCompleted":complete,"ownedPIDs":Array(owned),"cases":rows,"stopAcknowledged":stopped?.stopped==true,
                  "connectChildReaped":child.reaped,"modelPrompts":0,"fullAgentParityQualified":false,
                  "parentDescriptorForwarded":false,"realCredentialsUsed":false,"eventCaptureError":eventFailure]).write(to:report,options:.atomic)
        guard complete else { throw failure ?? CaptureFailure.failed("capture/cleanup incomplete") }
        print("Completed isolated CLI observations; not authentication/readiness qualification")
    }
}
