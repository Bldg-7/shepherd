import Foundation

private enum Failure: Error { case assertion(String), injected }
private actor Bytes: CoreByteTransport {
    var chunks: [Data]
    let wait: Bool
    let failClose: Bool
    var pending: CheckedContinuation<Data?, any Error>?
    var closedWaiter: CheckedContinuation<Void, Never>?
    var started = false
    var closed = false
    var writes: [Data] = []
    init(_ chunks: [Data] = [], wait: Bool = false, failClose: Bool = false) { self.chunks = chunks; self.wait = wait; self.failClose = failClose }
    func start() throws { guard !closed else { throw Failure.injected }; started = true }
    func read() async throws -> Data? {
        if closed { return nil }
        if !chunks.isEmpty { return chunks.removeFirst() }
        if wait { return try await withCheckedThrowingContinuation { pending = $0 } }
        return nil
    }
    func write(_ bytes: Data) { writes.append(bytes) }
    func close() throws {
        closed = true; let pending = pending; self.pending = nil; pending?.resume(returning: nil)
        closedWaiter?.resume(); closedWaiter = nil
        if failClose { throw Failure.injected }
    }
    func waitClosed() async { if !closed { await withCheckedContinuation { closedWaiter = $0 } } }
}
private actor FactoryGate {
    var waiting: CheckedContinuation<any CoreByteTransport, Never>?
    var entered: CheckedContinuation<Void, Never>?
    var cancelWaiter: CheckedContinuation<Void, Never>?
    var didEnter = false, didCancel = false
    let bytes: Bytes
    init(bytes: Bytes) { self.bytes = bytes }
    func make() async -> any CoreByteTransport {
        didEnter = true; entered?.resume(); entered = nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting = $0 }
        } onCancel: { Task { await self.cancelled() } }
    }
    func waitEntered() async { if !didEnter { await withCheckedContinuation { entered = $0 } } }
    func cancelled() { didCancel = true; cancelWaiter?.resume(); cancelWaiter = nil }
    func waitCancelled() async { if !didCancel { await withCheckedContinuation { cancelWaiter = $0 } } }
    func release() { waiting?.resume(returning: bytes); waiting = nil }
}

@main private struct ConversationLineTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.assertion(label) }; checks += 1 }
    static func main() async throws {
        let request = Data("{\"id\":\"owned\"}\n".utf8)
        let bytes = Bytes([Data("one\n한".utf8), Data("글\n".utf8)])
        let c = ConversationLineConnection { _ in bytes }
        let stream = try await c.openLineStream(endpoint: .conversations, request: request)
        var i = stream.lines.makeAsyncIterator()
        try check(try await i.next() == Data("one".utf8), "first framed line")
        try check(try await i.next() == Data("한글".utf8), "fragmented Unicode line")
        try check(try await i.next() == nil, "clean EOF")
        try await c.close()
        try check(await bytes.closed, "owned byte transport closes")
        try check(await bytes.writes == [request], "exact one request, no legacy/core handshake")

        let partial = Bytes([Data("unfinished".utf8)])
        let p = ConversationLineConnection { _ in partial }
        let ps = try await p.openLineStream(endpoint: .conversations, request: request)
        do { for try await _ in ps.lines {}; throw Failure.assertion("partial accepted") }
        catch HerdrLineStreamError.closed { checks += 1 }
        try await p.close()

        let flood = Bytes([Data("a\nb\nc\n".utf8)])
        let f = ConversationLineConnection { _ in flood }
        let fs = try await f.openLineStream(endpoint: .conversations, request: request)
        await flood.waitClosed() // Do not let the consumer race the deliberate overflow.
        do { for try await _ in fs.lines {}; throw Failure.assertion("flood accepted") }
        catch HerdrLineStreamError.slowConsumer { checks += 1 }
        try await f.close()

        let oversized = Bytes([Data(repeating: 65, count: 2 << 20)])
        let o = ConversationLineConnection { _ in oversized }
        let os = try await o.openLineStream(endpoint: .conversations, request: request)
        do { for try await _ in os.lines {}; throw Failure.assertion("oversized accepted") }
        catch HerdrLineStreamError.lineTooLong { checks += 1 }
        try await o.close()

        let capacity = ConversationLineConnection { _ in await Bytes(wait: true) }
        var held: [HerdrLineStream] = []
        for _ in 0..<8 { held.append(try await capacity.openLineStream(endpoint: .conversations, request: request)) }
        do { _ = try await capacity.openLineStream(endpoint: .conversations, request: request); throw Failure.assertion("unbounded streams") }
        catch ConversationLineConnection.Failure.capacity { checks += 1 }
        try await capacity.close()
        for stream in held {
            var iterator = stream.lines.makeAsyncIterator()
            do { try check(try await iterator.next() == nil, "closed stream has no late data") }
            catch HerdrLineStreamError.closed { checks += 1 }
        }

        let invalid = ConversationLineConnection { _ in throw Failure.assertion("invalid request reached factory") }
        for data in [Data(), Data("no-newline".utf8), Data("x\ny\n".utf8)] {
            do { _ = try await invalid.openLineStream(endpoint: .conversations, request: data); throw Failure.assertion("invalid accepted") }
            catch HerdrLineStreamError.invalidRequest { checks += 1 }
        }
        try await invalid.close()

        let gate = FactoryGate(bytes: Bytes())
        let late = ConversationLineConnection { _ in await gate.make() }
        let opening = Task { try await late.openLineStream(endpoint: .conversations, request: request) }
        await gate.waitEntered()
        let closing = Task { try await late.close() }
        await gate.waitCancelled(); await gate.release()
        do { _ = try await opening.value; throw Failure.assertion("late factory resurrected") }
        catch ConversationLineConnection.Failure.closed { checks += 1 }
        try await closing.value
        let lateBytes = gate.bytes
        try check(await lateBytes.closed, "late factory transport closed")
        try check(await !lateBytes.started, "late factory cannot start or authenticate")

        let droppedBytes = Bytes(wait: true)
        var droppedOwner: ConversationLineConnection? = ConversationLineConnection { _ in droppedBytes }
        let droppedStream = try await droppedOwner!.openLineStream(endpoint: .conversations, request: request)
        droppedOwner = nil
        await droppedBytes.waitClosed()
        try check(await droppedBytes.closed, "owner deinit retires quiet read stream")
        droppedStream.close()

        let bad = Bytes(wait: true, failClose: true)
        let broken = ConversationLineConnection { _ in bad }
        let bs = try await broken.openLineStream(endpoint: .conversations, request: request)
        bs.close()
        do { try await broken.close(); throw Failure.assertion("cleanup error hidden") }
        catch ConversationLineConnection.Failure.cleanupUnconfirmed { checks += 1 }
        print("PASS independent conversation line transport: \(checks) checks")
    }
}
