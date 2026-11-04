import Foundation

@MainActor private final class AttentionSink {
    var view: HcAttentionMonitor.View?
    var views = 0
    var candidates: [CoreAttentionFeed.Candidate] = []
    func state(_ value: HcAttentionMonitor.View) { view = value; views += 1 }
    func attention(_ value: CoreAttentionFeed.Candidate) -> Bool { candidates.append(value); return true }
}
private nonisolated struct Status: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}
@main @MainActor private struct HcAttentionTests {
    static var checks = 0
    static func check(_ b: Bool, _ label: String) throws { guard b else { throw NSError(domain: label, code: 1) }; checks += 1 }
    static func wait(_ label: String, until predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !predicate() { guard ContinuousClock.now < deadline else { throw NSError(domain: label, code: 1) }; try await Task.sleep(for: .milliseconds(10)) }
        checks += 1
    }
    static func main() async throws {
        let args = CommandLine.arguments
        let binary = URL(fileURLWithPath: args[1]), root = URL(fileURLWithPath: args[2]), report = URL(fileURLWithPath: args[3])
        let (transport, rpc, _) = try await HcCoreBootstrap.connect(binary: binary, scope: .init(root: root))
        let board = HcTerminalBoard(connection: rpc), sink = AttentionSink()
        var owned: [UInt32] = [], failure: (any Error)?, monitor: HcAttentionMonitor?, task: Task<Void,Error>?
        do {
            let status: Status = try await rpc.call("server.status").result(); owned = [status.pid]
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            let program = "import sys\ndef state(s): print('\\033]7501;state='+s+':app=owned-attention\\007',flush=True)\nstate('blocked')\nfor line in sys.stdin:\n s={'w':'working','b':'blocked','d':'done'}.get(line.strip())\n if s: state(s)"
            let terminal = try await board.run(argv: ["/usr/bin/python3","-I","-S","-B","-c",program], cwd: root.path)
            let live: Status = try await rpc.call("server.status").result()
            owned += live.holders.map(\.pid) + [terminal.pid].compactMap { $0 }
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            try await wait("owned initial blocked", until: { try await board.get(terminal.address).status?.state == "blocked" })
            let observer = try await HcAttentionMonitor(connection: rpc, confirmationDelay: .milliseconds(10)); monitor = observer
            let run = Task {
                try await observer.run(state: { await sink.state($0) }, attention: { candidate, _ in await sink.attention(candidate) })
            }; task = run
            try await wait("initial baseline", until: { sink.view != nil })
            try check(sink.candidates.isEmpty && sink.view?.unreadBlocked == 1, "initial blocked is badge-only baseline, not catchup alert")
            _ = try await observer.setViewed([terminal.address])
            try check(await observer.view().unreadBlocked == 0, "actually viewed blocked terminal clears badge")
            _ = try await observer.setViewed([])
            try check(await observer.view().unreadBlocked == 0, "leaving view does not mark same fact unseen again")
            func key(_ key: String) async throws {
                _ = try await rpc.call("terminal.keys", parameters: JSONSerialization.data(withJSONObject: ["terminal":terminal.address,"keys":[key,"enter"]]))
            }
            try await key("w")
            try await wait("working observed", until: { sink.view?.terminals.first(where: { $0.address == terminal.address })?.status?.state == "working" })
            try await key("b")
            try await wait("one fresh blocked alert", until: { sink.candidates.count == 1 })
            try check(sink.view?.unreadBlocked == 1, "new turn becomes unread")
            let previousViews = sink.views
            _ = try await rpc.call("terminal.label", parameters: JSONSerialization.data(withJSONObject: ["terminal":terminal.address,"labels":["owned":"unchanged-status"]]))
            try await wait("irrelevant event admitted", until: { sink.views > previousViews })
            try await Task.sleep(for: .milliseconds(100))
            try check(sink.candidates.count == 1, "delivered status not duplicated by another event")
            let candidate = sink.candidates[0]
            try await key("w")
            try await wait("second work observed", until: { sink.view?.terminals.first(where: { $0.address == terminal.address })?.status?.state == "working" })
            try check(try await observer.confirm(candidate) == nil, "changed/delivered candidate cannot confirm")
            _ = try await observer.setViewed([terminal.address])
            try await key("b")
            try await wait("viewed blocked observed", until: { sink.view?.terminals.first(where: { $0.address == terminal.address })?.status?.state == "blocked" })
            try check(sink.view?.unreadBlocked == 0 && sink.candidates.count == 1, "visible pane suppresses new alert and badge")
            _ = try await board.kill(terminal.address)
            try await wait("explicit kill observed", until: { sink.view?.terminals.first(where: { $0.address == terminal.address })?.state == "finished" })
            try check(sink.candidates.count == 1, "explicit kill is not an unexpected exit alert")
            try await observer.close(); run.cancel(); _ = try? await run.value
            try check(await rpc.state == .ready, "monitor close preserves shared RPC connection")
        } catch { failure = error }
        try? await monitor?.close(); task?.cancel(); _ = try? await task?.value
        _ = try await rpc.call("server.stop"); try await rpc.close()
        try check(await transport.snapshot().reaped, "owned connect child reaped")
        try JSONSerialization.data(withJSONObject: ["passed":failure == nil,"checks":checks,"ownedPIDs":owned,"failure":failure.map { String(describing:$0) } ?? ""]).write(to: report, options: .atomic)
        if let failure { throw failure }
        print("PASS hc attention adapter: \(checks) checks; no OS notifications/accounts")
    }
}
