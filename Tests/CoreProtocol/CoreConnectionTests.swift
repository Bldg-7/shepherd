import Foundation

#if os(macOS)
nonisolated struct FixtureValue: Decodable, Sendable { let value: Int }
nonisolated struct FixtureEmpty: Decodable, Sendable {}
nonisolated struct FixtureList: Decodable, Sendable { let terminals: [String]; let inherited_marker: Bool; let cwd: String }
nonisolated enum ConnectionTestError: Error { case failed(String) }

@main @MainActor
struct CoreConnectionTests {
    static var checks = 0
    static var python = ""
    static var fixture = ""
    static var work = ""
    static func check(_ condition: @autoclosure () -> Bool, _ message: String = #function) throws {
        checks += 1
        guard condition() else { throw ConnectionTestError.failed(message) }
    }
    static func expect(_ expected: CoreConnectionFailure, _ operation: () async throws -> Void) async throws {
        do { try await operation(); throw ConnectionTestError.failed("expected \(expected)") }
        catch let actual as CoreConnectionFailure { try check(actual == expected, "wrong connection error") }
    }
    static func make(_ mode: String = "normal", writeLimit: Int = 2 << 20,
                     connectionLimit: Int = 2 << 20, maximumStreams: Int = 32) throws -> (CoreProcessTransport, CoreRPCConnection) {
        let endpoint = try CoreProcessTransport(configuration: .init(
            executable: URL(fileURLWithPath: python), arguments: ["-I", fixture, mode],
            environment: ["PATH": "/usr/bin:/bin", "HOME": work, "TMPDIR": work, "LANG": "en_US.UTF-8"],
            directory: URL(fileURLWithPath: work), maximumWriteBytes: writeLimit))
        let connection = try CoreRPCConnection(transport: endpoint, maximumPendingPayloadBytes: 3 << 20,
                                               maximumQueuedWriteBytes: connectionLimit, maximumStreams: maximumStreams)
        return (endpoint, connection)
    }
    static func retired(_ endpoint: CoreProcessTransport, _ connection: CoreRPCConnection, spawned: Bool = true) async throws {
        try await connection.close()
        let snapshot = await endpoint.snapshot()
        try check(snapshot.closed && snapshot.childPID == nil && snapshot.queuedWriteBytes == 0, "owned process/fds did not retire")
        try check(snapshot.reaped == spawned, "spawned child was not reaped")
        try await connection.close()
    }
    static func main() async throws {
        python = CommandLine.arguments[1]; fixture = CommandLine.arguments[2]; work = CommandLine.arguments[3]
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        try await normal(); print("PASS normal RPC, reversed replies, stderr and last reply")
        try await failedConnections(); print("PASS handshake/EOF/error/cleanup failures")
        try await blockedWriter(); print("PASS blocked writer quotas and queued timeout")
        try await cancellationAndClose(); print("PASS cancellation, close and fresh epoch")
        try await streamsAndCredit(); print("PASS stream ownership, CREDIT, events and late opens")
        print("PASS CoreConnection: \(checks) assertions, real owned pipe children; no installed hc/SSH/app")
    }
    static func normal() async throws {
        let (endpoint, connection) = try make()
        let hello = try await connection.connect()
        try check(hello.core.id == "owned-process-fixture" && hello.framed)
        let list: FixtureList = try await connection.call("terminal.list").result()
        try check(list.terminals.isEmpty && !list.inherited_marker && list.cwd == work, "explicit environment/cwd must be honored")
        async let first = connection.call("fixture.reverse", parameters: Data("{\"value\":1}".utf8))
        async let second = connection.call("fixture.reverse", parameters: Data("{\"value\":2}".utf8))
        let pair = try await (first, second)
        let a: FixtureValue = try pair.0.result(), b: FixtureValue = try pair.1.result()
        try check(a.value == 1 && b.value == 2, "out-of-order replies crossed callers")
        let error = try await connection.call("fixture.fail")
        try check(error.error?.kind == "not_found" && !String(describing: error).contains("PRIVATE"))
        _ = try await connection.call("fixture.stderr")
        let stats = await endpoint.snapshot()
        try check(stats.stderrBytesDiscarded >= 128 * 1024, "stderr not independently drained")
        do {
            try await expect(.streamingNotSupported) { _ = try await connection.call("terminal.attach") }
            try await expect(.streamingNotSupported) { _ = try await connection.call("events.subscribe") }
            try await expect(.reservedMethod) { _ = try await connection.call("hello") }
            try await expect(.methodUnavailable) { _ = try await connection.call("not.advertised") }
            try await expect(.invalidTimeout) { _ = try await connection.call("terminal.list", timeout: .zero) }
        }
        let canceled = Task { try await connection.call("fixture.slow", parameters: Data("{\"value\":7}".utf8)) }
        _ = try await connection.call("fixture.slowBarrier")
        canceled.cancel()
        do { _ = try await canceled.value; throw ConnectionTestError.failed("canceled RPC succeeded") }
        catch is CancellationError { checks += 1 }
        var state = await connection.snapshot()
        try check(state.occupiedRequestSlots == 1 && state.awaitingReplies == 0, "late-reply tombstone missing")
        _ = try await connection.call("fixture.flush")
        state = await connection.snapshot()
        try check(state.occupiedRequestSlots == 0, "late cancellation reply not consumed")
        try await expect(.requestTimedOut) { _ = try await connection.call("fixture.slow", timeout: .milliseconds(100)) }
        _ = try await connection.call("fixture.flush")
        state = await connection.snapshot()
        try check(state.occupiedRequestSlots == 0 && state.state == .ready, "RPC timeout must not kill a healthy connection")
        let last: FixtureValue = try await connection.call("fixture.last").result()
        try check(last.value == 99, "last reply lost on process exit")
        try await retired(endpoint, connection)
    }
    static func failedConnections() async throws {
        for mode in ["hang-hello", "ignore-hello"] {
            let (endpoint, connection) = try make(mode)
            try await expect(.handshakeTimedOut) { _ = try await connection.connect(timeout: .milliseconds(100)) }
            try await retired(endpoint, connection)
            if mode == "ignore-hello" {
                let stats = await endpoint.snapshot()
                try check(stats.waitStatus.map { $0 & 0x7f == 9 } == true, "TERM/EOF-ignoring child was not killed/reaped")
            }
        }
        for (mode, expected) in [("bad-hello", CoreWire.Failure.invalidHello), ("partial-hello", .truncatedHello)] {
            let (endpoint, connection) = try make(mode)
            do { _ = try await connection.connect(); throw ConnectionTestError.failed("invalid handshake accepted") }
            catch let error as CoreWire.Failure { try check(error == expected) }
            try await retired(endpoint, connection)
        }
        for method in ["fixture.partial", "fixture.invalid"] {
            let (endpoint, connection) = try make()
            _ = try await connection.connect()
            do { _ = try await connection.call(method); throw ConnectionTestError.failed("invalid reply accepted") }
            catch CoreWire.Failure.truncatedFrame { try check(method == "fixture.partial") }
            catch CoreRPCFailure.invalidReply { try check(method == "fixture.invalid") }
            try await retired(endpoint, connection)
        }
        let missing = try CoreProcessTransport(configuration: .init(executable: URL(fileURLWithPath: work + "/absent-hc"), environment: [:]))
        let absent = try CoreRPCConnection(transport: missing)
        do { _ = try await absent.connect(); throw ConnectionTestError.failed("missing executable launched") }
        catch CoreProcessFailure.system { checks += 1 }
        try await retired(missing, absent, spawned: false)
        let (small, smallConnection) = try make(writeLimit: 4)
        do { _ = try await smallConnection.connect(); throw ConnectionTestError.failed("writer overflow accepted") }
        catch CoreProcessFailure.writeLimitExceeded { checks += 1 }
        try await retired(small, smallConnection)
        let (closedInput, broken) = try make("close-input")
        _ = try await broken.connect()
        do {
            _ = try await broken.call("fixture.echo", parameters: Data(("{\"text\":\"" + String(repeating: "x", count: 800_000) + "\"}").utf8))
            throw ConnectionTestError.failed("closed stdin accepted write")
        } catch CoreProcessFailure.system { checks += 1 }
        try await retired(closedInput, broken)
    }
    static func blockedWriter() async throws {
        let (endpoint, connection) = try make("no-read", connectionLimit: 1 << 20)
        _ = try await connection.connect()
        let parameters = Data(("{\"text\":\"" + String(repeating: "x", count: 800_000) + "\"}").utf8)
        try await expect(.requestTimedOut) { _ = try await connection.call("fixture.echo", parameters: parameters, timeout: .milliseconds(200)) }
        let state = await connection.snapshot()
        try check(state.queuedWriteBytes > 700_000 && state.occupiedRequestSlots == 1, "RPC timeout must retain in-flight writer accounting")
        try await expect(.writeLimitExceeded) { _ = try await connection.call("fixture.echo", parameters: parameters) }
        let afterRejection = await connection.snapshot()
        try check(afterRejection.occupiedRequestSlots == 1 && afterRejection.awaitingReplies == 0, "unsent rejection leaked a tombstone")
        // This small request queues behind the blocked frame and expires
        // without ever reaching the writer; its reservation must be released.
        try await expect(.requestTimedOut) { _ = try await connection.call("terminal.list", timeout: .milliseconds(100)) }
        let afterQueuedTimeout = await connection.snapshot()
        try check(afterQueuedTimeout.occupiedRequestSlots == 1 && afterQueuedTimeout.queuedWriteBytes == state.queuedWriteBytes)
        try await retired(endpoint, connection)
    }
    static func cancellationAndClose() async throws {
        let (before, neverStarted) = try make()
        try await neverStarted.close()
        try await expect(.alreadyStarted) { _ = try await neverStarted.connect() }
        try await retired(before, neverStarted, spawned: false)
        let (endpoint, connection) = try make("ignore-term")
        _ = try await connection.connect()
        let pending = Task { try await connection.call("fixture.slow") }
        _ = try await connection.call("fixture.slowBarrier")
        async let close1: Void = connection.close()
        async let close2: Void = connection.close()
        _ = try await (close1, close2)
        do { _ = try await pending.value; throw ConnectionTestError.failed("pending call survived close") }
        catch CoreConnectionFailure.closed { checks += 1 }
        try await retired(endpoint, connection)
        let (cancelEndpoint, cancelConnection) = try make("hang-hello")
        let task = Task { try await cancelConnection.connect(timeout: .seconds(10)) }
        // The cancellation handler must also work if cancellation wins before
        // the async connect begins. No assumption about which side won.
        task.cancel()
        do { _ = try await task.value; throw ConnectionTestError.failed("canceled connect succeeded") }
        catch is CancellationError { checks += 1 }
        try await cancelConnection.close()
        let canceled = await cancelEndpoint.snapshot()
        try check(canceled.closed && canceled.childPID == nil)
        let (freshEndpoint, fresh) = try make()
        _ = try await fresh.connect()
        try check(fresh.epoch != connection.epoch)
        try await retired(freshEndpoint, fresh)
    }
}
#endif
