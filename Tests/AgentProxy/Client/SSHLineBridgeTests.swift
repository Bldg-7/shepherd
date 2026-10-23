import Foundation
import NIOCore
import NIOEmbedded

// Accessed only by this test's serial EmbeddedEventLoop.
nonisolated final class CloseFlag: @unchecked Sendable { var value = false }

@main struct SSHLineBridgeTests {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); passed += 1
        }
        func fixture() throws -> (EmbeddedChannel, EmbeddedEventLoop, ConversationSSHLineChannel, AsyncThrowingStream<Data, any Error>) {
            let loop = EmbeddedEventLoop()
            let gate = ConversationSSHLineChannel()
            let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
            continuation.onTermination = { _ in gate.close() }
            let bridge = ConversationSSHLineBridge(continuation: continuation, lifetime: gate)
            let channel = EmbeddedChannel(handler: bridge, loop: loop)
            gate.install(channel)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
            return (channel, loop, gate, stream)
        }
        do {
            let (channel, loop, gate, stream) = try fixture()
            var it = stream.makeAsyncIterator()
            try channel.writeInbound(ByteBuffer(string: "fi"))
            try channel.writeInbound(ByteBuffer(string: "rst\nsecond\n"))
            check(try await it.next() == Data("first".utf8), "fragmented first line")
            check(try await it.next() == Data("second".utf8), "multiple completed lines")
            loop.advanceTime(by: .seconds(6))
            check(channel.isActive, "complete acknowledgement cancels deadline")
            gate.close(); loop.run()
            check(!channel.isActive, "explicit consumer close retires channel")
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
        do {
            let (channel, loop, _, stream) = try fixture()
            var it = stream.makeAsyncIterator()
            loop.advanceTime(by: .seconds(5))
            do { _ = try await it.next(); check(false, "missing acknowledgement") }
            catch HerdrLineStreamError.timedOut { check(true, "unacknowledged channel times out deterministically") }
            check(!channel.isActive, "timeout closes SSH child channel")
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
        do {
            let (channel, loop, _, stream) = try fixture()
            var it = stream.makeAsyncIterator()
            try channel.writeInbound(ByteBuffer(string: "one\ntwo\nthree\n")); loop.run()
            check(try await it.next() == Data("one".utf8), "bounded oldest queue first entry")
            check(try await it.next() == Data("two".utf8), "bounded oldest queue second entry")
            do { _ = try await it.next(); check(false, "silent dropped delta") }
            catch HerdrLineStreamError.slowConsumer { check(true, "overflow reports loss rather than silently replacing delta") }
            check(!channel.isActive, "slow consumer closes channel")
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
        do {
            let (channel, loop, _, stream) = try fixture()
            var it = stream.makeAsyncIterator()
            try channel.writeInbound(ByteBuffer(bytes: [UInt8](repeating: 65, count: BoundedHostLines.maximumLineBytes) + [10])); loop.run()
            do { _ = try await it.next(); check(false, "oversized line") }
            catch HerdrLineStreamError.lineTooLong { check(true, "SSH framing rejects a completed oversized line") }
            check(!channel.isActive, "oversized input closes only child channel")
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
        do {
            let (channel, _, _, stream) = try fixture()
            var it = stream.makeAsyncIterator()
            try channel.writeInbound(ByteBuffer(string: "partial"))
            try channel.close().wait()
            do { _ = try await it.next(); check(false, "partial EOF") }
            catch HerdrLineStreamError.closed { check(true, "partial line EOF is not a successful update") }
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
        do {
            let gate = ConversationSSHLineChannel(); gate.close()
            let loop = EmbeddedEventLoop(), closed = CloseFlag()
            let channel = EmbeddedChannel(loop: loop)
            channel.closeFuture.whenSuccess { closed.value = true }
            gate.install(channel); loop.run()
            // EmbeddedChannel can be artificially reactivated with connect()
            // after close, unlike the real SSH child. Assert actual retirement.
            check(closed.value && !channel.isActive, "cancellation before channel installation persists")
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
        print("SSH line bridge: \(passed) passed, 0 failed")
    }
}
