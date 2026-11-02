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
/// The test SSH server accepts exactly one known exec command; it never runs a
/// arbitrary client shell text. It runs only the precomputed, quoted command
/// in a private /bin/sh, matching an SSH server's exec parsing semantics.
private nonisolated final class OwnedExec: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let expected: String
    let config: CoreProcessTransport.Configuration
    let state: ServerState
    private var input: AsyncThrowingStream<Data, Error>.Continuation?
    private var worker: Task<Void, Never>?
    init(expected: String, config: CoreProcessTransport.Configuration, state: ServerState) {
        self.expected = expected; self.config = config; self.state = state
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.PseudoTerminalRequest {
            state.pty(); context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return
        }
        guard let exec = event as? SSHChannelRequestEvent.ExecRequest else { context.fireUserInboundEventTriggered(event); return }
        guard exec.command == expected, worker == nil else { context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return }
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

nonisolated struct IntegrationStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let live: Int; let core: CoreHello.Identity; let holders: [Holder]
}
nonisolated struct RunTerminal: Decodable, Sendable { let address: String; let pid: UInt32? }
nonisolated struct ReadTerminal: Decodable, Sendable { let text: String }
nonisolated struct IntegrationStop: Decodable, Sendable { let stopped: Bool }
nonisolated enum IntegrationFailure: Error { case failed(String) }

@main @MainActor
private struct SSHStreamIntegrationTests {
    static var checks = 0
    static func check(_ b: Bool, _ label: String) throws {
        checks += 1; if !b { throw IntegrationFailure.failed(label) }
        FileHandle.standardError.write(Data(("PASS " + label + "\n").utf8))
    }
    static func params(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    static func text(of view: View) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                                                          characterProvider: { terminal.getCharacter(for: $0) })
        }.joined(separator: "\n")
    }
    final class Sink: TerminalViewDelegate {
        var bytes = Data()
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String:String]) {}
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
    final class View: TerminalView {
        let sink = Sink()
        var sent: Data { get { sink.bytes } set { sink.bytes = newValue } }
        func bind() { terminalDelegate = sink }
    }
    static func main() async throws {
        let passed = try await run()
        // Let stream/connection destructors run after their owned EventLoopGroup
        // has shut down too; repeated close must not schedule work on that loop.
        try await Task.sleep(for: .milliseconds(50))
        if !passed { exit(1) }
    }
    static func run() async throws -> Bool {
        let bin = CommandLine.arguments[1], home = CommandLine.arguments[2], peer = CommandLine.arguments[3]
        let report = URL(fileURLWithPath: CommandLine.arguments[4])
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        var environment = ["PATH":"/usr/bin:/bin", "HOME":home, "XDG_STATE_HOME":home+"/state", "XDG_CONFIG_HOME":home+"/config",
                           "XDG_RUNTIME_DIR":home+"/runtime", "HC_SESSION":"owned", "HC_SOCKET":home+"/c.sock", "DO_NOT_TRACK":"1", "LANG":"en_US.UTF-8"]
        let localConfig = CoreProcessTransport.Configuration(executable: URL(fileURLWithPath: bin), environment: environment, directory: URL(fileURLWithPath: home))
        let controlTransport = try CoreProcessTransport(configuration: localConfig)
        let control = try CoreRPCConnection(transport: controlTransport)
        let hello = try await control.connect()
        let status: IntegrationStatus = try await control.call("server.status").result()
        try check(status.live == 0 && hello.version == "0.1.16", "fresh pinned core")
        try params(["corePID":status.pid]).write(to: report, options: .atomic)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let key = Curve25519.Signing.PrivateKey()
        // Never expose a known password on localhost: the core API has this
        // account's permissions. This per-run secret stays in memory only.
        let testPassword = UUID().uuidString + UUID().uuidString
        let pin = HostKeyFingerprint.compute(NIOSSHPrivateKey(ed25519Key: key).publicKey)
        environment["HC_SESSION"] = nil
        let configTemplate = try CoreSSHTransport.Configuration(host: "127.0.0.1", pinnedFingerprint: pin, executable: bin, session: "owned", environment: environment)
        let state = ServerState(), expected = configTemplate.command
        let execConfig = CoreProcessTransport.Configuration(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", expected], environment: ["PATH":"/usr/bin:/bin"], directory: URL(fileURLWithPath:home))
        let server = try await ServerBootstrap(group: group).serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { parent in
                guard state.add(parent) else { return parent.close() }
                let ssh = NIOSSHHandler(role: .server(SSHServerConfiguration(hostKeys: [NIOSSHPrivateKey(ed25519Key: key)], userAuthDelegate: ServerAuth(password: testPassword))), allocator: parent.allocator,
                    inboundChildChannelInitializer: { child, type in
                        guard case .session = type else { return child.eventLoop.makeFailedFuture(CoreSSHFailure.execRejected) }
                        return child.pipeline.addHandler(OwnedExec(expected: expected, config: execConfig, state: state))
                    })
                do {
                    try parent.pipeline.syncOperations.addHandlers([ssh, ServerErrorHandler()])
                    return parent.eventLoop.makeSucceededFuture(())
                } catch { return parent.eventLoop.makeFailedFuture(error) }
            }.bind(host: "127.0.0.1", port: 0).get()
        let port = server.localAddress!.port!
        func endpoint(pin: String, password: String? = nil) throws -> CoreSSHTransport {
            let password = password ?? testPassword
            let config = try CoreSSHTransport.Configuration(host: "127.0.0.1", port: port, pinnedFingerprint: pin, executable: bin, session: "owned", environment: environment)
            return CoreSSHTransport(configuration: config, authentication: { SSHAuthenticationMethod.passwordBased(username: "fixture", password: password) }, group: group)
        }
        let wrongPin = HostKeyFingerprint.compute(NIOSSHPrivateKey(ed25519Key: .init()).publicKey)
        let denied = try CoreRPCConnection(transport: endpoint(pin: wrongPin))
        do { _ = try await denied.connect(); throw IntegrationFailure.failed("wrong host key accepted") }
        catch CoreSSHFailure.hostKeyMismatch { checks += 1 }
        try await denied.close()
        try check(state.counts().0 == 0, "wrong pin blocked before exec")
        let wrongPassword = try CoreRPCConnection(transport: endpoint(pin: pin, password: "wrong"))
        do { _ = try await wrongPassword.connect(); throw IntegrationFailure.failed("wrong password accepted") }
        catch is CoreSSHFailure { checks += 1 }
        try await wrongPassword.close()
        try check(state.counts().0 == 0, "bad authentication blocked before exec")
        state.hold(true)
        let awaitingExec = try CoreRPCConnection(transport: endpoint(pin: pin))
        let connecting = Task { try await awaitingExec.connect() }
        let execDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while state.counts().0 == 0, ContinuousClock.now < execDeadline { try await Task.sleep(for: .milliseconds(5)) }
        try check(state.counts().0 == 1, "exec request reached owned server")
        connecting.cancel()
        do { _ = try await connecting.value; throw IntegrationFailure.failed("SSH connect cancellation ignored") }
        catch is CancellationError { checks += 1 }
        try await awaitingExec.close(); state.hold(false)
        let remote = try CoreRPCConnection(transport: endpoint(pin: pin))
        let remoteHello = try await remote.connect()
        try check(remoteHello.core.id == hello.core.id, "SSH reaches the requested private core")
        let subscription = try await remote.openStream("events.subscribe")
        let launched: RunTerminal = try await remote.call("terminal.run", parameters: params([
            "argv":["/usr/bin/python3", "-I", peer], "cwd":home, "keep":false,
            "env":["TERM":"xterm-256color", "TERM_PROGRAM":"3rdr", "COLORTERM":"truecolor"]])).result()
        let terminal = launched.address
        let running: IntegrationStatus = try await remote.call("server.status").result()
        let ownedPIDs = [status.pid] + running.holders.map(\.pid) + [launched.pid].compactMap { $0 }
        try params(["corePID":status.pid, "ownedPIDs":ownedPIDs]).write(to:report,options:.atomic)
        _ = try await remote.call("terminal.wait", parameters: params(["terminal":terminal, "timeout":5]))
        let stream = try await remote.openStream("terminal.attach", parameters: params([
            "terminal":terminal, "cols":90, "rows":25, "history":200,
            "display":["fg":"#123456", "bg":"#000000", "cell":[8,16]]]))
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:900,height:500), styleMask:[.titled], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        let view = View(frame: window.contentView!.bounds)
        view.bind(); window.contentView = view; _ = window.makeFirstResponder(view)
        view.getTerminal().resize(cols:90,rows:25)
        var outputFailure: (any Error)?
        var firstPaintBytes = Data()
        let output = Task { @MainActor in
            do {
                while let packet = try await stream.next() {
                    if packet.frame.kind == .data {
                        if firstPaintBytes.count < 16384 { firstPaintBytes.append(packet.frame.payload.prefix(16384 - firstPaintBytes.count)) }
                        view.feed(byteArray: Array(packet.frame.payload)[...])
                        try await stream.acknowledge(packet) // after real SwiftTerm processing
                    } else if packet.frame.kind == .close { break }
                }
            } catch { outputFailure = error }
        }
        func screen() -> String { text(of: view) }
        func waitScreen(_ text: String) async throws {
            let end = ContinuousClock.now.advanced(by:.seconds(5))
            while !screen().contains(text), ContinuousClock.now < end { try await Task.sleep(for:.milliseconds(10)) }
            if !screen().contains(text) {
                let raw: ReadTerminal? = try? await remote.call("terminal.read", parameters:params(["terminal":terminal,"lines":0])).result()
                FileHandle.standardError.write(Data(("VIEW: " + String(screen().prefix(3000)).debugDescription + "\nCORE: " + (raw?.text ?? "unreadable").debugDescription + "\nOUTPUT: " + String(describing: outputFailure) + "\n").utf8))
            }
            try check(screen().contains(text), "SwiftTerm rendered: " + text)
        }
        try await waitScreen("BOOT 한글😀")
        try await waitScreen("owned-link")
        let link = view.getTerminal().link(at: .screen(Position(col: 1, row: 1)), mode: .explicitOnly)
        if link != "https://example.invalid/owned" {
            FileHandle.standardError.write(Data(("FIRST PAINT: " + String(decoding:firstPaintBytes,as:UTF8.self).debugDescription + "\nLINK: " + String(describing:link) + "\n").utf8))
        }
        let firstPaintLinkPreserved = link == "https://example.invalid/owned"
        // Defer this known upstream failure until AFTER the remaining checks
        // and cleanup. The suite still fails; it must never count as a pass.
        try check(view.getTerminal().getCharData(col:0,row:0)?.attribute.fg != .defaultColor, "SGR foreground preserved")
        try await stream.send(Data("L".utf8))
        try await waitScreen("live-link")
        let liveRow = (0..<view.getTerminal().rows).first { row in
            view.getTerminal().getLine(row:row)?.translateToString(trimRight:true).contains("live-link") == true
        }!
        try check(view.getTerminal().link(at:.screen(Position(col:1,row:liveRow)), mode:.explicitOnly) == "https://example.invalid/live", "live OSC8 survives SSH/core/SwiftTerm")
        view.sent = Data()
        view.setMarkedText("ㅎ", selectedRange:NSRange(location:1,length:0), replacementRange:NSRange(location:NSNotFound,length:0))
        try check(view.sent.isEmpty, "IME composition sent before commit")
        view.insertText("한글😀", replacementRange:NSRange(location:NSNotFound,length:0))
        try check(view.sent == Data("한글😀".utf8), "IME commit UTF8")
        try await stream.send(view.sent)
        try await waitScreen(view.sent.map { String(format:"%02x",$0) }.joined())
        view.sent = Data()
        let ctrl = NSEvent.keyEvent(with:.keyDown, location:.zero, modifierFlags:.control, timestamp:0, windowNumber:window.windowNumber,
                                   context:nil, characters:"\u{2}", charactersIgnoringModifiers:"b", isARepeat:false, keyCode:11)!
        view.keyDown(with:ctrl)
        try check(view.sent == Data("\u{1b}[98;5u".utf8), "kitty Ctrl+B encoding")
        try await stream.send(view.sent)
        try await stream.send(Data([2,113]))
        try await waitScreen("0271")
        view.sent = Data()
        let mouse = NSEvent.mouseEvent(with:.leftMouseDown, location:NSPoint(x:100,y:200), modifierFlags:[], timestamp:0,
                                      windowNumber:window.windowNumber, context:nil, eventNumber:1, clickCount:1, pressure:1)!
        view.mouseDown(with:mouse)
        try check(String(decoding:view.sent,as:UTF8.self).contains("\u{1b}[<"), "SGR mouse input")
        try await stream.send(view.sent)
        view.getTerminal().resize(cols:91,rows:27)
        try await stream.resize(columns:91,rows:27)
        try await waitScreen("SIZE:91,27")
        try await stream.focus(true)
        try await stream.displayFacts(params(["fg":"#123456","bg":"#000000","cell":[8,16]]))
        try await stream.send(Data("Q".utf8))
        try await waitScreen("1b5d31303b7267623a")
        try await stream.send(Data("B".utf8))
        try await waitScreen("BURST-DONE") // >256 KiB: requires actual CREDIT flow
        var lines = try CoreEventLines(); var events = 0
        while events == 0 {
            guard let packet = try await subscription.next(timeout:.seconds(3)) else { break }
            try lines.receive(packet.frame.payload) { _ in events += 1 }
            try await subscription.acknowledge(packet)
        }
        try check(events > 0, "real event subscription")
        // Separate observer cannot type or resize the active viewer.
        let observe = try await remote.openStream("terminal.attach", parameters: params(["terminal":terminal,"cols":91,"rows":27,"observe":true,"resize_notifications":true]))
        try check(!observe.resizeNotifications, "0.1.16 must not advertise HEAD-only resize notifications")
        do { try await observe.send(Data([1])); throw IntegrationFailure.failed("observer input") }
        catch CoreStreamFailure.readOnly { checks += 1 }
        try await observe.close()
        try await stream.close(); output.cancel(); await output.value
        try check(outputFailure == nil || outputFailure is CancellationError, "output loop retired cleanly")
        window.close()
        try await subscription.close()
        try await remote.close()
        // Reconnect a new SSH connection; terminal survives disconnect.
        let reconnected = try CoreRPCConnection(transport:endpoint(pin:pin))
        _ = try await reconnected.connect()
        let snapshot: ReadTerminal = try await reconnected.call("terminal.read", parameters:params(["terminal":terminal,"lines":0])).result()
        try check(snapshot.text.contains("BURST-DONE"), "terminal survives SSH detach")
        let restored = try await reconnected.openStream("terminal.attach", parameters:params(["terminal":terminal,"cols":91,"rows":27,"resumed":true,"history":10]))
        let restoredView = View(frame:NSRect(x:0,y:0,width:900,height:500))
        restoredView.bind(); restoredView.getTerminal().resize(cols:91,rows:27)
        while !text(of: restoredView).contains("BURST-DONE") {
            guard let packet = try await restored.next(timeout:.seconds(3)) else { throw IntegrationFailure.failed("reattach EOF") }
            if packet.frame.kind == .data { restoredView.feed(byteArray:Array(packet.frame.payload)[...]); try await restored.acknowledge(packet) }
        }
        try check(true, "reconnected first paint reaches SwiftTerm")
        do { try await stream.send(Data([1])); throw IntegrationFailure.failed("old epoch accepted input") }
        catch CoreConnectionFailure.closed { checks += 1 }
        try await restored.close()
        _ = try await reconnected.call("terminal.kill", parameters:params(["terminal":terminal]))
        try await reconnected.close()
        let stopped: IntegrationStop = try await control.call("server.stop").result()
        try check(stopped.stopped, "owned core stop")
        try await control.close()
        try await server.close().get()
        let owned = state.owned()
        for channel in owned.0 { try? await channel.close().get() }
        for task in owned.1 { await task.value }
        try await group.shutdownGracefully()
        let counts = state.counts()
        try check(counts.0 == 3 && counts.1 == 0 && counts.2 == 0, "exec/no-PTY/owned-child cleanup")
        try params(["passed":firstPaintLinkPreserved,"corePID":status.pid,"ownedPIDs":ownedPIDs,"checks":checks,"stopAcknowledged":true,"ssh":true,"swiftTerm":true,
                    "osc8FirstPaint":firstPaintLinkPreserved,"osc8Live":true]).write(to:report,options:.atomic)
        if !firstPaintLinkPreserved {
            FileHandle.standardError.write(Data("BLOCKER SHPHRD-157: hc 0.1.16 first paint loses OSC8 hyperlink metadata; all other checks and cleanup completed\n".utf8))
            return false // Red qualification gate, never an expected-failure pass.
        }
        print("PASS real SSH + hc + SwiftTerm: \(checks) checks; only owned localhost/Unix endpoints")
        return true
    }
}
