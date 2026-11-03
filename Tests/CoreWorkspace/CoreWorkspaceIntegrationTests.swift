import Foundation

private nonisolated struct Status: Decodable, Sendable { let pid: UInt32; let live: Int }
private nonisolated struct Stored: Decodable, Sendable {
    // The fixture writes these exact values. Production storage decoding must
    // use the strict document codec, not this fixture-only wire convenience.
    struct Value: Decodable, Sendable { let schemaVersion: UInt32; let workspaces: [CoreWorkspaceDocument.Workspace] }
    let version: UInt64
    let value: Value?
    func document() throws -> CoreWorkspaceDocument? {
        guard let value else { return nil }
        guard value.schemaVersion == 1 else { throw CoreWorkspaceFailure.unsupportedSchema }
        return try CoreWorkspaceDocument(workspaces: value.workspaces)
    }
}
private nonisolated struct Written: Decodable, Sendable { let version: UInt64 }
private nonisolated struct Stopped: Decodable, Sendable { let stopped: Bool }
private nonisolated struct Notice: Decodable, Sendable {
    struct Params: Decodable, Sendable {
        struct Change: Decodable, Sendable { let name: String?; let version: UInt64? }
        let type: String?
        let data: Change?
    }
    let method: String
    let params: Params
}

@main @MainActor private struct CoreWorkspaceIntegrationTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw NSError(domain: label, code: 1) }; checks += 1
    }
    static func read(_ connection: CoreRPCConnection, _ state: inout CoreWorkspaceCAS) async throws {
        let token = try state.beginRead()
        let result: Stored = try await connection.call("doc.get", parameters: Data("{\"name\":\"\(CoreWorkspaceDocument.documentName)\"}".utf8)).result()
        try state.accept(token, version: result.version, document: result.document())
    }
    static func changed(_ stream: CoreStream, version: UInt64, lines: inout CoreEventLines) async throws {
        var found = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !found {
            guard ContinuousClock.now < deadline, let packet = try await stream.next(timeout: .seconds(3)), packet.frame.kind == .data else {
                throw NSError(domain: "missing subscribed doc notification", code: 1)
            }
            try lines.receive(packet.frame.payload) { bytes in
                let event = try JSONDecoder().decode(Notice.self, from: bytes)
                if event.method == "event", event.params.type == "doc", event.params.data?.name == CoreWorkspaceDocument.documentName,
                   event.params.data?.version == version { found = true }
            }
            try await stream.acknowledge(packet)
        }
        checks += 1
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { throw CoreWorkspaceFailure.invalidDocument }
        let binary = URL(fileURLWithPath: args[1]), home = URL(fileURLWithPath: args[2]), report = URL(fileURLWithPath: args[3])
        for part in ["", "state", "config", "runtime"] { try FileManager.default.createDirectory(at: home.appending(path: part), withIntermediateDirectories: true) }
        let env = ["PATH":"/usr/bin:/bin", "HOME":home.path, "XDG_STATE_HOME":home.appending(path:"state").path,
                   "XDG_CONFIG_HOME":home.appending(path:"config").path, "XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
                   "HC_SESSION":"owned", "HC_SOCKET":home.appending(path:"c.sock").path, "SSH_CONNECTION":"owned-fixture-no-launchd", "DO_NOT_TRACK":"1"]
        let config = CoreProcessTransport.Configuration(executable: binary, environment: env, directory: home)
        let ta = try CoreProcessTransport(configuration: config), tb = try CoreProcessTransport(configuration: config)
        let required: Set<String> = ["doc.get","doc.set","events.subscribe","server.status","server.stop"]
        let a = try CoreRPCConnection(transport: ta, requiredMethods: required), b = try CoreRPCConnection(transport: tb, requiredMethods: required)
        var streams: [CoreStream] = [], pid: UInt32?, failure: (any Error)?
        do {
            let ha = try await a.connect(), hb = try await b.connect()
            let status: Status = try await a.call("server.status").result(); pid = status.pid
            try JSONSerialization.data(withJSONObject: ["corePID":status.pid]).write(to: report, options: .atomic)
            try check(ha.version == args[4] && hb.core.id == ha.core.id && status.live == 0, "two clients one fresh pinned core")
            var sa = try CoreWorkspaceCAS(originCoreID: ha.core.id, epoch: a.epoch), sb = try CoreWorkspaceCAS(originCoreID: hb.core.id, epoch: b.epoch)
            let ea = try await a.openStream("events.subscribe"), eb = try await b.openStream("events.subscribe")
            streams = [ea, eb]
            var linesA = try CoreEventLines(), linesB = try CoreEventLines()
            try sa.didSubscribe(coreID: ha.core.id, epoch: a.epoch); try sb.didSubscribe(coreID: hb.core.id, epoch: b.epoch)
            try await read(a, &sa); try await read(b, &sb)
            try check(sa.snapshot?.version == 0 && sb.snapshot?.document == nil, "confirmed missing, no automatic write")
            let firstTab = CoreWorkspaceDocument.Tab(name: "first", layout: .leaf(.init()))
            let first = try CoreWorkspaceDocument(workspaces: [.init(name: "macOS fixture", tabs: [firstTab])])
            let other = try CoreWorkspaceDocument(workspaces: [.init(name: "mobile fixture")])
            let wa = try sa.beginWrite(first), wb = try sb.beginWrite(other)
            let accepted: Written = try await a.call("doc.set", parameters: wa.parameters()).result()
            try sa.finish(wa, result: .acknowledged(version: accepted.version))
            let rejected = try await b.call("doc.set", parameters: wb.parameters())
            try check(rejected.error?.kind == "conflict", "real concurrent baseline conflict")
            try sb.finish(wb, result: .conflict)
            try await changed(ea, version: 1, lines: &linesA); try await changed(eb, version: 1, lines: &linesB)
            try sa.invalidate(epoch: a.epoch); try sb.invalidate(epoch: b.epoch)
            try await read(a, &sa); try await read(b, &sb)
            try check(sa.snapshot == sb.snapshot && sb.snapshot?.document == first, "losing writer refetches winner without overwrite")
            let mutation = try sa.beginWrite(other)
            // Deliberately discard an actual success reply. This exercises an
            // uncertain client outcome, not a claim of injected transport loss.
            _ = try await a.call("doc.set", parameters: mutation.parameters())
            try sa.finish(mutation, result: .uncertain)
            try await changed(ea, version: 2, lines: &linesA)
            try sa.invalidate(epoch: a.epoch); try await read(a, &sa)
            try check(sa.snapshot?.version == 2 && sa.snapshot?.document == other, "uncertain outcome resolved by read, not replay")
            let deletion = Data("{\"name\":\"\(CoreWorkspaceDocument.documentName)\",\"version\":2,\"value\":null}".utf8)
            let deleted: Written = try await b.call("doc.set", parameters: deletion).result()
            try check(deleted.version == 3, "foreign device deletion retains version")
            try await changed(eb, version: 3, lines: &linesB)
            try sb.invalidate(epoch: b.epoch); try await read(b, &sb)
            let recreate = try sb.beginWrite(first)
            try check(recreate.expectedVersion == 3 && sb.snapshot?.document == nil, "recreate uses tombstone version, not zero")
        } catch { failure = error }
        for stream in streams { try? await stream.close() }
        let stop: Stopped? = try? await a.call("server.stop").result()
        try await a.close(); try await b.close()
        let aa = await ta.snapshot(), bb = await tb.snapshot()
        let passed = failure == nil && stop?.stopped == true && aa.reaped && bb.reaped
        var result: [String: Any] = ["passed":passed,"checks":checks,"stopAcknowledged":stop?.stopped == true,
                                   "connectChildrenReaped":aa.reaped && bb.reaped,"noMutationReplay":true]
        if let pid { result["corePID"] = pid }
        if let failure { result["failure"] = String(describing: failure) }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: .atomic)
        guard passed else { throw failure ?? CoreWorkspaceSyncFailure.refreshRequired }
        print("PASS owned real workspace CAS: \(checks) checks")
    }
}
