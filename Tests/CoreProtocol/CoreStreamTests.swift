import Foundation
#if os(macOS)
nonisolated struct StreamStats: Decodable, Sendable {
    struct Channel: Decodable, Sendable { let acks: Int; let input: String; let size: [Int]? }
    let closed: [UInt32]
    let channels: [String: Channel]
}
extension CoreConnectionTests {
    static func packet(_ stream: CoreStream) async throws -> CoreStreamPacket {
        guard let packet = try await stream.next(timeout: .seconds(3)) else { throw ConnectionTestError.failed("missing stream packet") }
        return packet
    }
    static func streamsAndCredit() async throws {
        let (endpoint, c) = try make()
        _ = try await c.connect()
        let a = try await c.openStream("terminal.attach", parameters: Data("{\"terminal\":\"normal\"}".utf8))
        let first = try await packet(a)
        try check(String(decoding: first.frame.payload, as: UTF8.self) == "initial")
        var stats: StreamStats = try await c.call("fixture.streamStats").result()
        try check(stats.channels[String(a.channel)]?.acks == 0, "dequeue must not grant CREDIT")
        do { _ = try await a.next(); throw ConnectionTestError.failed("read without ACK") }
        catch CoreStreamFailure.unacknowledgedData { checks += 1 }
        try await a.acknowledge(first)
        do { _ = try await a.acknowledge(first); throw ConnectionTestError.failed("double CREDIT") }
        catch CoreStreamFailure.invalidReceipt { checks += 1 }
        try await a.resize(columns: 101, rows: 31)
        try await a.focus(true)
        try await a.displayFacts(Data("{\"fg\":[255,255,255],\"bg\":[0,0,0]}".utf8))
        let typed = Data("한글😀\u{2}q".utf8)
        try await a.send(typed)
        let echo = try await packet(a)
        try check(echo.frame.payload == Data("echo:".utf8) + typed, "raw input must not use legacy prefix escaping")
        try await a.acknowledge(echo)
        stats = try await c.call("fixture.streamStats").result()
        try check(stats.channels[String(a.channel)]?.size == [101,31])

        let observer = try await c.openStream("terminal.attach", parameters: Data("{\"terminal\":\"normal\",\"observe\":true,\"resize_notifications\":true}".utf8))
        try check(observer.resizeNotifications && observer.observesOnly)
        let resize = try await packet(observer)
        try check(resize.frame.kind == .resize && resize.receipt == nil)
        let observed = try await packet(observer)
        do { _ = try await a.acknowledge(observed); throw ConnectionTestError.failed("cross-channel CREDIT") }
        catch CoreStreamFailure.invalidReceipt { checks += 1 }
        try await observer.acknowledge(observed)
        do { try await observer.send(Data([1])); throw ConnectionTestError.failed("observer typed") }
        catch CoreStreamFailure.readOnly { checks += 1 }
        try await observer.close()
        let legacy = try await c.openStream("terminal.attach", parameters: Data("{\"terminal\":\"normal\",\"observe\":true}".utf8))
        try check(!legacy.resizeNotifications, "absence is not support for resize notifications")
        try await legacy.close()

        let events = try await c.openStream("events.subscribe")
        let heartbeat = try await packet(events)
        var lines = try CoreEventLines(); var count = 0
        try lines.receive(heartbeat.frame.payload) { _ in count += 1 }
        try check(count == 1)
        try await events.acknowledge(heartbeat)
        do { try await events.focus(true); throw ConnectionTestError.failed("event channel changed focus") }
        catch CoreStreamFailure.readOnly { checks += 1 }

        let burst = try await c.openStream("terminal.attach", parameters: Data("{\"terminal\":\"burst\"}".utf8))
        var chunk = try await packet(burst)
        _ = try await c.call("fixture.echo") // stalled stream cannot block RPC
        stats = try await c.call("fixture.streamStats").result()
        try check(stats.channels[String(burst.channel)]?.acks == 0)
        var total = 0
        while chunk.frame.kind != .close {
            total += chunk.frame.payload.count
            try await burst.acknowledge(chunk)
            chunk = try await packet(burst)
        }
        try check(total == 600000 && chunk.receipt == nil, "output larger than initial window did not flow")
        let end = try await burst.next()
        try check(end == nil)
        try await a.close(); try await events.close()
        let state = await c.snapshot()
        try check(state.streams == 0 && state.bufferedStreamBytes == 0)
        try await retired(endpoint, c)

        let (lateEndpoint, late) = try make()
        _ = try await late.connect()
        try await expect(.requestTimedOut) {
            _ = try await late.openStream("terminal.attach", parameters: Data("{\"terminal\":\"late\"}".utf8), timeout: .milliseconds(50))
        }
        _ = try await late.call("fixture.flush")
        let cleaned: StreamStats = try await late.call("fixture.streamStats").result()
        try check(cleaned.closed == [1], "late attach was not closed")
        let lateState = await late.snapshot()
        try check(lateState.streams == 0 && lateState.occupiedRequestSlots == 0)
        let canceledOpen = Task { try await late.openStream("terminal.attach", parameters: Data("{\"terminal\":\"late\"}".utf8)) }
        _ = try await late.call("fixture.slowBarrier")
        canceledOpen.cancel()
        do { _ = try await canceledOpen.value; throw ConnectionTestError.failed("canceled open succeeded") }
        catch is CancellationError { checks += 1 }
        _ = try await late.call("fixture.flush")
        let canceledStats: StreamStats = try await late.call("fixture.streamStats").result()
        try check(canceledStats.closed == [1,2], "canceled late stream leaked")
        let idle = try await late.openStream("terminal.attach")
        let initial = try await packet(idle); try await idle.acknowledge(initial)
        do { _ = try await idle.next(timeout: .milliseconds(50)); throw ConnectionTestError.failed("stream read deadline") }
        catch CoreStreamFailure.timedOut { checks += 1 }
        try await idle.close()
        let afterReadTimeout = await late.snapshot()
        try check(afterReadTimeout.state == .ready && afterReadTimeout.streams == 0)
        try await retired(lateEndpoint, late)

        let (limitedEndpoint, limited) = try make(maximumStreams: 2)
        _ = try await limited.connect()
        let limitedA = try await limited.openStream("terminal.attach")
        let limitedB = try await limited.openStream("events.subscribe")
        do { _ = try await limited.openStream("terminal.attach"); throw ConnectionTestError.failed("stream admission limit ignored") }
        catch CoreStreamFailure.limitExceeded { checks += 1 }
        try await limitedA.close(); try await limitedB.close()
        let freed = await limited.snapshot()
        try check(freed.streams == 0 && freed.bufferedStreamBytes == 0)
        try await retired(limitedEndpoint, limited)

        for name in ["before", "overflow", "reuse"] {
            let (badEndpoint, bad) = try make(); _ = try await bad.connect()
            if name == "reuse" {
                let existing = try await bad.openStream("terminal.attach"); try await existing.close()
            }
            var rejected = false
            do {
                let s = try await bad.openStream("terminal.attach", parameters: Data("{\"terminal\":\"\(name)\"}".utf8))
                _ = try await s.next(timeout: .seconds(2))
            } catch { rejected = true }
            try check(rejected, "invalid stream protocol accepted: \(name)")
            try await retired(badEndpoint, bad)
        }
        let (timeoutEndpoint, timeout) = try make(); _ = try await timeout.connect()
        let hung = try await timeout.openStream("terminal.attach", parameters: Data("{\"terminal\":\"hangclose\"}".utf8))
        do { try await hung.close(); throw ConnectionTestError.failed("missing CLOSE ack accepted") }
        catch CoreStreamFailure.closeTimedOut { checks += 1 }
        try await retired(timeoutEndpoint, timeout)

        var ids = CoreChannelIDs()
        try ids.claim(2); try ids.claim(1); try ids.claim(UInt32.max)
        do { try ids.claim(1); throw ConnectionTestError.failed("channel reused") }
        catch CoreStreamFailure.invalidChannel { checks += 1 }
    }
}
#endif
