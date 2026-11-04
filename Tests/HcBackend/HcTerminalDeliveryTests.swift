import Foundation

private actor DeliveryPeer: CoreByteTransport {
    private var decoder = CoreFrameDecoder(), started = false, closed = false
    private var queued: [Data] = []
    private var reader: CheckedContinuation<Data?, Error>?
    private var held: UInt64?
    private(set) var credits = 0
    private(set) var attaches = 0
    private(set) var closes = 0
    let holdOpen: Bool
    let wrongTerminal: Bool
    init(holdOpen: Bool = false, wrongTerminal: Bool = false) { self.holdOpen = holdOpen; self.wrongTerminal = wrongTerminal }
    func start() async throws {}
    func read() async throws -> Data? {
        if !queued.isEmpty { return queued.removeFirst() }
        if closed { return nil }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
    func close() async throws { closed = true; reader?.resume(returning: nil); reader = nil; queued.removeAll() }
    private func emit(_ bytes: Data) {
        if let reader { self.reader = nil; reader.resume(returning: bytes) } else { queued.append(bytes) }
    }
    private func framed(channel: UInt32, kind: CoreWire.Kind, payload: Data = Data()) throws { emit(try CoreFrame(channel: channel, kind: kind, payload: payload).encoded()) }
    func write(_ bytes: Data) async throws {
        if !started {
            started = true
            emit(Data("{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"core\":{\"id\":\"fixture\",\"name\":\"fixture\"},\"version\":\"0.1.17\",\"generation\":1,\"framed\":true,\"features\":[],\"methods\":[\"terminal.attach\"]}}\n".utf8)); return
        }
        var frames: [CoreFrame] = []; try decoder.receive(bytes) { frames.append($0) }
        for frame in frames {
            if frame.channel == 0 {
                struct Request: Decodable { let id: UInt64 }
                let request = try JSONDecoder().decode(Request.self, from: frame.payload)
                attaches += 1
                if holdOpen { held = request.id } else { try opened(request.id) }
            } else if frame.kind == .credit { credits += Int(CoreWire.uint32(Array(frame.payload), at: 0)) }
            else if frame.kind == .close { closes += 1; try framed(channel: 1, kind: .close) }
        }
    }
    private func opened(_ id: UInt64) throws {
        let address = wrongTerminal ? "t2" : "t1"
        try framed(channel: 0, kind: .data, payload: Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"channel\":1,\"terminal\":{\"address\":\"\(address)\"}}}".utf8))
    }
    func release() throws { if let held { self.held = nil; try opened(held) } }
    func output(_ data: Data) throws { try framed(channel: 1, kind: .data, payload: data) }
}

@main @MainActor private struct HcTerminalDeliveryTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain: label, code: 1) }; checks += 1 }
    static func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) { guard .now < deadline else { throw CoreStreamFailure.timedOut }; try await Task.sleep(for: .milliseconds(5)) }
        checks += 1
    }
    static func make(_ peer: DeliveryPeer) async throws -> CoreRPCConnection {
        let rpc = try CoreRPCConnection(transport: peer, requiredMethods: ["terminal.attach"])
        _ = try await rpc.connect(); return rpc
    }
    static func main() async throws {
        let peer = DeliveryPeer(), rpc = try await make(peer)
        let session = HcTerminalSession(connection: rpc, terminalID: "t1", timeout: .milliseconds(100))
        try await session.start(columns: 80, rows: 24)
        let a = Data([0x1b,0x5b,0x33]), b = Data([0x31,0x6d,0xed,0x95,0x9c]) // Deliberately split CSI and Unicode across packets.
        try await peer.output(a); try await peer.output(b)
        let first = try await session.nextOutput(timeout: .seconds(1))!
        try check(first.frame.payload == a, "first bytes exact")
        try check(await peer.credits == 0, "dequeue and stalled renderer grant no CREDIT")
        do { _ = try await session.nextOutput(timeout: .seconds(1)); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreStreamFailure.unacknowledgedData { checks += 1 }
        try await session.acknowledgeOutput(first)
        let second = try await session.nextOutput(timeout: .seconds(1))!
        try check(second.frame.payload == b, "CSI/Unicode fragment never dropped")
        try await session.acknowledgeOutput(second)
        try await wait { await peer.credits == a.count + b.count }
        do { try await session.acknowledgeOutput(first); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreStreamFailure.invalidReceipt { checks += 1 }
        // The open-RPC timeout must NOT become an idle-output timeout.
        let waiting = Task { try await session.nextOutput() }
        try await Task.sleep(for: .milliseconds(250))
        try await peer.output(Data("after idle".utf8))
        let delayed = try await waiting.value!
        try check(delayed.frame.payload == Data("after idle".utf8), "idle longer than open timeout stays attached")
        try await session.acknowledgeOutput(delayed)
        async let closeA: Void = session.stop(), closeB: Void = session.stop()
        _ = try await (closeA, closeB)
        try check(await peer.closes == 1, "concurrent close awaits single owned close")
        try check(await rpc.state == .ready, "attach close preserves shared RPC")
        let before = HcTerminalSession(connection: rpc, terminalID: "t1")
        try await before.stop()
        do { try await before.start(columns: 80, rows: 24); throw CoreWorkspaceFailure.invalidDocument }
        catch is CancellationError { checks += 1 }
        try check(await peer.attaches == 1, "stop-before-start sends no attach")
        try await rpc.close()

        let held = DeliveryPeer(holdOpen: true), lateRPC = try await make(held)
        let late = HcTerminalSession(connection: lateRPC, terminalID: "t1")
        let opening = Task { try await late.start(columns: 80, rows: 24) }
        try await wait { await held.attaches == 1 }
        try await late.stop()
        do { try await opening.value; throw CoreWorkspaceFailure.invalidDocument }
        catch is CancellationError { checks += 1 }
        try await held.release()
        try await wait { await held.closes == 1 }
        try await lateRPC.close()

        let wrong = DeliveryPeer(wrongTerminal: true), wrongRPC = try await make(wrong)
        let wrongSession = HcTerminalSession(connection: wrongRPC, terminalID: "t1")
        do { try await wrongSession.start(columns: 80, rows: 24); throw CoreWorkspaceFailure.invalidDocument }
        catch HcTerminalSession.Failure.wrongTerminal { checks += 1 }
        try check(await wrong.closes == 1, "wrong target closes actual returned channel")
        try await wrongRPC.close()
        try JSONSerialization.data(withJSONObject: ["passed":true,"checks":checks]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS lossless terminal delivery: \(checks) checks")
    }
}
