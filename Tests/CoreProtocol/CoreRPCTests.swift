import Foundation

nonisolated enum RPCTestFailure: Error { case failed(String) }
nonisolated struct RPCVersion: Decodable, Sendable { let version: UInt64 }
nonisolated struct RPCChannel: Decodable, Sendable { let channel: UInt32 }
nonisolated struct RPCEmpty: Decodable, Sendable {}

@main @MainActor
private struct CoreRPCTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String = #function) throws {
        checks += 1
        guard try condition() else { throw RPCTestFailure.failed(message) }
    }
    static func fails(_ expected: CoreRPCFailure, _ operation: () throws -> Void) throws {
        checks += 1
        do { try operation() }
        catch let error as CoreRPCFailure {
            guard error == expected else { throw RPCTestFailure.failed("unexpected RPC error \(error)") }
            return
        }
        throw RPCTestFailure.failed("missing RPC error \(expected)")
    }
    static func reply(_ id: UInt64, _ result: String = "{}") throws -> CoreFrame {
        try CoreFrame(channel: 0, kind: .data, payload: Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}".utf8))
    }
    static func main() throws {
        let now = ContinuousClock().now
        let deadline = now.advanced(by: .seconds(10))
        var rpc = try CoreRPCRequests()
        let a = try rpc.begin(method: "terminal.list", deadline: deadline)
        let b = try rpc.begin(method: "server.status", deadline: deadline)
        try check(a.context.token.id == 1 && b.context.token.id == 2)
        try check(rpc.activeCount == 2 && rpc.occupiedSlots == 2 && rpc.nextDeadline == deadline)
        try check(rpc.pendingPayloadBytes == a.frame.payload.count + b.frame.payload.count)
        // Replies can arrive in the reverse order; match only by exact ID.
        guard case .reply(let contextB, let resultB) = try rpc.receive(reply(2), from: rpc.epoch, at: now) else { throw RPCTestFailure.failed("B not matched") }
        try check(contextB.method == "server.status" && resultB.id == 2)
        guard case .reply(let contextA, let resultA) = try rpc.receive(reply(1, "null"), from: rpc.epoch, at: now) else { throw RPCTestFailure.failed("A not matched") }
        try check(contextA.token == a.context.token)
        let null: String? = try resultA.result()
        try check(null == nil && rpc.pendingPayloadBytes == 0 && rpc.occupiedSlots == 0 && rpc.nextDeadline == nil)
        try fails(.unexpectedReply) { _ = try rpc.receive(reply(1), from: rpc.epoch, at: now) }

        var canceled = try CoreRPCRequests(maximumRequests: 1)
        let attach = try canceled.begin(method: "terminal.attach", deadline: deadline)
        try check(canceled.cancel(attach.context.token)?.method == "terminal.attach")
        try check(canceled.cancel(attach.context.token) == nil)
        try check(canceled.activeCount == 0 && canceled.occupiedSlots == 1 && canceled.nextDeadline == nil)
        try fails(.capacityExceeded) { _ = try canceled.begin(method: "terminal.list", deadline: deadline) }
        guard case .late(let original, let late, .cancelled) = try canceled.receive(reply(1, "{\"channel\":17}"), from: canceled.epoch, at: now) else { throw RPCTestFailure.failed("late attach missing") }
        let opened: RPCChannel = try late.result()
        try check(original.method == "terminal.attach" && opened.channel == 17)
        try check(canceled.occupiedSlots == 0 && canceled.pendingPayloadBytes == 0)
        let next = try canceled.begin(method: "terminal.list", deadline: deadline)
        try check(next.context.token.id == 2, "cancellation must never recycle an ID")

        var timed = try CoreRPCRequests()
        let t1 = try timed.begin(method: "terminal.send", deadline: now)
        let t2 = try timed.begin(method: "terminal.run", deadline: deadline)
        try check(timed.expire(at: now).map(\.token) == [t1.context.token])
        try check(timed.expire(at: now).isEmpty && timed.activeCount == 1 && timed.occupiedSlots == 2 && timed.nextDeadline == deadline)
        guard case .late(_, _, .timedOut) = try timed.receive(reply(t1.context.token.id), from: timed.epoch, at: now) else { throw RPCTestFailure.failed("expired reply delivered") }
        // No timer invocation: receiving at the deadline still cannot win it.
        guard case .late(_, _, .timedOut) = try timed.receive(reply(t2.context.token.id), from: timed.epoch, at: deadline) else { throw RPCTestFailure.failed("deadline did not win") }
        try check(timed.occupiedSlots == 0)

        var old = try CoreRPCRequests()
        let oldRequest = try old.begin(method: "terminal.list", deadline: deadline)
        var fresh = try CoreRPCRequests()
        let freshRequest = try fresh.begin(method: "terminal.list", deadline: deadline)
        try check(oldRequest.context.token.id == freshRequest.context.token.id && old.epoch != fresh.epoch)
        try fails(.staleEpoch) { _ = try fresh.receive(reply(1), from: old.epoch, at: now) }
        try check(fresh.cancel(oldRequest.context.token) == nil && fresh.activeCount == 1)
        try check(fresh.close().map(\.token) == [freshRequest.context.token])
        try check(fresh.close().isEmpty && fresh.pendingPayloadBytes == 0)
        try fails(.closed) { _ = try fresh.begin(method: "terminal.list", deadline: deadline) }
        try fails(.closed) { _ = try fresh.receive(reply(1), from: fresh.epoch, at: now) }

        var draining = try CoreRPCRequests()
        let d1 = try draining.begin(method: "terminal.list", deadline: deadline)
        let d2 = try draining.begin(method: "events.subscribe", deadline: deadline)
        let d3 = try draining.begin(method: "doc.get", deadline: deadline)
        draining.cancel(d2.context.token)
        try check(draining.close().map(\.token) == [d1.context.token, d3.context.token])
        try check(draining.expire(at: deadline).isEmpty && draining.occupiedSlots == 0)

        // Integer payloads stay exact, including values beyond Double precision.
        var exact = try CoreRPCRequests(startingRequestID: UInt64.max)
        let request = try exact.begin(method: "doc.set", parameters: Data("{\"version\":18446744073709551615}".utf8), deadline: deadline)
        try check(request.context.token.id == UInt64.max)
        guard case .reply(_, let huge) = try exact.receive(reply(UInt64.max, "{\"version\":18446744073709551615}"), from: exact.epoch, at: now) else { throw RPCTestFailure.failed("large ID") }
        let version: RPCVersion = try huge.result()
        try check(version.version == UInt64.max)
        try fails(.requestIDsExhausted) { _ = try exact.begin(method: "doc.get", deadline: deadline) }
        // Independently unpacked and parsed by Python in the runner.
        try request.frame.encoded().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

        let remote = try CoreFrame(channel: 0, kind: .data, payload: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"SECRET-FIXTURE\",\"data\":{\"kind\":\"needs_login\",\"hint\":\"SECRET-HINT\"}}}".utf8))
        let rejected = try CoreRPCReply(frame: remote)
        try check(rejected.error?.code == -32000 && rejected.error?.kind == "needs_login")
        try check(!String(describing: rejected).contains("SECRET") && !String(reflecting: rejected).contains("SECRET"))
        do { let _: RPCEmpty = try rejected.result(); throw RPCTestFailure.failed("remote error ignored") }
        catch let failure as CoreRPCRemoteFailure { try check(failure.kind == "needs_login" && !String(describing: failure).contains("SECRET")) }

        for invalid in [
            "{}", "[]", "{\"jsonrpc\":\"2.0\",\"id\":1}",
            "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":true,\"result\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"event\",\"result\":{}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":null}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":null}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1,\"message\":\"m\",\"data\":{\"kind\":\"secret path /\"}}}"
        ] {
            try fails(.invalidReply) { _ = try CoreRPCReply(frame: CoreFrame(channel: 0, kind: .data, payload: Data(invalid.utf8))) }
        }
        try fails(.invalidReply) { _ = try CoreRPCReply(frame: CoreFrame(channel: 1, kind: .data, payload: Data("{}".utf8))) }

        var bounded = try CoreRPCRequests(maximumPendingPayloadBytes: 128)
        let small = try bounded.begin(method: "a", deadline: deadline)
        try fails(.requestTooLarge) { _ = try bounded.begin(method: String(repeating: "a", count: 80), deadline: deadline) }
        try check(bounded.activeCount == 1 && bounded.pendingPayloadBytes == small.context.payloadBytes)
        try fails(.invalidMethod) { _ = try bounded.begin(method: "bad\nmethod", deadline: deadline) }
        for params in ["[]", "null", "\"string\"", "1", "not-json"] {
            try fails(.invalidParameters) { _ = try bounded.begin(method: "a", parameters: Data(params.utf8), deadline: deadline) }
        }
        try fails(.requestTooLarge) { _ = try bounded.begin(method: "a", parameters: Data(repeating: 32, count: 129), deadline: deadline) }
        try fails(.unexpectedReply) { _ = try bounded.receive(reply(999), from: bounded.epoch, at: now) }
        try check(bounded.close().map(\.token) == [small.context.token], "invalid reply must leave waiters available to drain")
        try fails(.invalidLimits) { _ = try CoreRPCRequests(maximumRequests: 0) }
        try fails(.invalidLimits) { _ = try CoreRPCRequests(maximumPendingPayloadBytes: 0) }
        try fails(.invalidLimits) { _ = try CoreRPCRequests(startingRequestID: 0) }

        // Tombstones are bounded even under a cancellation flood.
        var flood = try CoreRPCRequests(maximumRequests: 8)
        var tokens: [CoreRPCRequests.Token] = []
        for _ in 0..<8 {
            let request = try flood.begin(method: "terminal.attach", deadline: deadline)
            tokens.append(request.context.token); flood.cancel(request.context.token)
        }
        try check(flood.activeCount == 0 && flood.occupiedSlots == 8)
        try fails(.capacityExceeded) { _ = try flood.begin(method: "terminal.list", deadline: deadline) }
        for token in tokens.reversed() {
            guard case .late(_, _, .cancelled) = try flood.receive(reply(token.id), from: flood.epoch, at: now) else { throw RPCTestFailure.failed("lost tombstone") }
        }
        try check(flood.occupiedSlots == 0 && flood.pendingPayloadBytes == 0)
        try check(try flood.begin(method: "terminal.list", deadline: deadline).context.token.id == 9)
        print("PASS CoreRPC: \(checks) assertions (no transport I/O or timers)")
    }
}
