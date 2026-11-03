import Foundation
import Darwin
import ShepherdKit
import SwiftTerm

@MainActor private final class PassiveSink: @preconcurrency TerminalDelegate {
    var discardedResponseBytes = 0
    func send(source: Terminal, data: ArraySlice<UInt8>) { discardedResponseBytes += data.count }
    func isProcessTrusted(source: Terminal) -> Bool { false }
}
private nonisolated struct PassiveStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32
    let live: Int
    let holders: [Holder]
}
private nonisolated struct PassiveRun: Decodable, Sendable { let address: String; let pid: UInt32? }
private nonisolated struct PassiveRead: Decodable, Sendable { let text: String }
private nonisolated struct PassiveStop: Decodable, Sendable { let stopped: Bool }
private enum PassiveFailure: Error { case assertion(String) }

@main @MainActor private struct PassiveCoreIntegrationTests {
    static func params(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL passive screen gate; see owned report.json\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[1]), home = URL(fileURLWithPath: CommandLine.arguments[2])
        let peer = CommandLine.arguments[3], report = URL(fileURLWithPath: CommandLine.arguments[4])
        for part in ["", "state", "config", "runtime"] {
            try FileManager.default.createDirectory(at: home.appending(path: part), withIntermediateDirectories: true)
        }
        let env = ["PATH":"/usr/bin:/bin", "HOME":home.path, "XDG_STATE_HOME":home.appending(path:"state").path,
                   "XDG_CONFIG_HOME":home.appending(path:"config").path, "XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
                   "HC_SESSION":"owned", "HC_SOCKET":home.appending(path:"c.sock").path, "DO_NOT_TRACK":"1", "LANG":"en_US.UTF-8"]
        let transport = try CoreProcessTransport(configuration: .init(executable: binary, environment: env, directory: home))
        let connection = try CoreRPCConnection(transport: transport)
        var active: CoreStream?, observer: CoreStream?
        var failure: (any Error)?
        var owned: [UInt32] = []
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw PassiveFailure.assertion(label) }
            checks += 1
        }
        var negotiated = false
        do {
            _ = try await connection.connect()
            let fresh: PassiveStatus = try await connection.call("server.status").result()
            owned = [fresh.pid]
            try params(["ownedPIDs":owned,"corePID":fresh.pid]).write(to: report, options: .atomic)
            try check(fresh.live == 0, "fresh private core")
            let run: PassiveRun = try await connection.call("terminal.run", parameters: params([
                "argv":["/usr/bin/python3","-I","-S","-B",peer],"cwd":home.path,"keep":false,
                "env":["TERM":"xterm-256color","TERM_PROGRAM":"3rdr-fixture"]])).result()
            let status: PassiveStatus = try await connection.call("server.status").result()
            owned += status.holders.map(\.pid) + [run.pid].compactMap { $0 }
            try params(["ownedPIDs":owned,"corePID":fresh.pid]).write(to: report, options: .atomic)
            _ = try await connection.call("terminal.wait", parameters: params(["terminal":run.address,"timeout":5]))
            let leader = try await connection.openStream("terminal.attach", parameters: params(["terminal":run.address,"cols":80,"rows":24]))
            active = leader
            let stream = try await connection.openStream("terminal.attach", parameters: params([
                "terminal":run.address,"observe":true,"resize_notifications":true,"cols":5,"rows":4,"history":0]))
            observer = stream; negotiated = stream.resizeNotifications
            // False/absent is a red parity gate, never a legacy visual fallback.
            var sequence = try CorePassiveScreenSequence(stream: stream)
            // Retain the delegate explicitly; no UI/app activation is needed.
            let sink = PassiveSink()
            let model = Terminal(delegate: sink)
            func text() -> String {
                (0..<model.rows).compactMap { row in
                    model.getLine(row:row)?.translateToString(trimRight:true, skipNullCellsFollowingWide:true, characterProvider:model.getCharacter)
                }.joined(separator:"\n")
            }
            func wait(_ cols: UInt16, _ rows: UInt16) async throws {
                let end = ContinuousClock.now.advanced(by:.seconds(5))
                while sequence.columns != cols || sequence.rows != rows || !text().contains("PAINT-DONE:\(cols)x\(rows)") {
                    guard ContinuousClock.now < end, let packet = try await stream.next(timeout:.seconds(3)) else { throw PassiveFailure.assertion("missing grid/paint") }
                    switch try sequence.consume(packet) {
                    case .resize(let columns, let rows): model.resize(cols:Int(columns), rows:Int(rows))
                    case .data(let bytes):
                        model.feed(buffer:Array(bytes)[...])
                        try await stream.acknowledge(packet) // only after the renderer consumed bytes
                    case .closed: throw PassiveFailure.assertion("observer closed before paint")
                    }
                }
                try check(model.cols == Int(cols) && model.rows == Int(rows), "authoritative grid, not requested observer dimensions")
                try check(text().contains("CJK 한글😀") && text().contains("INPUT:0"), "unicode and passive input counter")
                try check(model.getCharData(col:0,row:1)?.attribute.bg == .ansi256(code:1), "red text background")
                let gap = model.getCharData(col:4,row:1)?.attribute.bg
                try check(gap == .defaultColor || gap == .defaultInvertedColor, "gap must not inherit preceding background")
                try check((0..<Int(cols)).allSatisfy { model.getCharData(col:$0,row:2)?.attribute.bg == .ansi256(code:4) }, "background-only row preserved")
                try check(model.getCharData(col:2,row:3)?.attribute.style.contains(.dim) == true, "dim attribute retained; not an empty-editor authority claim")
                try check(model.link(at:.screen(Position(col:1,row:4)),mode:.explicitOnly) == "https://example.invalid/passive", "snapshot OSC8")
            }
            try await wait(80,24)
            // Exercise generated terminal responses without returning them to the program.
            model.feed(text:"\u{1b}[5n")
            try check(sink.discardedResponseBytes > 0, "headless replies discarded")
            do { try await stream.send(Data("forbidden".utf8)); throw PassiveFailure.assertion("observer input permitted") }
            catch CoreStreamFailure.readOnly { checks += 1 }
            try await leader.resize(columns:97,rows:31); try await wait(97,31)
            for cols in [UInt16(81),82,83] { try await leader.resize(columns:cols,rows:27) }
            try await wait(83,27)
            try await leader.close(); active = nil
            try await wait(200,120) // only observers remain: core's headless grid
            let read: PassiveRead = try await connection.call("terminal.read", parameters:params(["terminal":run.address,"lines":0])).result()
            try check(read.text.contains("INPUT:0"), "no scroll, keys, query replies or observer writes reached program")
            sequence.retire()
            try check(sequence.isRetired && sequence.columns == nil, "replica invalidated on retirement")
        } catch { failure = error }
        if let observer { try? await observer.close() }
        if let active { try? await active.close() }
        let stop: PassiveStop? = try? await connection.call("server.stop").result()
        try await connection.close()
        let process = await transport.snapshot()
        let passed = failure == nil && stop?.stopped == true && process.reaped
        var result: [String: Any] = ["passed":passed,"checks":checks,"ownedPIDs":owned,"stopAcknowledged":stop?.stopped == true,
                                   "resizeNegotiated":negotiated,"connectChildReaped":process.reaped,
                                   "agentParityComplete":false,"credentialsUsed":false]
        if let failure { result["failure"] = String(describing: failure) }
        try params(result).write(to:report,options:.atomic)
        guard passed else { throw failure ?? PassiveFailure.assertion("cleanup unconfirmed") }
        print("PASS passive core attributed-grid integration: \(checks) checks; no program input or agent authority")
    }
}
