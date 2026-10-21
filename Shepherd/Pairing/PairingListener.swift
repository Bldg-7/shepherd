#if os(macOS)
import Darwin
import Foundation

/// Which connections the pairing listener takes, for the address the code
/// shows (SHPHRD-77, "기기→Mac 경로"): for a .local name or a private IPv4
/// address, connections from a private or link-local address to one of
/// this Mac's local addresses; for the Tailscale kinds, connections from a
/// Tailscale node to this Mac's Tailscale address. The listener is on every
/// IPv4 address of the Mac, and this is what it lets through: with a
/// Tailscale kind chosen, a device on the local network doesn't get as far
/// as the first message.
nonisolated struct PairingConnectionFilter: Hashable, Sendable {
    enum Sources: Hashable, Sendable {
        /// Private (RFC 1918) or link-local.
        case lan
        /// Tailscale's node range, without the addresses it keeps.
        case tailscale
        /// For tests on loopback.
        case ranges([IPv4Range])
    }

    var sources: Sources
    /// This Mac's addresses a connection may arrive at.
    var destinations: Set<PairingIPv4>

    init(sources: Sources, destinations: Set<PairingIPv4>) {
        self.sources = sources
        self.destinations = destinations
    }

    init(option: PairingAddressOption) {
        self.init(sources: option.kind.isLAN ? .lan : .tailscale, destinations: Set(option.localAddresses))
    }

    func allows(remote: PairingIPv4, local: PairingIPv4) -> Bool {
        guard destinations.contains(local) else { return false }
        switch sources {
        case .lan: return PairingAddressRanges.isLAN(remote)
        case .tailscale: return PairingAddressRanges.isTailscale(remote)
        case .ranges(let ranges): return ranges.contains { $0.contains(remote) }
        }
    }
}

/// The two ends of an accepted connection.
nonisolated struct PairingEndpoints: Hashable, Sendable {
    let remote: PairingIPv4
    let remotePort: UInt16
    let local: PairingIPv4
}

/// The TCP listener a device sends its pairing request to, open only while
/// a code is shown on the pairing page (SHPHRD-77, "기기→Mac 경로", "위협과
/// 대응"). On IPv4 only: a device always connects to an IPv4 address.
///
/// A connection the filter doesn't let through is closed before a byte is
/// read. One connection at a time may be waiting for its first message,
/// for ten seconds at most; one that comes while another is waiting is
/// closed at once. A connection whose first message arrives is handed to
/// `onFirstFrame` and no longer counts as waiting — the code it is for may
/// keep it open while the person decides, and a later connection is then
/// told the code was already used. A connection that sends nothing in time,
/// or something that isn't a frame, is reported to `onHandshakeFailure`.
///
/// All of its state is kept on its own serial queue.
nonisolated final class PairingListener: @unchecked Sendable {
    enum Address: Sendable {
        /// Every IPv4 address of this Mac.
        case any
        /// 127.0.0.1 only, for tests.
        case loopback
    }

    enum HandshakeFailure: Error, Sendable {
        case timedOut
        case malformed
    }

    static let handshakeTimeout: Duration = .seconds(10)

    private let queue = DispatchQueue(label: "PairingListener")
    private let handshakeTimeout: Duration
    private let onFirstFrame: @Sendable (Data, PairingConnection) -> Void
    private let onHandshakeFailure: @Sendable (HandshakeFailure, PairingEndpoints) -> Void
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?
    private var filter: PairingConnectionFilter?
    private var waiting: PairingConnection?

    init(handshakeTimeout: Duration = PairingListener.handshakeTimeout,
         onFirstFrame: @escaping @Sendable (Data, PairingConnection) -> Void,
         onHandshakeFailure: @escaping @Sendable (HandshakeFailure, PairingEndpoints) -> Void) {
        self.handshakeTimeout = handshakeTimeout
        self.onFirstFrame = onFirstFrame
        self.onHandshakeFailure = onHandshakeFailure
    }

    /// Starts listening on a port the system picks, and returns it.
    func start(on address: Address, filter: PairingConnectionFilter?) throws -> UInt16 {
        try queue.sync {
            guard socket < 0 else { throw PairingListenerError.alreadyStarted }
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw PairingListenerError.system("socket", errno) }
            do {
                try Self.prepare(fd)
                var bound = sockaddr_in()
                bound.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                bound.sin_family = sa_family_t(AF_INET)
                bound.sin_port = 0
                bound.sin_addr.s_addr = (address == .loopback ? INADDR_LOOPBACK : INADDR_ANY).bigEndian
                let bindResult = withUnsafePointer(to: &bound) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard bindResult == 0 else { throw PairingListenerError.system("bind", errno) }
                guard Darwin.listen(fd, 4) == 0 else { throw PairingListenerError.system("listen", errno) }
                guard let local = Self.address(of: fd, peer: false) else { throw PairingListenerError.system("getsockname", errno) }
                socket = fd
                self.filter = filter
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptPending() }
                source.setCancelHandler { Darwin.close(fd) }
                self.source = source
                source.resume()
                return local.port
            } catch {
                Darwin.close(fd)
                throw error
            }
        }
    }

    /// The filter for the code now shown. Nil lets nothing through.
    func setFilter(_ filter: PairingConnectionFilter?) {
        queue.async { self.filter = filter }
    }

    /// Stops listening. Connections already handed on stay open; one still
    /// waiting for its first message is closed.
    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            socket = -1
            filter = nil
            waiting?.close()
            waiting = nil
        }
    }

    var isListening: Bool {
        queue.sync { socket >= 0 }
    }

    // MARK: - On the queue

    private func acceptPending() {
        while socket >= 0 {
            let fd = Darwin.accept(socket, nil, nil)
            guard fd >= 0 else { return }
            guard (try? Self.prepare(fd)) != nil,
                  let remote = Self.address(of: fd, peer: true), let local = Self.address(of: fd, peer: false) else {
                Darwin.close(fd)
                continue
            }
            let endpoints = PairingEndpoints(remote: remote.address, remotePort: remote.port, local: local.address)
            guard let filter, filter.allows(remote: endpoints.remote, local: endpoints.local), waiting == nil else {
                Darwin.close(fd)
                continue
            }
            let connection = PairingConnection(fd: fd, endpoints: endpoints)
            waiting = connection
            connection.begin()
            let timeout = handshakeTimeout
            Task.detached { [weak self] in
                do {
                    let frame = try await connection.nextFrame(timeout: timeout)
                    self?.handshakeEnded(connection)
                    self?.onFirstFrame(frame, connection)
                } catch {
                    connection.close()
                    self?.handshakeEnded(connection)
                    let failure: HandshakeFailure = (error as? PairingConnectionError) == .timedOut ? .timedOut : .malformed
                    self?.onHandshakeFailure(failure, endpoints)
                }
            }
        }
    }

    private func handshakeEnded(_ connection: PairingConnection) {
        queue.sync {
            if waiting === connection { waiting = nil }
        }
    }

    /// Non-blocking, closed in child processes, and no SIGPIPE on a write to
    /// a closed connection.
    fileprivate static func prepare(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw PairingListenerError.system("fcntl", errno) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw PairingListenerError.system("fcntl", errno) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw PairingListenerError.system("setsockopt", errno)
        }
    }

    private static func address(of fd: Int32, peer: Bool) -> (address: PairingIPv4, port: UInt16)? {
        var storage = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { peer ? getpeername(fd, $0, &length) : getsockname(fd, $0, &length) }
        }
        guard result == 0, storage.sin_family == sa_family_t(AF_INET) else { return nil }
        return (PairingIPv4(value: UInt32(bigEndian: storage.sin_addr.s_addr)), UInt16(bigEndian: storage.sin_port))
    }
}

nonisolated enum PairingListenerError: Error, Equatable, LocalizedError {
    case alreadyStarted
    case system(String, Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "The pairing listener is already running."
        case .system(let call, let code):
            "\(call): \(String(cString: strerror(code)))"
        }
    }
}

nonisolated enum PairingConnectionError: Error, Equatable {
    case timedOut
    case closed
    case tooLong
    /// More frames than a pairing ever sends, before they were read.
    case tooManyFrames
    case busy
    case writeFailed(Int32)
}

/// One accepted connection: frames in, as they complete, and bytes out.
/// Its state is kept on its own serial queue.
nonisolated final class PairingConnection: @unchecked Sendable {
    /// A device sends a request and a report; anything more, unread, is
    /// someone else's doing.
    static let maximumQueuedFrames = 4

    let endpoints: PairingEndpoints
    private let fd: Int32
    private let queue = DispatchQueue(label: "PairingConnection")
    private var source: DispatchSourceRead?
    private var reader = PairingFrameReader()
    private var frames: [Data] = []
    private var failure: PairingConnectionError?
    private var waiter: CheckedContinuation<Data, any Error>?
    private var waiterGeneration = 0
    private var isClosed = false

    fileprivate init(fd: Int32, endpoints: PairingEndpoints) {
        self.fd = fd
        self.endpoints = endpoints
    }

    fileprivate func begin() {
        queue.async { [weak self] in
            guard let self else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: self.queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            let fd = self.fd
            source.setCancelHandler { Darwin.close(fd) }
            self.source = source
            source.resume()
        }
    }

    /// The next frame's body. Throws `timedOut` when none completes in
    /// `timeout`, and `closed` (or why) once the connection has ended.
    func nextFrame(timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if !self.frames.isEmpty {
                    continuation.resume(returning: self.frames.removeFirst())
                    return
                }
                if let failure = self.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                guard self.waiter == nil else {
                    continuation.resume(throwing: PairingConnectionError.busy)
                    return
                }
                self.waiter = continuation
                self.waiterGeneration += 1
                let generation = self.waiterGeneration
                let (seconds, attoseconds) = timeout.components
                let interval = Double(seconds) + Double(attoseconds) / 1e18
                self.queue.asyncAfter(deadline: .now() + interval) {
                    guard self.waiterGeneration == generation, let waiter = self.waiter else { return }
                    self.waiter = nil
                    waiter.resume(throwing: PairingConnectionError.timedOut)
                }
            }
        }
    }

    /// Writes all of `data`, waiting up to five seconds for room.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard !self.isClosed else {
                    continuation.resume(throwing: PairingConnectionError.closed)
                    return
                }
                continuation.resume(with: Result { try self.writeAll(data) })
            }
        }
    }

    func close() {
        queue.async { self.end(.closed) }
    }

    // MARK: - On the queue

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isClosed {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                do {
                    for frame in try reader.append(buffer.prefix(count)) { deliver(frame) }
                } catch {
                    end(.tooLong)
                }
            } else if count == 0 {
                end(.closed)
            } else {
                if errno != EAGAIN && errno != EINTR { end(.closed) }
                return
            }
        }
    }

    private func deliver(_ frame: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else if frames.count >= Self.maximumQueuedFrames {
            end(.tooManyFrames)
        } else {
            frames.append(frame)
        }
    }

    private func end(_ reason: PairingConnectionError) {
        guard !isClosed else { return }
        isClosed = true
        failure = reason
        source?.cancel()
        source = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: reason)
        }
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        let bytes = Array(data)
        let deadline = Date().addingTimeInterval(5)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                guard Date() < deadline else { throw PairingConnectionError.writeFailed(EAGAIN) }
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&poller, 1, 100)
            } else {
                throw PairingConnectionError.writeFailed(errno)
            }
        }
    }
}
#endif
