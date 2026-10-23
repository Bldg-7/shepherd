import Foundation
#if canImport(Citadel)
import NIOCore

/// Cancellation may arrive while SSH is still opening the child channel. Keep
/// the cancellation bit before a channel exists and close it as soon as it does.
nonisolated final class ConversationSSHLineChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var stopped = false
    func install(_ channel: Channel) {
        lock.lock()
        let close = stopped
        if !close { self.channel = channel }
        lock.unlock()
        if close { channel.close(promise: nil) }
    }
    func close() {
        lock.lock(); stopped = true; let channel = channel; self.channel = nil; lock.unlock()
        channel?.close(promise: nil)
    }
    func retired() { lock.lock(); channel = nil; lock.unlock() }
}

/// No intermediate unbounded AsyncStream<ByteBuffer>. Framing and admission
/// happen synchronously on the SSH channel's event loop before yielding a line.
nonisolated final class ConversationSSHLineBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    let lifetime: ConversationSSHLineChannel
    private var buffer = BoundedHostLines()
    private var deadline: Scheduled<Void>?
    private var received = false
    private var ended = false
    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation, lifetime: ConversationSSHLineChannel) {
        self.continuation = continuation; self.lifetime = lifetime
    }
    func channelActive(context: ChannelHandlerContext) {
        deadline = context.eventLoop.scheduleTask(in: .seconds(5)) {
            if !self.received { self.finish(HerdrLineStreamError.timedOut); self.lifetime.close() }
        }
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !ended else { return }
        do {
            try buffer.append(unwrapInboundIn(data).readableBytesView) { line in
                received = true; deadline?.cancel(); deadline = nil
                switch continuation.yield(line) {
                case .enqueued: break
                case .dropped: throw HerdrLineStreamError.slowConsumer
                case .terminated: throw CancellationError()
                @unknown default: throw HerdrLineStreamError.closed
                }
            }
        } catch { finish(error); context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        finish(buffer.hasIncompleteLine ? HerdrLineStreamError.closed : nil)
        lifetime.retired(); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(HerdrLineStreamError.closed); context.close(promise: nil)
    }
    private func finish(_ error: (any Error)?) {
        guard !ended else { return }; ended = true; deadline?.cancel(); deadline = nil
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
#endif
