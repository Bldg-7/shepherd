import Foundation

/// In-memory framed peer. No process, core install, network or credentials.
private actor WorkspacePeer: CoreByteTransport {
    private var framed = false, closed = false
    private var decoder = CoreFrameDecoder()
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var channel: UInt32 = 0
    private var streams: Set<UInt32> = []
    private var version: UInt64 = 0, sequence: UInt64 = 0
    private var value: Data?
    private var held: [(UInt64, UInt64, Data?)] = []
    var holdGets = false, failGets = false, dropWrites = false
    private var holdOpens = false, pendingOpens: [UInt64] = []
    private(set) var methods: [String] = []
    private(set) var writes = 0
    func start() async throws {}
    func read() async throws -> Data? {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async throws { closed = true; waiter?.resume(returning: nil); waiter = nil; queue.removeAll() }
    private func output(_ bytes: Data) {
        if let waiter { self.waiter = nil; waiter.resume(returning: bytes) } else { queue.append(bytes) }
    }
    private func frame(_ payload: Data, channel: UInt32 = 0, kind: CoreWire.Kind = .data) throws {
        output(try CoreFrame(channel: channel, kind: kind, payload: payload).encoded())
    }
    private func reply(_ id: UInt64, _ raw: String) throws {
        try frame(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(raw)}".utf8))
    }
    private func get(_ id: UInt64, _ version: UInt64, _ value: Data?) throws {
        try reply(id, "{\"version\":\(version),\"value\":\(value.map { String(decoding:$0,as:UTF8.self) } ?? "null")}")
    }
    func write(_ bytes: Data) async throws {
        if !framed {
            framed = true; methods.append("hello")
            output(Data("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"core\":{\"id\":\"owned-workspace\",\"name\":\"fixture\"},\"version\":\"0.1.17\",\"generation\":1,\"framed\":true,\"features\":[],\"methods\":[\"events.subscribe\",\"doc.get\",\"doc.set\"]}}\n".utf8))
            return
        }
        var frames: [CoreFrame] = []
        try decoder.receive(bytes) { frames.append($0) }
        for incoming in frames {
            if incoming.channel != 0 {
                if incoming.kind == .close { streams.remove(incoming.channel); try frame(Data(), channel: incoming.channel, kind: .close) }
                continue
            }
            struct Request: Decodable {
                struct Params: Decodable { let version: UInt64? }
                let id: UInt64; let method: String; let params: Params
            }
            let request = try JSONDecoder().decode(Request.self, from: incoming.payload)
            methods.append(request.method)
            switch request.method {
            case "events.subscribe":
                if holdOpens { pendingOpens.append(request.id) }
                else { try subscribe(request.id) }
            case "doc.get":
                if failGets { try frame(Data("{\"jsonrpc\":\"2.0\",\"id\":\(request.id),\"error\":{\"code\":-32000,\"message\":\"PRIVATE\",\"data\":{\"kind\":\"unavailable\"}}}".utf8)) }
                else if holdGets { held.append((request.id, version, value)) }
                else { try get(request.id, version, value) }
            case "doc.set":
                guard request.params.version == version else {
                    try frame(Data("{\"jsonrpc\":\"2.0\",\"id\":\(request.id),\"error\":{\"code\":-32000,\"message\":\"PRIVATE\",\"data\":{\"kind\":\"conflict\"}}}".utf8)); continue
                }
                let object = try JSONSerialization.jsonObject(with: incoming.payload) as! [String:Any]
                let params = object["params"] as! [String:Any]
                value = try JSONSerialization.data(withJSONObject: params["value"]!, options: [.fragmentsAllowed])
                version += 1; writes += 1
                try notification("event", extra: "\"type\":\"doc\",\"data\":{\"name\":\"3rdr-workspace-v1\",\"version\":\(version)},", advance: true)
                if !dropWrites { try reply(request.id, "{\"version\":\(version)}") }
            default: throw CoreWorkspaceFailure.invalidDocument
            }
        }
    }
    func notification(_ method: String, extra: String = "", advance: Bool = false) throws {
        if advance { sequence += 1 }
        let bytes = Data("{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\",\"params\":{\(extra)\"seq\":\(sequence)}}\n".utf8)
        for channel in streams { try frame(bytes, channel: channel) }
    }
    private func subscribe(_ id: UInt64) throws {
        channel += 1; streams.insert(channel)
        try reply(id, "{\"channel\":\(channel),\"seq\":\(sequence),\"terminals\":[]}")
    }
    func delayOpens() { holdOpens = true }
    func openingCount() -> Int { pendingOpens.count }
    func releaseOpens() throws { holdOpens = false; let ids = pendingOpens; pendingOpens.removeAll(); for id in ids { try subscribe(id) } }
    func change(_ document: CoreWorkspaceDocument, notify: Bool = true) throws {
        value = try document.encoded(); version += 1
        if !notify { sequence += 1; return }
        try notification("event", extra: "\"type\":\"doc\",\"data\":{\"name\":\"3rdr-workspace-v1\",\"version\":\(version)},", advance: true)
    }
    func configure(hold: Bool = false, fail: Bool = false, drop: Bool = false) { holdGets = hold; failGets = fail; dropWrites = drop }
    func pendingGets() -> Int { held.count }
    func releaseGets() throws { let saved = held; held.removeAll(); holdGets = false; for (id, version, value) in saved { try get(id, version, value) } }
    func malformedDocument() { value = Data("{\"schemaVersion\":99,\"workspaces\":[]}".utf8); version += 1 }
    func malformedEvent() throws { for channel in streams { try frame(Data("not-json\n".utf8), channel: channel) } }
    func streamCount() -> Int { streams.count }
}

@main @MainActor private struct CoreWorkspaceStoreTests {
    static var checks = 0
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw NSError(domain: label, code: 1) }; checks += 1 }
    static func wait(_ label: String, _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "timeout: " + label, code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
        checks += 1
    }
    static func main() async throws {
        let peer = WorkspacePeer()
        let rpc = try CoreRPCConnection(transport: peer, requiredMethods: ["doc.get","doc.set","events.subscribe"])
        _ = try await rpc.connect()
        let store = try await CoreWorkspaceStore(connection: rpc, timeout: .milliseconds(200))
        var watch = try await store.updates().makeAsyncIterator()
        _ = await watch.next()
        var watchers: [AsyncStream<CoreWorkspaceStore.View>] = []
        for _ in 0..<7 { watchers.append(try await store.updates()) }
        do { _ = try await store.updates(); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreWorkspaceStoreFailure.subscriberLimit { checks += 1 }
        let initial = try await store.start()
        try check(initial.canWrite && initial.snapshot?.version == 0 && initial.snapshot?.document == nil, "confirmed missing after subscribe")
        let methods = await peer.methods
        try check(Array(methods.prefix(3)) == ["hello","events.subscribe","doc.get"], "subscribe before read")
        let workspace = CoreWorkspaceDocument.Workspace(name: "one")
        let first = try CoreWorkspaceDocument(workspaces: [workspace])
        let outcome = try await store.edit(.appendWorkspace(workspace), expectedVersion: 0)
        try check(outcome == .acknowledged(version: 1), "real owner dispatches one edit")
        try await wait("self event refresh") { let v = await store.view(); return v.canWrite && v.snapshot?.version == 1 }
        do { _ = try await store.commit(first, expectedVersion: 0); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreWorkspaceStoreFailure.staleRevision { checks += 1 }
        try check(await peer.writes == 1, "stale proposal never sent")
        // Hold a read at v1; an intervening event advertises v2 before its old reply.
        await peer.configure(hold: true)
        let refresh = Task { try await store.refresh() }
        try await wait("read held") { await peer.pendingGets() == 1 }
        let second = try CoreWorkspaceEdit.renameWorkspace(workspace.id, "two").applying(to: first)
        try await peer.change(second)
        try await wait("event invalidation") { !(await store.view().canWrite) }
        try await peer.releaseGets(); _ = try await refresh.value
        try await wait("stale read retired") { let v = await store.view(); return v.canWrite && v.snapshot?.version == 2 && v.snapshot?.document == second }
        await peer.configure(fail: true)
        let failed = try await store.refresh()
        try check(!failed.canWrite && failed.snapshot?.document == second && failed.failure == .readFailed, "failed read cannot erase cache")
        await peer.configure()
        try await peer.notification("missed")
        try await wait("missed refetch") { await store.view().canWrite }
        await peer.configure(drop: true)
        let uncertain = try await store.commit(first, expectedVersion: 2)
        try check(uncertain == .uncertain, "lost ACK is uncertain")
        try await wait("uncertain reread") { let v = await store.view(); return v.canWrite && v.snapshot?.version == 3 }
        try check(await peer.writes == 2, "timeout never replays mutation")
        await peer.configure(); await peer.malformedDocument()
        try await peer.notification("missed")
        try await wait("invalid schema") { await store.view().failure == .invalidDocument }
        let invalid = await store.view()
        try check(invalid.snapshot?.version == 3 && !invalid.canWrite, "bad document retains read-only cache")
        try await peer.malformedEvent()
        try await wait("bad stream retires") { await store.view().phase == .failed }
        try await store.close()
        try check(await peer.streamCount() == 0, "only owned stream closed")
        try check(await rpc.state == .ready, "shared RPC connection not closed by store")
        do { _ = try await store.commit(first, expectedVersion: 3); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreWorkspaceStoreFailure.closed { checks += 1 }
        // A fresh store can use the still-live shared connection. Close twice
        // while its refresh is held; both callers await the same cleanup job.
        try await peer.change(second)
        let next = try await CoreWorkspaceStore(connection: rpc, timeout: .milliseconds(200))
        _ = try await next.start()
        await peer.configure(hold: true)
        let pending = Task { try await next.refresh() }
        try await wait("close during refresh") { await peer.pendingGets() == 1 }
        async let closeA: Void = next.close()
        async let closeB: Void = next.close()
        _ = try await (closeA, closeB)
        do { _ = try await pending.value; throw CoreWorkspaceFailure.invalidDocument }
        catch CoreWorkspaceStoreFailure.closed { checks += 1 }
        try await peer.releaseGets()
        let ended = await next.view()
        try check(ended.phase == .closed && !ended.canWrite && ended.snapshot?.version == 5, "late read cannot revive closed store")
        try check(await peer.streamCount() == 0, "concurrent close retires stream")
        withExtendedLifetime(watchers) {}
        await peer.delayOpens()
        let unopened = try await CoreWorkspaceStore(connection: rpc)
        let starting = Task { try await unopened.start() }
        try await wait("subscribe held") { await peer.openingCount() == 1 }
        try await unopened.close()
        do { _ = try await starting.value; throw CoreWorkspaceFailure.invalidDocument }
        catch is CancellationError { checks += 1 }
        try await peer.releaseOpens()
        try await wait("late open orphan cleanup") { await peer.streamCount() == 0 }
        try check(await unopened.view().phase == .closed, "late open never revives owner")
        try await rpc.close()

        let conflictPeer = WorkspacePeer()
        let conflictRPC = try CoreRPCConnection(transport: conflictPeer, requiredMethods: ["doc.get","doc.set","events.subscribe"])
        _ = try await conflictRPC.connect()
        let conflictStore = try await CoreWorkspaceStore(connection: conflictRPC)
        _ = try await conflictStore.start()
        try await conflictPeer.change(first, notify: false) // Delay event delivery, not the server mutation.
        let conflict = try await conflictStore.commit(try CoreWorkspaceDocument(), expectedVersion: 0)
        try check(conflict == .conflict, "remote CAS conflict surfaced")
        try await wait("remote conflict refetch") { let v = await conflictStore.view(); return v.canWrite && v.snapshot?.document == first }
        try check(await conflictPeer.writes == 0, "remote conflict never retried")
        try await conflictStore.close(); try await conflictRPC.close()
        try JSONSerialization.data(withJSONObject: ["passed":true,"checks":checks]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS workspace RPC/event owner: \(checks) checks")
    }
}
