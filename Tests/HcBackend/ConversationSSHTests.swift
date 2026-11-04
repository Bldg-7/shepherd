import Foundation
import ShepherdKit
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
@preconcurrency import Citadel
import Crypto

private nonisolated final class State: @unchecked Sendable {
    let lock = NSLock()
    var channels: [any Channel] = [], pipes: [CoreProcessTransport] = [], tasks: [Task<Void, Never>] = []
    var execs = 0, ptys = 0, errors = 0
    private var pids: [Int32] = []
    func pid(_ pid: Int32) { lock.lock(); pids.append(pid); lock.unlock() }
    func ownedPIDs() -> [Int32] { lock.lock(); defer { lock.unlock() }; return pids }
    func add(_ channel: any Channel) -> Bool { lock.lock(); defer { lock.unlock() }; guard channels.count < 16 else { return false }; channels.append(channel); return true }
    func pipe(_ pipe: CoreProcessTransport) { lock.lock(); pipes.append(pipe); lock.unlock() }
    func task(_ task: Task<Void, Never>) { lock.lock(); tasks.append(task); lock.unlock() }
    func exec() { lock.lock(); execs += 1; lock.unlock() }
    func pty() { lock.lock(); ptys += 1; lock.unlock() }
    func error() { lock.lock(); errors += 1; lock.unlock() }
    func snapshot() -> ([any Channel], [CoreProcessTransport], [Task<Void, Never>], Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (channels,pipes,tasks,execs,ptys,errors) }
}
private nonisolated struct Auth: NIOSSHServerUserAuthenticationDelegate {
    let password: String
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let p) = request.request, request.username == "fixture", p.password == password { responsePromise.succeed(.success) }
        else { responsePromise.succeed(.failure) }
    }
}
private nonisolated final class Errors: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
private nonisolated final class Peer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var received = 0
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data); received += bytes.readableBytes
        guard received <= 65536 else { context.close(promise: nil); return }
        if bytes.readableBytesView.contains(10) {
            context.writeAndFlush(NIOAny(ByteBuffer(string: "capture-ready 한글\n")), promise: nil)
        }
    }
}
/// The SSH server only executes the exact precomputed fixed socket command.
private nonisolated final class Exec: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let expected: String, home: String, state: State
    var input: AsyncThrowingStream<Data, any Error>.Continuation?
    var worker: Task<Void, Never>?
    init(expected: String, home: String, state: State) { self.expected = expected; self.home = home; self.state = state }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.PseudoTerminalRequest { state.pty(); context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return }
        guard let exec = event as? SSHChannelRequestEvent.ExecRequest else { context.fireUserInboundEventTriggered(event); return }
        guard exec.command == expected, worker == nil else { context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return }
        state.exec()
        let pipe: CoreProcessTransport
        do { pipe = try CoreProcessTransport(configuration: .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",expected], environment: ["HOME":home,"PATH":"/usr/bin:/bin"], directory: URL(fileURLWithPath:home))) }
        catch { state.error(); context.close(promise: nil); return }
        state.pipe(pipe)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        input = continuation
        let channel = context.channel, state = state
        let task = Task.detached {
            var writer: Task<Void, Never>?
            do {
                try await pipe.start()
                if let pid = await pipe.snapshot().childPID { state.pid(pid) }
                else { state.error() }
                try await channel.triggerUserOutboundEvent(ChannelSuccessEvent()).get()
                writer = Task {
                    do { for try await bytes in stream { try await pipe.write(bytes) } }
                    catch { try? await pipe.close() }
                }
                while let bytes = try await pipe.read() { try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes:bytes)))).get() }
            } catch { }
            continuation.finish(); writer?.cancel()
            do { try await pipe.close() } catch { state.error() }
            if let writer { await writer.value }
            channel.close(promise: nil)
        }
        worker = task; state.task(task)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard data.type == .channel, case .byteBuffer(let bytes) = data.data, bytes.readableBytes <= 65536, let input else { context.close(promise:nil); return }
        if case .enqueued = input.yield(Data(bytes.readableBytesView)) {} else { context.close(promise:nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { input?.finish(); worker?.cancel(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { input?.finish(throwing:error); worker?.cancel(); context.close(promise:nil) }
}
@main @MainActor private struct ConversationSSHTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain:label,code:1) }; checks += 1 }
    static func main() async throws {
        let home = CommandLine.arguments[1], report = URL(fileURLWithPath:CommandLine.arguments[2])
        let socket = try HerdrLineEndpoint.conversations.path(home:home)
        try FileManager.default.createDirectory(at:URL(fileURLWithPath:socket).deletingLastPathComponent(),withIntermediateDirectories:true)
        let group = MultiThreadedEventLoopGroup(numberOfThreads:2), state = State()
        let peer = try await ServerBootstrap(group:group).childChannelInitializer { channel in
            guard state.add(channel) else { return channel.close() }
            return channel.pipeline.addHandler(Peer())
        }.bind(unixDomainSocketPath:socket).get()
        let key = NIOSSHPrivateKey(ed25519Key:Curve25519.Signing.PrivateKey())
        let pin = HostKeyFingerprint.compute(key.publicKey), password = UUID().uuidString+UUID().uuidString
        let expected = try CoreSSHTransport.Configuration.conversationHistory(host:"127.0.0.1",pinnedFingerprint:pin).command
        let server = try await ServerBootstrap(group:group).childChannelInitializer { parent in
            guard state.add(parent) else { return parent.close() }
            let handler = NIOSSHHandler(role:.server(SSHServerConfiguration(hostKeys:[key],userAuthDelegate:Auth(password:password))),allocator:parent.allocator,inboundChildChannelInitializer:{ child,type in
                guard case .session = type, state.add(child) else { return child.eventLoop.makeFailedFuture(CoreSSHFailure.execRejected) }
                return child.pipeline.addHandler(Exec(expected:expected,home:home,state:state))
            })
            do {
                try parent.pipeline.syncOperations.addHandlers([handler,Errors()])
                return parent.eventLoop.makeSucceededFuture(())
            } catch { return parent.eventLoop.makeFailedFuture(error) }
        }.bind(host:"127.0.0.1",port:0).get()
        let port = server.localAddress!.port!
        let transport: @MainActor @Sendable (String, String) throws -> CoreSSHTransport = { pin, secret in
            let config = try CoreSSHTransport.Configuration.conversationHistory(host:"127.0.0.1",port:port,pinnedFingerprint:pin)
            return CoreSSHTransport(configuration:config,authentication:{ SSHAuthenticationMethod.passwordBased(username:"fixture",password:secret) },group:group)
        }
        var failure: (any Error)?
        var owned: [Int32] = []
        do {
            let wrong = try transport("SHA256:not-the-key",password)
            do { try await wrong.start(); throw NSError(domain:"wrong key accepted",code:1) }
            catch CoreSSHFailure.hostKeyMismatch { checks += 1 }
            try await wrong.close()
            try check(state.snapshot().3 == 0,"wrong pin before exec")
            let denied = try transport(pin,"not-the-password")
            do { try await denied.start(); throw NSError(domain:"wrong password accepted",code:1) }
            catch CoreSSHFailure.authenticationFailed { checks += 1 }
            try await denied.close()
            try check(state.snapshot().3 == 0,"wrong credential before exec")
            let connection = ConversationLineConnection { _ in try await transport(pin,password) }
            let stream = try await connection.openLineStream(endpoint:.conversations,request:Data("{}\n".utf8))
            var iterator = stream.lines.makeAsyncIterator()
            try check(try await iterator.next() == Data("capture-ready 한글".utf8),"real pinned SSH -> fixed nc -> private capture socket -> Unicode line")
            stream.close(); try await connection.close()
            try check(!expected.contains(" connect") && !expected.contains("herdr.sock"),"no terminal backend handshake or CLI")
            try check(expected.contains("env -i HOME="),"capture child receives no inherited agent/config authority")
        } catch { failure = error }
        try await server.close().get(); try await peer.close().get()
        for channel in state.snapshot().0 where channel.isActive { try await channel.close().get() }
        for task in state.snapshot().2 { await task.value }
        for pipe in state.snapshot().1 {
            let snap = await pipe.snapshot()
            try check(snap.started && snap.closed && snap.reaped,"owned nc child reaped")
        }
        try await group.shutdownGracefully()
        try check(!FileManager.default.fileExists(atPath:socket),"private capture socket removed by listener shutdown")
        let final = state.snapshot()
        owned = state.ownedPIDs()
        try check(owned.count == 1 && final.1.count == 1,"exact nc child PID recorded before close")
        try check(final.3 == 1 && final.4 == 0 && final.5 == 0,"one capture exec, no PTY, no child cleanup errors")
        try JSONSerialization.data(withJSONObject:["passed":failure == nil,"checks":checks,"ownedPIDs":owned,"failure":failure.map{String(describing:$0)} ?? "","coreStarted":false]).write(to:report)
        if let failure { throw failure }
        print("PASS independent capture SSH/socket: \(checks) checks")
    }
}
