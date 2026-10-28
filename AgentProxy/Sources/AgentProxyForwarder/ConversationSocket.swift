import Foundation
import Darwin
import NIOCore
import NIOPosix
import AgentProxyCore
import AgentProxyProtocol

/// One event loop owns tee ingestion, history and all read clients. The parent
/// forwarder never waits for this process. No raw request/error/transcript logs.
enum ConversationSocket {
    static func run(descriptor: Int32, path: String, stateDirectory: String? = nil, inheritedProducerDescriptor: Int32? = nil) -> Int32 {
        let producer: ConversationProducerLease?
        if let stateDirectory {
            do {
                producer = try ConversationProducerLease(rootPath: stateDirectory, inheritedDescriptor: inheritedProducerDescriptor)
                if let inheritedProducerDescriptor { Darwin.close(inheritedProducerDescriptor) }
            } catch { return 4 }
        } else {
            guard inheritedProducerDescriptor == nil else { return 4 }
            producer = nil
        }
        let lease: SocketLease
        do { lease = try SocketLease(path) } catch { return 4 }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = ReadState(loop: group.next(), stateDirectory: stateDirectory, producerLease: producer)
        var listener: Channel?
        var tee: Channel?
        defer {
            let flush = try? state.loop.submit { state.stop() }.wait()
            if let flush { _ = flush.wait(timeout: .now() + .seconds(1)) }
            try? listener?.close().wait()
            try? tee?.close().wait()
            try? group.syncShutdownGracefully()
            lease.cleanup()
        }
        do {
            // NIO-created Unix listeners unconditionally unlink their pathname
            // on close. Adopt our bound descriptor instead, so only the lease's
            // inode-checked cleanup can remove a socket.
            let boundDescriptor = try lease.bindDescriptor()
            listener = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 64 << 10))
                .childChannelOption(ChannelOptions.writeBufferWaterMark, value: WriteBufferWaterMark(low: 64 << 10, high: 2 << 20))
                .childChannelInitializer { channel in state.add(channel) }
                .withBoundSocket(boundDescriptor).wait()
            tee = try ClientBootstrap(group: group)
                .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 64 << 10))
                .channelInitializer { channel in channel.pipeline.addHandler(TeeInput(state)) }
                .withConnectedSocket(descriptor).wait()
            try state.loop.submit { state.start() }.wait()
            try tee!.closeFuture.wait()
            return try state.loop.submit { state.exitCode }.wait()
        } catch { return 4 }
    }
}

/// A private lock prevents two cooperating recorders from unlinking each
/// other's listener. Never unlink a file/symlink, an active socket or a path
/// whose inode changed after bind. Only an empty coordination file persists.
final class SocketLease {
    let path: String
    private let lock: Int32
    private var inode: ino_t?
    private var device: dev_t?
    init(_ path: String, removeStale: Bool = true) throws {
        guard AgentProxyPaths.socketPathFits(path) else { throw UnsafePath() }
        try StateDirectory.prepareSocketFolder(for: path)
        let folder = (path as NSString).deletingLastPathComponent
        // This is our app's own support folder, not Library/Application Support
        // or an arbitrary caller's home/tmp folder. Custom paths must already
        // use a private folder; never chmod those on the caller's behalf.
        if (folder as NSString).lastPathComponent == AgentProxyPaths.applicationFolder {
            _ = try StateDirectory.prepare(folder)
        }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw UnsafePath() }
        let fd = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw UnsafePath() }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw UnsafePath()
        }
        if removeStale {
            do { try Self.clearStale(path) } catch { Darwin.close(fd); throw error }
        }
        do { try Self.verifyLock(path: path, descriptor: fd) } catch { Darwin.close(fd); throw error }
        self.path = path; lock = fd
    }
    deinit { Darwin.close(lock) }
    func verifyLock() throws { try Self.verifyLock(path: path, descriptor: lock) }
    private static func verifyLock(path: String, descriptor: Int32) throws {
        var opened = stat(), current = stat()
        guard fstat(descriptor, &opened) == 0, lstat(path + ".lock", &current) == 0,
              opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == getuid(), opened.st_mode & 0o777 == 0o600,
              opened.st_nlink == 1, current.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { throw UnsafePath() }
    }
    func bindDescriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnsafePath() }
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw UnsafePath() }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for (i, byte) in path.utf8.enumerated() { bytes[i] = byte }
                bytes[path.utf8.count] = 0
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw UnsafePath() }
            try bound()
            guard listen(fd, 16) == 0 else { throw UnsafePath() }
            return fd // ownership transfers to NIO, including close on failure
        } catch { Darwin.close(fd); throw error }
    }
    private func bound() throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw UnsafePath() }
        inode = info.st_ino; device = info.st_dev
        guard chmod(path, 0o600) == 0 else { throw UnsafePath() }
    }
    func cleanup() {
        var info = stat()
        if let inode, let device, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
           info.st_uid == getuid(), info.st_ino == inode, info.st_dev == device { unlink(path) }
    }
    private static func clearStale(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { if errno == ENOENT { return }; throw UnsafePath() }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw UnsafePath() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnsafePath() }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UnsafePath() }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (i, byte) in path.utf8.enumerated() { bytes[i] = byte }
            bytes[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // In-progress/backlog-full/permission failures are NOT stale evidence.
        guard result < 0, errno == ECONNREFUSED else { throw UnsafePath() }
        var current = stat()
        guard lstat(path, &current) == 0, current.st_ino == info.st_ino, current.st_dev == info.st_dev,
              current.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else { throw UnsafePath() }
    }
    struct UnsafePath: Error {}
}

private final class ReadState: @unchecked Sendable {
    let loop: EventLoop
    let capture = ConversationCapture(makeDecoder: AgentProxyBodyDecoder.make)
    var exitCode: Int32 = 0
    var clients: [ObjectIdentifier: ReadClient] = [:]
    private var ticker: RepeatedTask?
    private var authorityGeneration: UInt64 = 0
    private var authority: [Data: AgentProxyRouteCreate] = [:]
    // Two tokens cover the retained table and one replacement. They remain
    // reserved even while no replacement is active, so ordinary work cannot
    // consume authority headroom. This is accounting, not an RSS guarantee.
    private var authorityReservation: UUID?
    private var authorityReplacementReservation: UUID?
    // 1,024 routes with five <=256-byte strings, dictionary keys and one
    // bounded decoded frame fit the conservative admission workspace; the
    // independent fixed capture budget covers tee framing and decoder bytes.
    static let authorityWorkspaceBytes = 8 << 20
    var authorityAwaitingCapacity = false
    var authorityAssemblyBytes = 0
    private let producerLease: ConversationProducerLease?
    private var persistence: ConversationPersistenceCoordinator?
    private struct ScheduledRevision { let revision: UInt64; let token: UUID }
    private var scheduledRevisions: [String: ScheduledRevision] = [:]
    private var persistentIDs: [ConversationKey: String] = [:]
    private var blockedPersistence: Set<ConversationKey> = []
    private var historicalConflicts: Set<ConversationKey> = []
    private var retryTicks = 0
    private var retryRunning = false
    private var retryCursor: String?
    init(loop: EventLoop, stateDirectory: String?, producerLease: ConversationProducerLease?) {
        self.loop = loop
        self.producerLease = producerLease
        guard let current = capture.reserve(bytes: Self.authorityWorkspaceBytes),
              let replacement = capture.reserve(bytes: Self.authorityWorkspaceBytes) else {
            preconditionFailure("recorder authority headroom unavailable at initialization")
        }
        authorityReservation = current
        authorityReplacementReservation = replacement
        if let stateDirectory {
            guard let producerLease else { preconditionFailure("persistent recorder requires producer admission") }
            persistence = ConversationPersistenceCoordinator(root: stateDirectory, loop: loop, capture: capture, producerLease: producerLease)
            capture.onMainAdmission = { [weak self] owner, current, live, resume, cancel in
                self?.beginRestore(owner, current: current, live: live, resume: resume, cancel: cancel) ?? false
            }
        }
    }

    func producerIsValid() -> Bool {
        guard let producerLease else { return persistence == nil }
        do { try producerLease.verify(); return true } catch { return false }
    }

    private func authorized(_ owner: ConversationOwner) -> Bool {
        guard let route = authority[Data(owner.context.routeID.utf8)] else { return false }
        return Data(route.kind.rawValue.utf8) == Data(owner.key.agent.utf8)
            && Data(route.session.utf8) == Data(owner.key.herdrSession.utf8)
            && Data(route.paneID.utf8) == Data(owner.context.paneID.utf8)
            && Data(route.terminalID.utf8) == Data(owner.context.terminalID.utf8)
    }

    private func beginRestore(_ owner: ConversationOwner, current: @escaping () -> Bool, live: @escaping () -> Bool,
                              resume: @escaping () -> Void, cancel: @escaping () -> Void) -> Bool {
        guard let persistence, authorized(owner), authorityGeneration != 0 else { return false }
        let key = owner.key
        if persistentIDs[key] != nil || capture.reconciler.store.read(key: key) != nil { return false }
        blockedPersistence.insert(key)
        let captureEpoch = capture.reconciler.store.epoch
        let diskKey = ConversationStore.PersistentSnapshot.Key(agent: key.agent, herdrSession: key.herdrSession, nativeSession: key.nativeSession)
        let admitted = persistence.loadFirst(diskKey) { [weak self] result in
            guard let self else { return }
            let awaiting = current()
            guard (awaiting || live()), self.producerIsValid(), self.capture.reconciler.store.epoch == captureEpoch,
                  self.authorized(owner) else { cancel(); return }
            switch result {
            case .failure:
                self.blockedPersistence.insert(key)
                resume()
            case .success(let loaded):
                if let loaded {
                    // A live request won the race. Never replace its state or
                    // overwrite the historical disk body with an unmerged view.
                    guard awaiting else { self.blockedPersistence.insert(key); self.historicalConflicts.insert(key); return }
                    let diskID = loaded.id
                    guard !self.persistentIDs.contains(where: { $0.key != key && Data($0.value.utf8) == Data(diskID.utf8) }) else {
                        self.blockedPersistence.insert(key); cancel(); return
                    }
                    let r = loaded
                    let adjusted = ConversationStore.PersistentSnapshot.Record(id: r.id, key: r.key,
                        context: .init(routeID: owner.context.routeID, paneID: owner.context.paneID, terminalID: owner.context.terminalID),
                        updatedOrder: r.updatedOrder, items: r.items, truncated: r.truncated, status: r.status, subagents: r.subagents)
                    guard self.capture.restoreOne(adjusted) != nil else {
                        // Preserve the historical body and the newly admitted
                        // live exchange when import cannot fit without eviction.
                        self.blockedPersistence.insert(key)
                        self.historicalConflicts.insert(key)
                        resume()
                        self.scheduleChangedRecords()
                        return
                    }
                    self.persistentIDs[key] = diskID
                }
                resume()
                if self.persistentIDs[key] == nil, let live = self.capture.reconciler.store.read(key: key) {
                    self.persistentIDs[key] = live.summary.id
                }
                if self.persistentIDs[key] != nil { self.blockedPersistence.remove(key) }
            }
            self.scheduleChangedRecords()
        }
        if !admitted { blockedPersistence.insert(key) }
        return admitted
    }

    struct PersistenceStatus: Encodable {
        let mode: String
        let blockedConversations: Int
        let historicalConflicts: Int
        let authorityRetainedBytes: Int
        let captureReservedBytes: Int
        let authorityAwaitingCapacity: Bool
        let authorityAssemblyBytes: Int
        let admittedClients: Int
        let activeExchanges: Int
        let statusWorkspaceDeferrals: Int
    }

    func persistenceStatus() -> PersistenceStatus {
        let mode: String
        if let persistence {
            switch persistence.health {
            case .volatile: mode = "volatile"
            case .healthy: mode = "healthy"
            case .degraded: mode = "degraded"
            }
        } else { mode = "off" }
        return PersistenceStatus(mode: mode, blockedConversations: blockedPersistence.count,
                                 historicalConflicts: historicalConflicts.count,
                                 authorityRetainedBytes: authorityReservation == nil ? 0 : Self.authorityWorkspaceBytes,
                                 captureReservedBytes: capture.reservedBytes,
                                 authorityAwaitingCapacity: authorityAwaitingCapacity,
                                 authorityAssemblyBytes: authorityAssemblyBytes,
                                 admittedClients: clients.count,
                                 activeExchanges: capture.activeExchangeCount,
                                 statusWorkspaceDeferrals: persistence?.statusWorkspaceDeferrals ?? 0)
    }

    /// Retry one blocked live key per interval. Only a no-record result can
    /// unblock a live entry: an existing historical body must remain untouched.
    private func retryBlockedPersistence() {
        guard !retryRunning, let persistence, authorityGeneration != 0 else { return }
        let candidates = capture.reconciler.store.list().filter {
            blockedPersistence.contains($0.key) && !historicalConflicts.contains($0.key)
        }.sorted { $0.id < $1.id }
        guard let summary = candidates.first(where: { retryCursor == nil || $0.id > retryCursor! }) ?? candidates.first else { return }
        retryCursor = summary.id
        guard let owner = capture.reconciler.currentOwner(conversationID: summary.id), authorized(owner) else { return }
        let key = summary.key, liveID = summary.id, captureEpoch = capture.reconciler.store.epoch
        let diskKey = ConversationStore.PersistentSnapshot.Key(agent: key.agent, herdrSession: key.herdrSession, nativeSession: key.nativeSession)
        retryRunning = true
        let admitted = persistence.loadFirst(diskKey) { [weak self] result in
            guard let self else { return }
            self.retryRunning = false
            guard self.producerIsValid(), self.capture.reconciler.store.epoch == captureEpoch, self.authorized(owner),
                  self.blockedPersistence.contains(key),
                  self.capture.reconciler.ownsConversation(owner, conversationID: liveID),
                  self.capture.reconciler.store.read(key: key)?.summary.id == liveID else { return }
            switch result {
            case .failure: return
            case .success(.some): self.historicalConflicts.insert(key)
            case .success(.none):
                self.persistentIDs[key] = liveID
                self.blockedPersistence.remove(key)
                self.scheduleChangedRecords()
            }
        }
        if !admitted { retryRunning = false }
    }

    /// Called after an accepted frame changes the normalized store. Never
    /// passes wire bytes or request metadata to the filesystem worker.
    func scheduleChangedRecords() {
        guard let persistence, authorityGeneration != 0 else { return }
        let summaries = capture.reconciler.store.list()
        let live = Set(summaries.map(\.id))
        scheduledRevisions = scheduledRevisions.filter { live.contains($0.key) }
        let liveKeys = Set(summaries.map(\.key))
        persistentIDs = persistentIDs.filter { liveKeys.contains($0.key) }
        blockedPersistence = blockedPersistence.filter { liveKeys.contains($0) }
        historicalConflicts = historicalConflicts.filter { liveKeys.contains($0) }
        for summary in summaries where persistentIDs[summary.key] == nil { blockedPersistence.insert(summary.key) }
        for summary in summaries where scheduledRevisions[summary.id]?.revision != summary.revision {
            guard !blockedPersistence.contains(summary.key), let persistentID = persistentIDs[summary.key], let route = authority[Data(summary.context.routeID.utf8)],
                  Data(route.session.utf8) == Data(summary.key.herdrSession.utf8),
                  route.kind.rawValue == summary.key.agent,
                  Data(route.paneID.utf8) == Data(summary.context.paneID.utf8),
                  Data(route.terminalID.utf8) == Data(summary.context.terminalID.utf8),
                  let record = capture.reconciler.store.persistenceRecord(id: summary.id) else { continue }
            let mapped = ConversationStore.PersistentSnapshot.Record(id: persistentID, key: record.key, context: record.context,
                updatedOrder: record.updatedOrder, items: record.items, truncated: record.truncated, status: record.status, subagents: record.subagents)
            let token = UUID()
            if persistence.schedule(mapped, completion: { [weak self] success in
                guard let self, !success, self.scheduledRevisions[summary.id]?.token == token else { return }
                self.scheduledRevisions.removeValue(forKey: summary.id)
            }) {
                scheduledRevisions[summary.id] = ScheduledRevision(revision: summary.revision, token: token)
            }
        }
    }

    private func same(_ a: AgentProxyRouteCreate, _ b: AgentProxyRouteCreate) -> Bool {
        a.kind == b.kind && zip([a.session, a.paneID, a.terminalID, a.cliVersion],
                                [b.session, b.paneID, b.terminalID, b.cliVersion])
            .allSatisfy { Data($0.0.utf8) == Data($0.1.utf8) }
    }

    /// Authority arrives only on the inherited supervisor stream. The input
    /// stream's order fences old tee frames before each replacement snapshot.
    func reserveAuthority() -> UUID? {
        let reservation = authorityReplacementReservation
        authorityReplacementReservation = nil
        return reservation
    }

    func acceptAuthority(_ frame: AgentProxyTeeFrame.Frame, reservation: UUID) -> UInt64? {
        guard frame.exchange == 0,
              let snapshot = try? JSONDecoder().decode(AgentProxyTeeFrame.RouteSnapshot.self, from: Data(frame.payload)) else { return nil }
        return acceptAuthority(snapshot, reservation: reservation)
    }

    static func validAuthorityRoute(_ route: AgentProxyTeeFrame.RouteSnapshot.Route) -> Bool {
        let fields = [route.routeID, route.identity.session, route.identity.paneID,
                      route.identity.terminalID, route.identity.cliVersion]
        return !route.routeID.isEmpty && fields.allSatisfy {
            $0.utf8.count <= AgentProxyControl.maximumFieldBytes &&
            !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }

    /// The caller owns the new reservation until this returns a generation;
    /// then the state owns it, replacing the old reservation only after all
    /// validation and construction succeed.
    func acceptAuthority(_ snapshot: AgentProxyTeeFrame.RouteSnapshot, reservation: UUID) -> UInt64? {
        guard snapshot.generation > authorityGeneration, snapshot.routes.count <= 1024 else { return nil }
        var next: [Data: AgentProxyRouteCreate] = [:]
        for route in snapshot.routes {
            guard Self.validAuthorityRoute(route) else { return nil }
            let key = Data(route.routeID.utf8)
            guard next[key] == nil else { return nil }
            next[key] = route.identity
        }
        let revoked = authority.contains { key, old in
            guard let current = next[key] else { return true }
            return !same(old, current)
        }
        if revoked {
            // Coarse but fail-closed: no in-flight ticket or read subscriber
            // survives an authority change that removes or rotates a route.
            capture.invalidateForClear()
            persistentIDs.removeAll()
            blockedPersistence.removeAll()
            historicalConflicts.removeAll()
            for client in Array(clients.values) { client.channel.close(promise: nil) }
        }
        // The persistence fence discards queued snapshots for every generation.
        scheduledRevisions.removeAll()
        authority = next
        let previousReservation = authorityReservation
        authorityReservation = reservation
        authorityReplacementReservation = previousReservation
        authorityGeneration = snapshot.generation
        return snapshot.generation
    }

    var hasPersistentProducer: Bool { producerLease != nil }

    func acceptClear(_ frame: AgentProxyTeeFrame.Frame) -> Bool {
        guard producerLease != nil, producerIsValid(), frame.payload.isEmpty, frame.exchange > authorityGeneration else { return false }
        authorityGeneration = frame.exchange
        capture.invalidateForClear()
        scheduledRevisions.removeAll(); persistentIDs.removeAll(); blockedPersistence.removeAll(); historicalConflicts.removeAll()
        for client in Array(clients.values) { client.channel.close(promise: nil) }
        return true
    }

    func clearPersistence(_ completion: @escaping (ConversationPersistenceCoordinator.ClearOutcome) -> Void) {
        guard let persistence else { loop.execute { completion(.unavailable) }; return }
        persistence.clearHistory(completion)
    }

    func fencePersistence(_ completion: @escaping () -> Void) {
        if let persistence { persistence.fence(completion) }
        else { loop.execute(completion) }
    }

    func pausePersistenceForAuthority(_ completion: @escaping () -> Void) {
        if let persistence { persistence.pauseForAuthority(completion) }
        else { loop.execute(completion) }
    }

    func resumePersistenceAfterAuthority() { persistence?.resumeAfterAuthority() }

    func acceptOpen(_ frame: AgentProxyTeeFrame.Frame) -> Bool {
        guard authorityGeneration != 0,
              let open = try? JSONDecoder().decode(AgentProxyTeeFrame.Open.self, from: Data(frame.payload)),
              let identity = open.routeIdentity,
              let current = authority[Data(open.routeID.utf8)] else { return false }
        return same(identity, current)
    }
    func start() {
        loop.assertInEventLoop()
        ticker = loop.scheduleRepeatedTask(initialDelay: .milliseconds(100), delay: .milliseconds(100)) { [weak self] _ in
            guard let self else { return }
            guard self.producerIsValid() else {
                self.exitCode = 3
                self.capture.invalidateForClear()
                for client in Array(self.clients.values) { client.channel.close(promise: nil) }
                return
            }
            for client in Array(self.clients.values) { client.tick() }
            self.retryTicks += 1
            if self.retryTicks >= 20 {
                self.retryTicks = 0
                self.retryBlockedPersistence()
                self.scheduleChangedRecords()
                self.persistence?.refreshStatus()
            }
        }
    }
    func add(_ channel: Channel) -> EventLoopFuture<Void> {
        loop.assertInEventLoop()
        guard producerIsValid(), clients.count < 16, let reservation = capture.reserve(bytes: 4 << 20) else { return channel.close() }
        let key = ObjectIdentifier(channel)
        let client = ReadClient(state: self, channel: channel)
        clients[key] = client
        channel.closeFuture.whenComplete { _ in
            self.clients.removeValue(forKey: key)
            self.capture.release(reservation)
        }
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(ReadLine()))
            try channel.pipeline.syncOperations.addHandler(client)
        }
    }
    func protocolFailure() {
        loop.assertInEventLoop()
        exitCode = 3
        capture.invalidateForClear()
        scheduledRevisions.removeAll()
        for client in Array(clients.values) { client.channel.close(promise: nil) }
        authority.removeAll()
        if let reservation = authorityReservation { capture.release(reservation); authorityReservation = nil }
        if let reservation = authorityReplacementReservation { capture.release(reservation); authorityReplacementReservation = nil }
        persistence?.fence({})
        persistence?.resumeAfterAuthority()
    }

    func stop() -> DispatchSemaphore? {
        loop.assertInEventLoop(); ticker?.cancel(); ticker = nil
        capture.finishAll(); scheduleChangedRecords()
        authority.removeAll()
        if let reservation = authorityReservation { capture.release(reservation); authorityReservation = nil }
        if let reservation = authorityReplacementReservation { capture.release(reservation); authorityReplacementReservation = nil }
        for client in Array(clients.values) { client.channel.close(promise: nil) }
        return persistence?.finishWhenIdle()
    }
}

private final class TeeInput: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let state: ReadState
    var decoder = AgentProxyTeeFrame.Decoder()
    private struct PartialAuthority {
        let generation: UInt64
        let count: Int
        var routes: [AgentProxyTeeFrame.RouteSnapshot.Route]
        var nextIndex: Int
        var encodedBytes: Int
        let reservation: UUID
    }
    private var partialAuthority: PartialAuthority?
    // At most one already-framed snapshot waits for replacement workspace;
    // frame/decoder bytes are covered by capture's fixed framing budget.
    private var deferredFrame: AgentProxyTeeFrame.Frame?
    private var deferredReservation: UUID?
    private var deferredRetry: Scheduled<Void>?
    private var fencing = false
    init(_ state: ReadState) { self.state = state }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard state.producerIsValid() else { state.exitCode = 3; context.close(promise: nil); return }
        decoder.append(unwrapInboundIn(data).readableBytesView)
        // One maximum frame plus one fixed-size socket read. This covers a
        // deferred frame and pipelined bytes without unbounded framing storage.
        guard decoder.bufferedByteCount <= AgentProxyTeeFrame.maximumPayloadBytes + AgentProxyTeeFrame.headerBytes + (64 << 10) else {
            state.exitCode = 3; context.close(promise: nil); return
        }
        process(context: context)
    }
    private func deferAuthority(_ frame: AgentProxyTeeFrame.Frame, context: ChannelHandlerContext) {
        guard deferredFrame == nil, let options = context.channel.syncOptions else {
            state.exitCode = 3; context.close(promise: nil); return
        }
        do { try options.setOption(ChannelOptions.autoRead, value: false) }
        catch { state.exitCode = 3; context.close(promise: nil); return }
        deferredFrame = frame
        state.authorityAwaitingCapacity = true
        fencing = true
        state.pausePersistenceForAuthority { [self] in retryDeferred(context: context) }
    }

    private func retryDeferred(context: ChannelHandlerContext) {
        guard context.channel.isActive, deferredFrame != nil else { return }
        if let reservation = state.reserveAuthority() {
            deferredReservation = reservation
            state.authorityAwaitingCapacity = false
            fencing = false
            process(context: context)
            if !fencing {
                guard let options = context.channel.syncOptions else { state.exitCode = 3; context.close(promise: nil); return }
                do { try options.setOption(ChannelOptions.autoRead, value: true) }
                catch { state.exitCode = 3; context.close(promise: nil) }
            }
        } else {
            deferredRetry = context.eventLoop.scheduleTask(in: .milliseconds(100)) { [self] in
                deferredRetry = nil
                retryDeferred(context: context)
            }
        }
    }

    private func process(context: ChannelHandlerContext) {
        guard !fencing else { return }
        do {
            while true {
                let frame: AgentProxyTeeFrame.Frame
                if let deferredFrame { frame = deferredFrame; self.deferredFrame = nil }
                else if let next = try decoder.next() { frame = next }
                else { break }
                // ACKs are only valid in the recorder-to-supervisor direction.
                guard frame.kind != .routeAcknowledgement && frame.kind != .clearFailure else { state.exitCode = 3; context.close(promise: nil); return }
                if partialAuthority != nil && frame.kind != .routeSnapshotPart {
                    state.exitCode = 3; context.close(promise: nil); return
                }
                if frame.kind == .clearHistory {
                    if !state.hasPersistentProducer {
                        guard frame.exchange > 0, frame.payload.isEmpty,
                              let payload = try? JSONEncoder().encode(AgentProxyTeeFrame.ClearFailure(outcome: .unavailable)) else { state.exitCode = 3; context.close(promise: nil); return }
                        let header = AgentProxyTeeFrame.header(kind: .clearFailure, exchange: frame.exchange, payloadCount: payload.count)
                        context.channel.write(ByteBuffer(bytes: header), promise: nil)
                        context.channel.writeAndFlush(ByteBuffer(bytes: payload)).whenFailure { _ in context.close(promise: nil) }
                        continue
                    }
                    guard state.acceptClear(frame), let options = context.channel.syncOptions else { state.exitCode = 3; context.close(promise: nil); return }
                    fencing = true
                    do { try options.setOption(ChannelOptions.autoRead, value: false) }
                    catch { state.exitCode = 3; context.close(promise: nil); return }
                    state.clearPersistence { [self] outcome in
                        guard context.channel.isActive else { return }
                        guard state.producerIsValid() else { state.exitCode = 3; context.close(promise: nil); return }
                        let kind: AgentProxyTeeFrame.Kind
                        let payload: Data
                        switch outcome {
                        case .cleared: kind = .routeAcknowledgement; payload = Data()
                        case .unavailable, .partial:
                            kind = .clearFailure
                            let reason: AgentProxyTeeFrame.ClearFailure.Outcome = outcome == .partial ? .partial : .unavailable
                            guard let encoded = try? JSONEncoder().encode(AgentProxyTeeFrame.ClearFailure(outcome: reason)) else { context.close(promise: nil); return }
                            payload = encoded
                        }
                        let header = AgentProxyTeeFrame.header(kind: kind, exchange: frame.exchange, payloadCount: payload.count)
                        context.channel.write(ByteBuffer(bytes: header), promise: nil)
                        context.channel.writeAndFlush(ByteBuffer(bytes: payload)).whenFailure { _ in context.close(promise: nil) }
                        state.resumePersistenceAfterAuthority()
                        fencing = false; process(context: context)
                        if !fencing {
                            guard let options = context.channel.syncOptions else { state.exitCode = 3; context.close(promise: nil); return }
                            do { try options.setOption(ChannelOptions.autoRead, value: true) }
                            catch { state.exitCode = 3; context.close(promise: nil) }
                        }
                    }
                    return
                } else if frame.kind == .routeSnapshot || frame.kind == .routeSnapshotPart {
                    let generation: UInt64?
                    if frame.kind == .routeSnapshot {
                        guard let reservation = deferredReservation ?? state.reserveAuthority() else { deferAuthority(frame, context: context); return }
                        deferredReservation = nil
                        generation = state.acceptAuthority(frame, reservation: reservation)
                        if generation == nil { state.capture.release(reservation) }
                    } else {
                        var acquired: UUID?
                        if partialAuthority == nil {
                            guard let reservation = deferredReservation ?? state.reserveAuthority() else { deferAuthority(frame, context: context); return }
                            deferredReservation = nil
                            acquired = reservation
                        }
                        guard frame.exchange == 0,
                              let part = try? JSONDecoder().decode(AgentProxyTeeFrame.RouteSnapshotPart.self, from: Data(frame.payload)),
                              part.count > 0, part.count <= 16, part.index >= 0, part.index < part.count,
                              !part.routes.isEmpty, part.routes.count <= 64,
                              part.routes.allSatisfy(ReadState.validAuthorityRoute) else {
                            if let acquired { state.capture.release(acquired) }
                            state.exitCode = 3; context.close(promise: nil); return
                        }
                        if let acquired {
                            guard part.index == 0 else { state.capture.release(acquired); state.exitCode = 3; context.close(promise: nil); return }
                            partialAuthority = PartialAuthority(generation: part.generation, count: part.count, routes: [], nextIndex: 0, encodedBytes: 0, reservation: acquired)
                            state.authorityAssemblyBytes = ReadState.authorityWorkspaceBytes
                        }
                        guard var partial = partialAuthority, partial.generation == part.generation, partial.count == part.count,
                              partial.nextIndex == part.index, partial.routes.count <= 1024 - part.routes.count,
                              partial.encodedBytes <= (16 << 20) - frame.payload.count else { state.exitCode = 3; context.close(promise: nil); return }
                        partial.routes.append(contentsOf: part.routes); partial.nextIndex += 1; partial.encodedBytes += frame.payload.count
                        if partial.nextIndex < partial.count { partialAuthority = partial; continue }
                        partialAuthority = nil
                        state.authorityAssemblyBytes = 0
                        generation = state.acceptAuthority(.init(generation: partial.generation, routes: partial.routes), reservation: partial.reservation)
                        if generation == nil { state.capture.release(partial.reservation) }
                    }
                    guard let generation else { state.exitCode = 3; context.close(promise: nil); return }
                    fencing = true
                    guard let options = context.channel.syncOptions else { state.exitCode = 3; context.close(promise: nil); return }
                    do { try options.setOption(ChannelOptions.autoRead, value: false) }
                    catch { state.exitCode = 3; context.close(promise: nil); return }
                    state.fencePersistence { [self] in
                        guard context.channel.isActive else { return }
                        guard state.producerIsValid() else { state.exitCode = 3; context.close(promise: nil); return }
                        let ack = AgentProxyTeeFrame.header(kind: .routeAcknowledgement, exchange: generation, payloadCount: 0)
                        context.channel.writeAndFlush(ByteBuffer(bytes: ack)).whenFailure { _ in context.close(promise: nil) }
                        state.resumePersistenceAfterAuthority()
                        // Previously queued saves were discarded by the fence;
                        // re-admit only records still authorized by this snapshot.
                        state.scheduleChangedRecords()
                        fencing = false
                        process(context: context)
                        if !fencing {
                            guard let options = context.channel.syncOptions else { state.exitCode = 3; context.close(promise: nil); return }
                            do { try options.setOption(ChannelOptions.autoRead, value: true) }
                            catch { state.exitCode = 3; context.close(promise: nil) }
                        }
                    }
                    return
                } else if frame.kind != .open || state.acceptOpen(frame) {
                    let sequence = state.capture.reconciler.store.sequence
                    state.capture.consume(frame)
                    if state.capture.reconciler.store.sequence != sequence { state.scheduleChangedRecords() }
                }
            }
        } catch { state.exitCode = 3; context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        let malformed = state.exitCode != 0 || partialAuthority != nil || deferredFrame != nil || decoder.bufferedByteCount != 0 || fencing
        deferredRetry?.cancel(); deferredRetry = nil
        state.authorityAwaitingCapacity = false
        if let deferredReservation { state.capture.release(deferredReservation); self.deferredReservation = nil }
        if let partialAuthority { state.capture.release(partialAuthority.reservation); self.partialAuthority = nil }
        state.authorityAssemblyBytes = 0
        if malformed { state.protocolFailure() }
        else { state.capture.finishAll(); state.scheduleChangedRecords() }
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.exitCode = 3; context.close(promise: nil) }
}

private struct ReadLine: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let newline = buffer.readableBytesView.firstIndex(of: 10) {
            let size = newline - buffer.readerIndex
            guard size <= ConversationReadAPI.maximumRequestBytes, let line = buffer.readSlice(length: size) else { throw TooLong() }
            buffer.moveReaderIndex(forwardBy: 1); context.fireChannelRead(NIOAny(line)); return .continue
        }
        guard buffer.readableBytes <= ConversationReadAPI.maximumRequestBytes else { throw TooLong() }
        return .needMoreData
    }
    struct TooLong: Error {}
}

private final class ReadClient: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let state: ReadState
    let channel: Channel
    private var requested = false
    private var cursor: ConversationReadAPI.Cursor?
    private var pendingSince: NIODeadline?
    private var initialDeadline: Scheduled<Void>?
    init(state: ReadState, channel: Channel) { self.state = state; self.channel = channel }
    func channelActive(context: ChannelHandlerContext) {
        initialDeadline = channel.eventLoop.scheduleTask(in: .seconds(15)) { [weak self] in
            guard let self, !self.requested else { return }; self.channel.close(promise: nil)
        }
        context.fireChannelActive()
    }
    func channelInactive(context: ChannelHandlerContext) { initialDeadline?.cancel(); context.fireChannelInactive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard state.producerIsValid() else { context.close(promise: nil); return }
        // One query per channel; a subscribe query turns it into an event stream.
        // Never accumulate pipelined replies or retain unbounded request state.
        guard !requested else { context.close(promise: nil); return }
        requested = true; initialDeadline?.cancel()
        guard let reservation = state.capture.reserve(bytes: 8 << 20) else { context.close(promise: nil); return }
        defer { state.capture.release(reservation) }
        let line = Data(unwrapInboundIn(data).readableBytesView)
        struct StatusRequest: Decodable { let id: String; let method: String }
        struct StatusReply: Encodable { let id: String; let result: ReadState.PersistenceStatus }
        if let request = try? JSONDecoder().decode(StatusRequest.self, from: line), request.method == "persistence.status",
           !request.id.isEmpty, request.id.utf8.count <= AgentProxyControl.maximumFieldBytes,
           !request.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
           let bytes = try? JSONEncoder().encode(StatusReply(id: request.id, result: state.persistenceStatus())) {
            write(bytes + Data([10]), closeAfter: true)
            return
        }
        let bytes = ConversationReadAPI.answer(line, store: state.capture.reconciler.store)
        struct Method: Decodable { let method: String }
        if (try? JSONDecoder().decode(Method.self, from: line).method) == "conversation.subscribe",
           let result = try? JSONDecoder().decode(ConversationReadAPI.Reply.self, from: bytes).result, !result.reset {
            cursor = ConversationReadAPI.Cursor(result)
        }
        write(bytes, closeAfter: cursor == nil)
    }
    func tick() {
        if let since = pendingSince {
            if NIODeadline.now() - since >= .seconds(5) { channel.close(promise: nil) }
            return // coalesce, don't queue intermediate snapshots
        }
        guard let cursor else { return }
        guard let reservation = state.capture.reserve(bytes: 8 << 20) else { channel.close(promise: nil); return }
        defer { state.capture.release(reservation) }
        guard let update = ConversationReadAPI.update(after: cursor, store: state.capture.reconciler.store) else { return }
        self.cursor = ConversationReadAPI.Cursor(update)
        write(ConversationReadAPI.encodeUpdate(update), closeAfter: self.cursor == nil)
    }
    private func write(_ bytes: Data, closeAfter: Bool) {
        guard pendingSince == nil, bytes.count <= ConversationReadAPI.maximumReplyBytes else { channel.close(promise: nil); return }
        pendingSince = .now()
        var buffer = channel.allocator.buffer(capacity: bytes.count); buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer).whenComplete { result in
            self.pendingSince = nil
            if closeAfter { self.channel.close(promise: nil) }
            else if case .failure = result { self.channel.close(promise: nil) }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
