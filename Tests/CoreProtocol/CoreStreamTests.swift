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
    static func passiveSequenceCases(stream: CoreStream, data: CoreStreamPacket) throws {
        func resize(_ cols: UInt16, _ rows: UInt16, ordinal: UInt64 = 1, origin: CoreStreamID? = nil) throws -> CoreStreamPacket {
            let payload = Data([UInt8(truncatingIfNeeded: cols), UInt8(truncatingIfNeeded: cols >> 8),
                                UInt8(truncatingIfNeeded: rows), UInt8(truncatingIfNeeded: rows >> 8)])
            return CoreStreamPacket(stream: origin ?? stream.id, ordinal: ordinal,
                                    frame: try CoreFrame(channel: stream.channel, kind: .resize, payload: payload), receipt: nil)
        }
        func reject(_ failure: CorePassiveScreenFailure, _ packet: CoreStreamPacket) throws {
            var sequence = try CorePassiveScreenSequence(stream: stream)
            do { _ = try sequence.consume(packet); throw ConnectionTestError.failed("passive sequence accepted invalid input") }
            catch let error as CorePassiveScreenFailure { try check(error == failure) }
            try check(sequence.isRetired && sequence.columns == nil && sequence.rows == nil, "bad packet must invalidate geometry")
        }
        try reject(.outOfOrder, resize(80, 24, ordinal: 2))
        try reject(.invalidPacket, resize(0, 24))
        try reject(.invalidPacket, resize(80, 0))
        try reject(.gridTooLarge, resize(UInt16.max, UInt16.max))
        try reject(.gridTooLarge, resize(1024, 1024))
        try reject(.wrongStream, resize(80, 24, origin: CoreStreamID(epoch: UUID(), channel: stream.channel)))
        try reject(.wrongStream, resize(80, 24, origin: CoreStreamID(epoch: stream.id.epoch, channel: stream.channel)))
        try reject(.missingInitialGrid, CoreStreamPacket(stream: stream.id, ordinal: 1, frame: data.frame, receipt: data.receipt))
        try reject(.invalidPacket, CoreStreamPacket(stream: stream.id, ordinal: 1,
            frame: try CoreFrame(channel: stream.channel, kind: .focus, payload: Data([1])), receipt: nil))
        let size = try resize(512, 512)
        try reject(.invalidPacket, CoreStreamPacket(stream: stream.id, ordinal: 1, frame: size.frame, receipt: data.receipt))
        var sequence = try CorePassiveScreenSequence(stream: stream)
        _ = try sequence.consume(size)
        try check(sequence.columns == 512 && sequence.rows == 512, "exact cell budget")
        do { _ = try sequence.consume(size); throw ConnectionTestError.failed("duplicate control applied") }
        catch CorePassiveScreenFailure.outOfOrder { checks += 1 }
        try check(sequence.isRetired && sequence.columns == nil)
        do { _ = try sequence.consume(data); throw ConnectionTestError.failed("retired sequence revived") }
        catch CorePassiveScreenFailure.retired { checks += 1 }
        var closed = try CorePassiveScreenSequence(stream: stream)
        let close = CoreStreamPacket(stream: stream.id, ordinal: 1,
                                     frame: try CoreFrame(channel: stream.channel, kind: .close), receipt: nil)
        let end = try closed.consume(close)
        try check(end == .closed && closed.isRetired && closed.rows == nil)
        var lost = try CorePassiveScreenSequence(stream: stream)
        _ = try lost.consume(resize(80, 24)); lost.retire()
        try check(lost.isRetired && lost.columns == nil, "connection loss invalidates geometry")
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
        var passive = try CorePassiveScreenSequence(stream: observer)
        let resize = try await packet(observer)
        try check(resize.frame.kind == .resize && resize.receipt == nil)
        let resizeUpdate = try passive.consume(resize)
        try check(resizeUpdate == .resize(columns: 90, rows: 25))
        let observed = try await packet(observer)
        let dataUpdate = try passive.consume(observed)
        try check(dataUpdate == .data(Data("initial".utf8)))
        try passiveSequenceCases(stream: observer, data: observed)
        do { _ = try await a.acknowledge(observed); throw ConnectionTestError.failed("cross-channel CREDIT") }
        catch CoreStreamFailure.invalidReceipt { checks += 1 }
        try await observer.acknowledge(observed)
        do { try await observer.send(Data([1])); throw ConnectionTestError.failed("observer typed") }
        catch CoreStreamFailure.readOnly { checks += 1 }
        try await observer.close()
        let legacy = try await c.openStream("terminal.attach", parameters: Data("{\"terminal\":\"normal\",\"observe\":true}".utf8))
        try check(!legacy.resizeNotifications, "absence is not support for resize notifications")
        do { _ = try CorePassiveScreenSequence(stream: legacy); throw ConnectionTestError.failed("legacy observer accepted as ordered replica") }
        catch CorePassiveScreenFailure.unsupported { checks += 1 }
        do { _ = try CorePassiveScreenSequence(stream: a); throw ConnectionTestError.failed("typing stream accepted as passive") }
        catch CorePassiveScreenFailure.unsupported { checks += 1 }
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
