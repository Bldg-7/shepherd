import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import Crypto
import AgentProxyProtocol

/// The forwarder: the 127.0.0.1 listener, `ap.sock` and the recorder it
/// supervises, all on one event loop.
///
/// Starting it, in order: the state folder (made or checked), the routes
/// from `routes.json`, a check that no other proxy answers on the control
/// socket, the listener on the port in `state.json` (or a new one from
/// `AgentProxyPaths.portRange`, then saved), the control socket, and the
/// recorder. The listener is bound before anything slower, so agents whose
/// requests were refused while it was down get through again within a
/// second of its start.
public final class AgentProxyServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var stateDirectory: String
        public var controlSocketPath: String
        /// The recorder's executable and arguments; nil starts none, and no
        /// copy is made.
        public var recorderCommand: [String]?
        public var build: String
        /// Lines about the proxy itself: start, status codes, error counts.
        /// Never a header, path, token or body.
        public var log: @Sendable (String) -> Void
        /// Called on the event loop when `proxy.restartWhenIdle` was asked for
        /// and no request is in flight. The executable exits; launchd starts
        /// the new one.
        public var onExitRequest: @Sendable (Int32) -> Void

        public init(stateDirectory: String, controlSocketPath: String, recorderCommand: [String]?, build: String,
                    log: @escaping @Sendable (String) -> Void, onExitRequest: @escaping @Sendable (Int32) -> Void) {
            self.stateDirectory = stateDirectory; self.controlSocketPath = controlSocketPath
            self.recorderCommand = recorderCommand; self.build = build; self.log = log; self.onExitRequest = onExitRequest
        }
    }

    /// How long a saved port that is still taken (by a proxy that is just
    /// exiting) is tried before another is picked.
    static let savedPortPatience: TimeInterval = 3

    private let configuration: Configuration
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let loop: EventLoop
    private let trustRoots: NIOSSLTrustRoots
    private let addressing: UpstreamPool.Addressing
    private let timing: UpstreamPool.Timing
    private var core: ProxyCore?
    private var listener: Channel?
    private var control: Channel?
    private var recorder: RecorderSupervisor?
    private var stopped = false

    public private(set) var port = 0

    public convenience init(configuration: Configuration) {
        self.init(configuration: configuration, trustRoots: .default, addressing: .production, timing: .init())
    }

    /// Tests only: every upstream at an address of the test's and verified
    /// against the test's own roots instead of the system's, with shorter
    /// waits. The executable never calls it.
    @_spi(Testing)
    public convenience init(configuration: Configuration, testUpstreams: [AgentProxyUpstream: SocketAddress],
                            trustRoots: [NIOSSLCertificate], connectTimeout: TimeAmount = .seconds(10),
                            idleTimeout: TimeAmount = .seconds(30)) {
        self.init(configuration: configuration, trustRoots: .certificates(trustRoots), addressing: .fixed(testUpstreams),
                  timing: .init(connect: connectTimeout, idle: idleTimeout))
    }

    private init(configuration: Configuration, trustRoots: NIOSSLTrustRoots, addressing: UpstreamPool.Addressing, timing: UpstreamPool.Timing) {
        self.configuration = configuration
        self.trustRoots = trustRoots; self.addressing = addressing; self.timing = timing
        loop = group.next()
    }

    /// The SHA-256 of an executable, as `proxy.status` reports it: what the
    /// app compares with the proxy in its own bundle.
    public static func build(ofExecutableAt path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "unknown" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the port.
    @discardableResult
    public func start() throws -> Int {
        let log = configuration.log
        let directory = try StateDirectory.prepare(configuration.stateDirectory)
        try StateDirectory.prepareSocketFolder(for: configuration.controlSocketPath)
        try ControlServer.clear(configuration.controlSocketPath)
        let pool = try loop.submit { [self] in try UpstreamPool(loop: loop, trustRoots: trustRoots, addressing: addressing, timing: timing) }.wait()
        let core = try loop.submit { [self] in
            ProxyCore(loop: loop, routes: RouteTable(directory: directory, log: log), pool: pool, build: configuration.build,
                      log: log, onExitRequest: configuration.onExitRequest)
        }.wait()
        self.core = core

        let saved = (try? directory.read("state.json")).flatMap { $0 }.flatMap { try? JSONDecoder().decode(ProxyState.self, from: $0) }
        let (listener, port) = try bindListener(core: core, saved: saved?.port)
        self.listener = listener
        self.port = port
        try loop.submit { core.port = port }.wait()
        if saved?.port != port {
            try directory.write("state.json", AgentProxyControl.encoder.encode(ProxyState(port: port)))
        }
        log("listening on 127.0.0.1:\(port)")

        do {
            control = try ControlServer.bind(configuration.controlSocketPath, core: core, group: group)
        } catch {
            listener.close(promise: nil)
            throw error
        }

        if let command = configuration.recorderCommand, !command.isEmpty {
            let recorder = RecorderSupervisor(command: command, loop: loop, tee: core.tee, routes: core.routes, log: log)
            self.recorder = recorder
            try loop.submit {
                core.recorder = recorder
                core.routes.onAuthorityChanged = { [weak recorder] in recorder?.authorityChanged() }
                recorder.start()
            }.wait()
        }
        return port
    }

    private func bindListener(core: ProxyCore, saved: Int?) throws -> (Channel, Int) {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 64 << 10, high: 256 << 10))
            .childChannelInitializer { channel in
                guard core.connectionOpened(channel) else { return channel.close() }
                return channel.eventLoop.makeCompletedFuture {
                    var noFraming = HTTPResponseEncoder.Configuration()
                    noFraming.automaticallySetFramingHeaders = false
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false,
                                                                                    withServerUpgrade: nil,
                                                                                    withErrorHandling: false,
                                                                                    withOutboundHeaderValidation: true,
                                                                                    withEncoderConfiguration: noFraming)
                    try channel.pipeline.syncOperations.addHandler(DownstreamHandler(core: core))
                }
            }
        func bind(_ port: Int) -> Channel? {
            guard let address = try? SocketAddress(ipAddress: "127.0.0.1", port: port) else { return nil }
            return try? bootstrap.bind(to: address).wait()
        }
        if let saved, AgentProxyPaths.portRange.contains(saved) {
            let deadline = Date().addingTimeInterval(Self.savedPortPatience)
            repeat {
                if let channel = bind(saved) { return (channel, saved) }
                usleep(100_000)
            } while Date() < deadline
            configuration.log("port \(saved) is taken; picking another")
        }
        for _ in 0..<64 {
            let port = Int.random(in: AgentProxyPaths.portRange)
            if let channel = bind(port) { return (channel, port) }
        }
        throw AgentProxyStartError.noPort
    }

    /// Closes the listener and the control socket, stops the recorder and
    /// the event loop. Not to be called on the event loop.
    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        recorder?.stop()
        if let core { try? loop.submit { core.pool.closeAll() }.wait() }
        listener?.close(promise: nil)
        if let control {
            control.close(promise: nil)
            unlink(configuration.controlSocketPath)
        }
        try? group.syncShutdownGracefully()
    }
}

/// What the handlers share. Used on the proxy's event loop only.
final class ProxyCore: @unchecked Sendable {
    static let maximumConnections = 256

    let loop: EventLoop
    let routes: RouteTable
    let pool: UpstreamPool
    let tee = Tee()
    let build: String
    let log: @Sendable (String) -> Void
    private let onExitRequest: @Sendable (Int32) -> Void
    var recorder: RecorderSupervisor?
    var port = 0
    private var exchangeIDs: UInt64 = 0
    private var inFlight = 0
    private var draining = false
    private var exiting = false
    private var connections = 0
    private var exchanges = 0
    private var rejectedCount = 0
    private var upstreamFailures = 0

    init(loop: EventLoop, routes: RouteTable, pool: UpstreamPool, build: String,
         log: @escaping @Sendable (String) -> Void, onExitRequest: @escaping @Sendable (Int32) -> Void) {
        self.loop = loop; self.routes = routes; self.pool = pool; self.build = build
        self.log = log; self.onExitRequest = onExitRequest
    }

    func nextExchangeID() -> UInt64 {
        exchangeIDs += 1
        return exchangeIDs
    }

    func connectionOpened(_ channel: Channel) -> Bool {
        guard connections < Self.maximumConnections else { return false }
        connections += 1
        channel.closeFuture.whenComplete { [self] _ in connections -= 1 }
        return true
    }

    func began(routeID: String?) {
        inFlight += 1
        exchanges += 1
        if let routeID { routes.began(routeID: routeID) }
    }

    func ended(routeID: String?, status: UInt?, upstream: AgentProxyUpstream) {
        inFlight -= 1
        if let routeID { routes.ended(routeID: routeID) }
        log(status.map { "exchange: \(upstream.rawValue) \($0)" } ?? "exchange: \(upstream.rawValue) cut off")
        exitIfIdle()
    }

    func rejected(status: HTTPResponseStatus, reason: String) {
        rejectedCount += 1
        log("rejected: \(status.code) \(reason)")
    }

    func upstreamFailed() { upstreamFailures += 1 }

    func restartWhenIdle() -> AgentProxyRestartWhenIdle {
        if !draining { log("restart when idle: \(inFlight) in flight") }
        draining = true
        return AgentProxyRestartWhenIdle(accepted: true, inFlight: inFlight)
    }

    func exitIfIdle() {
        guard draining, inFlight == 0, !exiting else { return }
        exiting = true
        log("idle; exiting for a restart")
        onExitRequest(0)
    }

    func status() -> AgentProxyStatus {
        let recorderStatus = recorder.map {
            AgentProxyStatus.Recorder(state: $0.state, pid: $0.currentPID, restarts: $0.restarts)
        } ?? AgentProxyStatus.Recorder(state: .stopped, pid: nil, restarts: 0)
        return AgentProxyStatus(protocolVersion: AgentProxyControl.protocolVersion, build: build, port: port,
                                state: draining ? .draining : .running, routeCount: routes.count, inFlight: inFlight,
                                recorder: recorderStatus,
                                counters: .init(exchanges: exchanges, rejected: rejectedCount,
                                                upstreamFailures: upstreamFailures, recorderDropped: tee.dropped))
    }
}
