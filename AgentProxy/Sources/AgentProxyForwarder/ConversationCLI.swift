import Foundation
import NIOCore
import NIOPosix
import AgentProxyCore
import AgentProxyProtocol

/// Local diagnostic reader. Only explicitly addressed read sockets; no model
/// calls, terminal scraping, transcript files or implicit helper launch.
public enum AgentProxyConversationCLI {
    public enum Failure: Error { case unavailable, invalidReply, noConversation }

    /// Prints one bounded latest page, including its stable paging cursor.
    public static func show(socketPath: String, terminalID: String) throws -> Data {
        guard AgentProxyPaths.socketPathFits(socketPath), !terminalID.isEmpty, terminalID.utf8.count <= 256,
              !terminalID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unavailable }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        func query(_ method: String, _ params: [String: String]) throws -> Data {
            var request = try JSONSerialization.data(withJSONObject: ["id": "show", "method": method, "params": params])
            request.append(10)
            let promise = group.next().makePromise(of: Data.self)
            let handler = ReadReply(request: request, promise: promise)
            let channel = try ClientBootstrap(group: group).connectTimeout(.seconds(2))
                .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 64 << 10))
                .channelInitializer { channel in channel.pipeline.addHandler(handler) }
                .connect(unixDomainSocketPath: socketPath).wait()
            let deadline = channel.eventLoop.scheduleTask(in: .seconds(5)) { handler.fail(); channel.close(promise: nil) }
            defer { deadline.cancel(); try? channel.close().wait() }
            return try promise.futureResult.wait()
        }
        let listed = try JSONDecoder().decode(ConversationReadAPI.Reply.self, from: query("conversations.list", ["terminalID": terminalID]))
        guard listed.error == nil, let list = listed.result, list.protocolVersion == ConversationReadAPI.protocolVersion, !list.reset else { throw Failure.invalidReply }
        guard let latest = list.conversations?.first else { throw Failure.noConversation }
        let response = try query("conversation.read", ["conversationID": latest.id, "epoch": list.epoch])
        let read = try JSONDecoder().decode(ConversationReadAPI.Reply.self, from: response)
        guard read.error == nil, let result = read.result, result.protocolVersion == ConversationReadAPI.protocolVersion,
              !result.reset, result.summary?.id == latest.id, result.epoch == list.epoch else { throw Failure.invalidReply }
        return response
    }
}

private final class ReadReply: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let request: Data
    let promise: EventLoopPromise<Data>
    var bytes = Data()
    var done = false
    init(request: Data, promise: EventLoopPromise<Data>) { self.request = request; self.promise = promise }
    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: request.count); buffer.writeBytes(request)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        context.fireChannelActive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        let input = unwrapInboundIn(data).readableBytesView
        guard input.count <= ConversationReadAPI.maximumReplyBytes - bytes.count else { fail(); context.close(promise: nil); return }
        bytes.append(contentsOf: input)
        if let end = bytes.firstIndex(of: 10) {
            guard end == bytes.count - 1 else { fail(); context.close(promise: nil); return }
            done = true; promise.succeed(bytes); context.close(promise: nil)
        }
    }
    func fail() { guard !done else { return }; done = true; promise.fail(AgentProxyConversationCLI.Failure.unavailable) }
    func channelInactive(context: ChannelHandlerContext) { fail(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(); context.close(promise: nil) }
}
