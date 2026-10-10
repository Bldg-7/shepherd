import NIO
import NIOSSH

extension SSHClient {
    /// Creates a new direct-streamlocal channel. This channel type is used to open a connection
    /// to a Unix domain socket on the remote server (the OpenSSH `direct-streamlocal@openssh.com`
    /// extension), e.g. herdr's local socket API at `~/.config/herdr/herdr.sock`.
    public func createDirectStreamlocalChannel(
        using settings: SSHChannelType.DirectStreamlocal,
        initialize: @escaping (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        return try await eventLoop.flatSubmit { [eventLoop, sshHandler = self.session.sshHandler] in
            let createdChannel = eventLoop.makePromise(of: Channel.self)
            sshHandler.value.createChannel(
                createdChannel,
                channelType: .directStreamlocal(settings)
            ) { channel, type in
                guard case .directStreamlocal = type else {
                    return channel.eventLoop.makeFailedFuture(SSHClientError.channelCreationFailed)
                }

                do {
                    try channel.pipeline.syncOperations.addHandler(DataToBufferCodec())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                return initialize(channel)
            }

            return createdChannel.futureResult
        }.get()
    }
}
