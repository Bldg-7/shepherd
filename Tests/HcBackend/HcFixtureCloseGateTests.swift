import Foundation
import ShepherdKit

private nonisolated final class RecordingGateBase: CoreByteTransport {
    private actor State {
        private(set) var writes: [Data] = []
        private(set) var closed = false
        func write(_ bytes: Data) throws { guard !closed else { throw CoreConnectionFailure.closed }; writes.append(bytes) }
        func close() { closed = true }
    }
    private let state = State()
    var writes: [Data] { get async { await state.writes } }
    var closed: Bool { get async { await state.closed } }
    let output = Data([0,255,0x1b,0x5b,0x6d])
    func start() async throws {}
    func read() async throws -> Data? { output }
    func write(_ bytes: Data) async throws { try await state.write(bytes) }
    func close() async throws { await state.close() }
}
@main @MainActor private struct HcFixtureCloseGateTests {
    static func wait(_ gate: HcFixtureCloseGateTransport) async throws {
        let end = ContinuousClock.now.advanced(by:.seconds(2))
        while !(await gate.snapshot()).entered {
            guard ContinuousClock.now < end else { throw CoreConnectionFailure.requestTimedOut }
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value,message); checks += 1 }
        let raw = try CoreFrame(channel:17,kind:.data,payload:Data([255,0,0x1b,0x5b])).encoded()
        let cas = try CoreFrame(channel:0,kind:.data,payload:Data("{\"jsonrpc\":\"2.0\",\"id\":73,\"method\":\"doc.set\",\"params\":{\"version\":\"exact-original-caller-version\"}}".utf8)).encoded()
        let base = RecordingGateBase(), gate = HcFixtureCloseGateTransport(base:base)
        try await gate.start(); try await gate.arm()
        try await gate.write(raw)
        check(await base.writes == [raw],"opaque terminal bytes forwarded unchanged, not inspected as JSON")
        let pending = Task { try await gate.write(cas) }
        try await wait(gate)
        check(await base.writes == [raw],"matching complete CAS has not been dispatched")
        check(try await gate.read() == base.output,"reads remain byte-for-byte opaque during a held write")
        try await gate.release(); try await pending.value
        check(await base.writes == [raw,cas],"exact caller bytes/version forwarded once after release")
        let finished = await gate.snapshot()
        check(finished.forwarded == 1 && finished.released,"one held logical write, one dispatch")
        do { try await gate.release(); preconditionFailure("release replay") } catch { checks += 1 }
        do { try await gate.arm(); preconditionFailure("rearm replay") } catch { checks += 1 }
        try await gate.close(); check(await base.closed,"owned base closes")

        let canceledBase = RecordingGateBase(), canceledGate = HcFixtureCloseGateTransport(base:canceledBase)
        try await canceledGate.start(); try await canceledGate.arm()
        let canceled = Task { try await canceledGate.write(cas) }; try await wait(canceledGate)
        canceled.cancel()
        do { try await canceled.value; preconditionFailure("cancel dispatched") } catch { checks += 1 }
        let canceledWrites = await canceledBase.writes, canceledClosed = await canceledBase.closed
        check(canceledWrites.isEmpty && canceledClosed,"cancel retires base without CAS dispatch/replay")

        let concurrentBase = RecordingGateBase(), concurrentGate = HcFixtureCloseGateTransport(base:concurrentBase)
        try await concurrentGate.start(); try await concurrentGate.arm()
        let first = Task { try await concurrentGate.write(cas) }; try await wait(concurrentGate)
        do { try await concurrentGate.write(raw); preconditionFailure("concurrent write reordered") } catch { checks += 1 }
        do { try await first.value; preconditionFailure("held write survived connection retirement") } catch { checks += 1 }
        let concurrentWrites = await concurrentBase.writes, concurrentClosed = await concurrentBase.closed
        check(concurrentWrites.isEmpty && concurrentClosed,"concurrent admission fails closed without reordering")
        print("PASS \(checks) owned gate invariants; no GUI or actual-core qualification")
    }
}
