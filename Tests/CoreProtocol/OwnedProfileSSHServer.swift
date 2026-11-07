import Foundation
import AppKit
import ShepherdKit
import SwiftTerm
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
@preconcurrency import Citadel
import Crypto

private nonisolated final class ServerState: @unchecked Sendable {
    let lock = NSLock()
    private var channels: [any Channel] = []
    private var tasks: [Task<Void, Never>] = []
    private var execs = 0
    private var ptys = 0
    private var cleanupErrors = 0
    private var holdExec = false
    func hold(_ value: Bool) { lock.lock(); holdExec = value; lock.unlock() }
    func isHeld() -> Bool { lock.lock(); defer { lock.unlock() }; return holdExec }
    func add(_ c: any Channel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard channels.count < 16 else { return false }
        channels.append(c); return true
    }
    func add(_ t: Task<Void, Never>) { lock.lock(); tasks.append(t); lock.unlock() }
    func exec() { lock.lock(); execs += 1; lock.unlock() }
    func pty() { lock.lock(); ptys += 1; lock.unlock() }
    func cleanupError() { lock.lock(); cleanupErrors += 1; lock.unlock() }
    func counts() -> (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (execs,ptys,cleanupErrors) }
    func owned() -> ([any Channel], [Task<Void, Never>]) { lock.lock(); defer { lock.unlock() }; return (channels,tasks) }
}
@MainActor private final class FactorySecrets: MachineSecretStore {
    var data: [String: Data] = [:]
    var reads = 0
    func saveSecret(_ bytes: Data, tag: String) throws { data[tag] = bytes }
    func loadSecret(tag: String) throws -> Data? { reads += 1; return data[tag] }
    func deleteSecret(tag: String) throws { data[tag] = nil }
}
private nonisolated struct ServerAuth: NIOSSHServerUserAuthenticationDelegate {
    let password: String
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let p) = request.request, request.username == "fixture", p.password == password {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}
private nonisolated final class ServerErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
/// Only precomputed exact exec commands may choose their corresponding owned
/// configuration. In particular, production discovery executes its actual shell
/// script; it is not silently replaced with the direct executable command.
private nonisolated final class OwnedExec: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let commands: [String:CoreProcessTransport.Configuration]
    let state: ServerState
    private var input: AsyncThrowingStream<Data, Error>.Continuation?
    private var worker: Task<Void, Never>?
    init(commands: [String:CoreProcessTransport.Configuration], state: ServerState) {
        self.commands = commands; self.state = state
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.PseudoTerminalRequest {
            state.pty(); context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return
        }
        guard let exec = event as? SSHChannelRequestEvent.ExecRequest else { context.fireUserInboundEventTriggered(event); return }
        guard let config = commands[exec.command], worker == nil else { context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return }
        state.exec()
        if state.isHeld() { return } // Exercise cancellation while exec ACK is pending.
        let pipe: CoreProcessTransport
        do { pipe = try CoreProcessTransport(configuration: config) }
        catch { context.close(promise: nil); return }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        input = pair.continuation
        let channel = context.channel, state = state
        let task = Task.detached {
            var writer: Task<Void, Never>?
            do {
                try await pipe.start()
                try await channel.triggerUserOutboundEvent(ChannelSuccessEvent()).get()
                writer = Task {
                    do { for try await bytes in pair.stream { try await pipe.write(bytes) } }
                    catch { try? await pipe.close() }
                }
                while let bytes = try await pipe.read() {
                    try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))).get()
                }
            } catch { }
            pair.continuation.finish(); writer?.cancel()
            do { try await pipe.close() } catch { state.cleanupError() }
            if let writer { await writer.value }
            channel.close(promise: nil)
        }
        worker = task; state.add(task)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard data.type == .channel, case .byteBuffer(let bytes) = data.data, bytes.readableBytes <= 64 << 10,
              let input else { context.close(promise: nil); return }
        switch input.yield(Data(bytes.readableBytesView)) {
        case .enqueued: break
        default: context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { input?.finish(); worker?.cancel(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { input?.finish(throwing: error); worker?.cancel(); context.close(promise: nil) }
}


private nonisolated struct ProfileServerStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}
private nonisolated struct ProfileServerStop: Decodable, Sendable { let stopped: Bool }
private nonisolated struct ProfileCredentials: Encodable {
    let machine: Machine; let password: String; let expectedCoreID: String
}
@main @MainActor private struct OwnedProfileSSHServer {
    private nonisolated static func persist(_ data: Data, to file: URL) throws {
        guard data.count <= 1 << 20 else { throw CoreConnectionFailure.writeLimitExceeded }
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 5, let port = Int(CommandLine.arguments[3]),
              let seconds = Int(CommandLine.arguments[4]), (30...420).contains(seconds) else {
            throw CoreConnectionFailure.notReady
        }
        let binary = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = URL(fileURLWithPath:CommandLine.arguments[2])
        let home = root.appending(path:"remote core")
        try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let socket = home.appending(path:"c.sock")
        guard socket.path.utf8.count < 104 else { throw CoreConnectionFailure.notReady }
        let env = ["PATH":"/usr/bin:/bin","HOME":home.path,"XDG_STATE_HOME":home.appending(path:"state").path,
            "XDG_CONFIG_HOME":home.appending(path:"config").path,"XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
            "HC_SESSION":"owned","HC_SOCKET":socket.path,"SSH_CONNECTION":"owned-fixture-no-launchd","DO_NOT_TRACK":"1"]
        let transport = try CoreProcessTransport(configuration:.init(executable:binary,environment:env,directory:home))
        let control = try CoreRPCConnection(transport:transport)
        let hello = try await control.connect()
        guard hello.version == "0.1.17" else { throw CoreConnectionFailure.notReady }
        let state = ServerState(), group = MultiThreadedEventLoopGroup(numberOfThreads:2)
        var server: (any Channel)?
        var model: HcWorkspaceModel?
        var failure: (any Error)?
        var owned: [UInt32] = []
        let credentialsFile = root.appending(path:"remote-profile-secret.json")
        let report = root.appending(path:"remote-report.json")
        func statusReceipt() async throws {
            let status: ProfileServerStatus = try await control.call("server.status").result()
            let programs = try await HcTerminalBoard(connection:control).list(all:true)
            owned = Array(Set(owned + [status.pid] + status.holders.map(\.pid) + programs.compactMap(\.pid))).sorted()
            try JSONSerialization.data(withJSONObject:["ownedPIDs":owned,"corePID":status.pid])
                .write(to:report,options:.atomic)
        }
        do {
            try await statusReceipt()
            let recovery = root.appending(path:"remote-recovery.json"), focus = root.appending(path:"remote-focus.json")
            let next = HcWorkspaceModel(connection:control,saveRecovery:{ try Self.persist($0,to:recovery) },saveFocus:{ try Self.persist($0,to:focus) }); model = next
            try await next.start()
            let workspace = try await next.createWorkspace(name:"Owned SSH origin B")
            try await next.launchTab(workspaceID:workspace,name:"Remote-only pane",
                argv:["/usr/bin/python3","-I","-S","-B","-c","import time\nprint('HC-REMOTE-ORIGIN-B',flush=True)\ntime.sleep(360)\n"],
                cwd:home.path)
            try await statusReceipt()
            let key = Curve25519.Signing.PrivateKey()
            let password = UUID().uuidString + UUID().uuidString
            let pin = HostKeyFingerprint.compute(NIOSSHPrivateKey(ed25519Key:key).publicKey)
            let command = try HcConnectionPolicy.remoteCommand(session:"owned")
            func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of:"'",with:"'\\''") + "'" }
            let bin = home.appending(path:".local/bin")
            try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
            let shim = bin.appending(path:"hc")
            try ("#!/bin/sh\nset -eu\ntest \"$HC_SESSION\" = owned\nexport HC_SOCKET=" + quoted(socket.path) +
                 "\nexec " + quoted(binary.path) + " \"$@\"\n").write(to:shim,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shim.path)
            let config = CoreProcessTransport.Configuration(executable:URL(fileURLWithPath:"/bin/sh"),
                arguments:["-c",command],environment:env,directory:home)
            let commands = [command:config]
            server = try await ServerBootstrap(group:group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr),value:1)
                .childChannelInitializer { parent in
                    guard state.add(parent) else { return parent.close() }
                    let handler = NIOSSHHandler(role:.server(SSHServerConfiguration(hostKeys:[NIOSSHPrivateKey(ed25519Key:key)],
                        userAuthDelegate:ServerAuth(password:password))),allocator:parent.allocator,inboundChildChannelInitializer:{ child,type in
                        guard case .session = type else { return child.eventLoop.makeFailedFuture(CoreSSHFailure.execRejected) }
                        return child.pipeline.addHandler(OwnedExec(commands:commands,state:state))
                    })
                    do { try parent.pipeline.syncOperations.addHandlers([handler,ServerErrorHandler()]); return parent.eventLoop.makeSucceededFuture(()) }
                    catch { return parent.eventLoop.makeFailedFuture(error) }
                }.bind(host:"127.0.0.1",port:port).get()
            let machine = Machine(displayName:"Owned SSH origin B",hostname:"127.0.0.1",port:port,username:"fixture",
                                  authMethod:.password,sessionName:"owned")
            try JSONEncoder().encode(ProfileCredentials(machine:machine,password:password,expectedCoreID:hello.core.id))
                .write(to:credentialsFile,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:credentialsFile.path)
            let ready: [String:Any] = ["port":port,"fingerprint":pin,"coreID":hello.core.id,"machineID":machine.id.uuidString,
                "credentialTemporaryPrivateFile":true,"credentialLogged":false,"terminal":next.selectedTab?.layout?.panes.first?.terminal?.terminalID ?? ""]
            try JSONSerialization.data(withJSONObject:ready).write(to:root.appending(path:"remote-ready.json"),options:.atomic)
            try FileHandle.standardOutput.write(contentsOf:Data("OWNED_PROFILE_SSH_READY\n".utf8))
            let deadline = ContinuousClock.now.advanced(by:.seconds(seconds))
            while !FileManager.default.fileExists(atPath:root.appending(path:"stop.request").path) {
                guard ContinuousClock.now < deadline else { throw CoreConnectionFailure.requestTimedOut }
                try await Task.sleep(for:.milliseconds(30))
            }
        } catch { failure = error }
        try? FileManager.default.removeItem(at:credentialsFile)
        // Stop accepting clients, close only this fixture's channels, then join
        // workers before their owned event loops. Never signal a user service.
        if let server { try? await server.close().get() }
        for channel in state.owned().0 { try? await channel.close().get() }
        for task in state.owned().1 { await task.value }
        let stopped: ProfileServerStop? = try? await control.call("server.stop").result()
        try await model?.disconnect()
        try await control.close()
        try await group.shutdownGracefully()
        let closed = await transport.snapshot(), counts = state.counts()
        let good = failure == nil && stopped?.stopped == true && closed.reaped && counts.1 == 0 && counts.2 == 0
        var facts: [String:Any] = ["passed":good,"ownedPIDs":owned,"coreStopped":stopped?.stopped == true,
            "connectReaped":closed.reaped,"ptyCount":counts.1,"execCount":counts.0,"cleanupErrors":counts.2,
            "credentialFileRemoved":!FileManager.default.fileExists(atPath:credentialsFile.path),"realSSHAccount":false,"guiQualified":false]
        if let failure { facts["failureType"] = String(describing:type(of:failure)) }
        try JSONSerialization.data(withJSONObject:facts,options:[.prettyPrinted,.sortedKeys]).write(to:report,options:.atomic)
        guard good else { throw failure ?? CoreConnectionFailure.closed }
        try FileHandle.standardOutput.write(contentsOf:Data("OWNED_PROFILE_SSH_RETIRED\n".utf8))
    }
}
