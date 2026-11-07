import Foundation
import SwiftTerm
import ShepherdKit
import AppKit

private nonisolated struct NarrowStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}
private nonisolated struct NarrowStopped: Decodable, Sendable { let stopped: Bool }
private nonisolated enum NarrowFailure: Error { case assertion(String) }
@main @MainActor private struct HcNarrowRenderTests {
    static func flat(_ view: TerminalView) -> String {
        let t = view.getTerminal()
        return (0..<t.rows).compactMap { t.getLine(row:$0)?.translateToString(trimRight:true,skipNullCellsFollowingWide:true,characterProvider:t.getCharacter) }.joined()
    }
    static func consume(_ session: HcTerminalSession, view: TerminalView, raw: inout Data, needle: String) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(6)), bytes = Data(needle.utf8)
        while !raw.contains(bytes) {
            guard ContinuousClock.now < deadline, let packet = try await session.nextOutput(timeout:.seconds(3)) else { throw NarrowFailure.assertion("owned fixture output missing") }
            guard raw.count + packet.frame.payload.count < 1 << 20 else { throw NarrowFailure.assertion("bounded output") }
            raw.append(packet.frame.payload)
            view.feed(byteArray:Array(packet.frame.payload)[...])
            try await session.acknowledgeOutput(packet) // Render before CREDIT, just like the app.
        }
    }
    static func main() async throws {
        let binary = URL(fileURLWithPath:CommandLine.arguments[1]), home = URL(fileURLWithPath:CommandLine.arguments[2])
        let report = URL(fileURLWithPath:CommandLine.arguments[4])
        let env = ["PATH":"/usr/bin:/bin","HOME":home.path,"XDG_STATE_HOME":home.appending(path:"state").path,
            "XDG_CONFIG_HOME":home.appending(path:"config").path,"XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
            "HC_SESSION":"owned","HC_SOCKET":home.appending(path:"c.sock").path,"SSH_CONNECTION":"owned-fixture-no-launchd"]
        let transport = try CoreProcessTransport(configuration:.init(executable:binary,environment:env,directory:home))
        let rpc = try CoreRPCConnection(transport:transport)
        let hello = try await rpc.connect()
        guard hello.version == CommandLine.arguments[5] else { throw NarrowFailure.assertion("official version") }
        let board = HcTerminalBoard(connection:rpc)
        let status: NarrowStatus = try await rpc.call("server.status").result()
        var pids: Set<UInt32> = [status.pid]
        var cases: [[String:Any]] = [], failure: (any Error)?, checks = 0
        var session: HcTerminalSession?
        func identities() throws { try JSONSerialization.data(withJSONObject:["ownedPIDs":Array(pids).sorted(),"corePID":status.pid]).write(to:report,options:.atomic) }
        try identities()
        do {
            for columns in [80,6] {
                let program = "import sys,tty,time\nprint('CJK 한글 😀 real SwiftTerm UI',flush=True)\nprint('HC-UI-RENDER-DONE',flush=True)\ninput()\nprint('\\x1b]8;;file:///owned/preview.md\\x1b\\\\Open owned preview\\x1b]8;;\\x1b\\\\',flush=True)\ntty.setraw(sys.stdin.fileno())\nprint('HC-DROP-READY',flush=True)\ntime.sleep(60)\n"
                let record = try await board.run(argv:["/usr/bin/python3","-I","-S","-B","-c",program],cwd:home.path)
                if let pid = record.pid { pids.insert(pid) }
                let live: NarrowStatus = try await rpc.call("server.status").result(); pids.formUnion(live.holders.map(\.pid)); try identities()
                let first = board.attach(record.address); session = first
                let firstView = TerminalView(frame:NSRect(x:0,y:0,width:900,height:500))
                firstView.getTerminal().resize(cols:80,rows:24)
                try await first.start(columns:80,rows:24)
                var initial = Data()
                try await consume(first,view:firstView,raw:&initial,needle:"HC-UI-RENDER-DONE")
                try await first.stop(); session = nil
                let next = board.attach(record.address); session = next
                let view = TerminalView(frame:NSRect(x:0,y:0,width:900,height:500))
                view.getTerminal().resize(cols:columns,rows:24)
                try await next.start(columns:columns,rows:24)
                var raw = Data()
                // Consume at least the reconnect snapshot before fixture input.
                guard let snapshot = try await next.nextOutput(timeout:.seconds(4)) else { throw NarrowFailure.assertion("snapshot missing") }
                raw.append(snapshot.frame.payload); view.feed(byteArray:Array(snapshot.frame.payload)[...]); try await next.acknowledgeOutput(snapshot)
                let before = flat(view)
                _ = try await rpc.call("terminal.keys",parameters:JSONSerialization.data(withJSONObject:["terminal":record.address,"keys":["f","enter"]]))
                try await consume(next,view:view,raw:&raw,needle:"HC-DROP-READY")
                let rendered = flat(view), core = try await board.read(record.address)
                let rawReady = raw.contains(Data("HC-DROP-READY".utf8)), renderedReady = rendered.contains("HC-DROP-READY")
                let coreFlat = core.text.replacingOccurrences(of:"\n",with:"").replacingOccurrences(of:"\r",with:"")
                // Diagnostic control only. Do not alter the actual wire path or
                // application renderer; seed a separate fresh parser's saved cursor.
                let seeded = TerminalView(frame:NSRect(x:0,y:0,width:900,height:500))
                seeded.getTerminal().resize(cols:columns,rows:24)
                seeded.feed(byteArray:[0x1b,0x37])
                seeded.feed(byteArray:Array(raw)[...])
                let explicitOff = TerminalView(frame:NSRect(x:0,y:0,width:900,height:500))
                explicitOff.getTerminal().resize(cols:6,rows:24)
                explicitOff.feed(byteArray:Array("\u{001b}7\u{001b}[?7l\u{001b}[?1049h\u{001b}[?1049lHC-DROP-READY".utf8)[...])
                let offPreserved = !flat(explicitOff).contains("HC-DROP-READY")
                cases.append(["columns":columns,"rawReady":rawReady,"renderedReady":renderedReady,"coreReady":coreFlat.contains("HC-DROP-READY"),
                    "before":before,"rendered":rendered,"coreText":core.text,"nativeGUIQualified":false,
                    "diagnosticSeededRendered":flat(seeded),"diagnosticSeededReady":flat(seeded).contains("HC-DROP-READY"),
                    "explicitDisabledWrapPreserved":offPreserved,"diagnosticOnly":true])
                try raw.write(to:home.appending(path:"narrow-\(columns).vt"))
                try await next.stop(); session = nil
                _ = try await board.kill(record.address)
                checks += 1
            }
        } catch { failure = error }
        if let session { try await session.stop() }
        let stopped: NarrowStopped? = try? await rpc.call("server.stop").result()
        try await rpc.close()
        let closed = await transport.snapshot()
        let passed = failure == nil && cases.count == 2 && cases.allSatisfy { $0["rawReady"] as? Bool == true && $0["renderedReady"] as? Bool == true && $0["explicitDisabledWrapPreserved"] as? Bool == true }
        var result: [String:Any] = ["passed":passed,"checks":checks,"cases":cases,"ownedPIDs":Array(pids).sorted(),
            "stopAcknowledged":stopped?.stopped == true,"connectChildReaped":closed.reaped,"physicalGUIQualified":false,
            "rendererVersion":SwiftTermBuildInfo.version,"rendererBaseCommit":SwiftTermBuildInfo.commit ?? "unknown"]
        if let failure { result["failure"] = String(describing:failure) }
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:report,options:.atomic)
        guard passed else { throw failure ?? NarrowFailure.assertion("narrow renderer divergence; inspect raw/core/render evidence") }
        print("PASS owned narrow render comparison: \(checks) cases; actual SwiftTerm/core, no window")
    }
}
