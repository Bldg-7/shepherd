import Foundation

#if os(macOS)
import Darwin

/// Talks to this same Mac's own herdr instance directly over its Unix domain
/// socket — no SSH, no credential, because there's no network hop at all.
/// Mirrors `SSHHerdrTransport`'s one-connection-per-request design: herdr.sock
/// answers an ordinary request on a connection and then closes it, whatever
/// the transport (confirmed live with a plain local socket — see
/// SSHHerdrTransport.swift's header comment for the full story). The
/// exceptions are the requests that wait for something — `events.subscribe`,
/// `events.wait` and `agent.wait`: herdr keeps their connection open, for as
/// long as the subscription lasts or until what is waited for happens.
public actor LocalHerdrTransport: HerdrTransport {
    public enum LocalHerdrTransportError: Error, LocalizedError {
        case socketPathTooLong
        case connectFailed(String)
        case noResponse

        public var errorDescription: String? {
            switch self {
            case .socketPathTooLong: String(localized: "herdr.sock's path is too long for a Unix domain socket", bundle: .shepherdKit)
            case .connectFailed(let reason): String(localized: "Couldn't reach herdr.sock: \(reason)", bundle: .shepherdKit)
            case .noResponse: String(localized: "herdr.sock closed the connection without responding", bundle: .shepherdKit)
            }
        }
    }

    public static var defaultSocketPath: String {
        // Not `FileManager.default.homeDirectoryForCurrentUser` — under App
        // Sandbox that resolves to the container path, not the real home
        // (confirmed live). This app no longer sandboxes (direct AF_UNIX
        // connect() to an arbitrary path is blocked under App Sandbox with
        // no grantable entitlement — confirmed live: EPERM even with a
        // security-scoped bookmark and network.client both active), but
        // reading the password database directly is correct either way.
        let home: String
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".config/herdr/herdr.sock").path
    }

    private let socketPath: String
    /// Where every request's and subscription's socket work happens — see
    /// `SocketExchange` and `SocketSubscription`. Serial, and shared by all
    /// of this transport's connections: nothing run on it ever blocks, so
    /// one queue carries any number of them.
    private let ioQueue = DispatchQueue(label: "LocalHerdrTransport.io")
    private var nextRequestID = 0

    public init(socketPath: String = LocalHerdrTransport.defaultSocketPath) {
        self.socketPath = socketPath
    }

    // Nothing to keep open between calls — see send() below.
    public func connect() async throws {}
    public func disconnect() async {}

    /// The actor's part in a request is to hand out its id. The round trip
    /// itself is awaited with the actor released, so requests don't queue
    /// behind each other. A machine whose herdr can't subscribe has its
    /// monitor keep several `events.wait` long-polls open per pane instead
    /// (see `MachineMonitor`), each held by herdr for up to 25 s; it needs to
    /// hear from whichever resolves first — and to get a `session.snapshot`
    /// through while the rest are still waiting.
    public func send(method: String, params: JSONValue) async throws -> JSONValue {
        let id = "req_\(nextRequestID)"
        nextRequestID += 1
        let request = HerdrRequest(id: id, method: method, params: params)
        let line = try request.encodedLine()

        let exchange = SocketExchange(socketPath: socketPath, requestLine: line, queue: ioQueue)
        let responseLine = try await exchange.response()
        // An empty-but-present line is still "no response": herdr always
        // sends a JSON object, never a blank line.
        guard !responseLine.isEmpty else {
            throw LocalHerdrTransportError.noResponse
        }
        let response = try JSONDecoder().decode(HerdrResponse.self, from: responseLine)
        if let error = response.error {
            throw error
        }
        return response.result ?? .null
    }

    public func runHerdr(_ arguments: [String]) async throws -> Data {
        try await HerdrExecutable.runLocally(arguments)
    }

    public func runScript(_ script: String) async throws -> Data {
        let command = LocalCommand.Command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        return try await LocalCommand.run(command) { status, stderr in
            HostScriptError(status: status, message: stderr)
        }
    }

    /// Like `send`, the actor only hands out the id; the subscription's
    /// connection is read on `ioQueue` as lines arrive, whatever the reader
    /// is busy with. herdr drops a subscriber it can't write to for 5 s
    /// (its STREAM_WRITE_TIMEOUT, 0.9.1), so the lines are taken off the
    /// socket straight away and wait in the stream for the reader.
    public func subscribe(params: JSONValue) async throws -> HerdrSubscriptionLines {
        let id = "req_\(nextRequestID)"
        nextRequestID += 1
        let line = try HerdrRequest(id: id, method: "events.subscribe", params: params).encodedLine()
        return try await SocketSubscription.open(socketPath: socketPath, requestLine: line, queue: ioQueue)
    }
}

/// One request and its one-line response, over a connection of its own.
///
/// The socket is non-blocking and driven by dispatch sources instead of by a
/// thread sitting in `recv`: a long-poll spends nearly all of its life
/// waiting, a monitor polling that way with 30 panes has around 90 of them
/// open at a time (see `MachineMonitor`), and a parked thread apiece would
/// run GCD's pool dry. It is also what makes cancellation prompt — there is
/// no blocked call to wake, only a source to cancel.
///
/// Every stored property below is touched on `queue` only, which is what
/// makes this safe to share despite the compiler not being able to see it.
/// That one serial queue is also what settles the races: the response
/// arriving, the peer hanging up and the task being cancelled each run as
/// their own block on it, the first to get there calls `finish`, and
/// `finish` leaves nothing for the others to act on.
private nonisolated final class SocketExchange: @unchecked Sendable {
    private typealias TransportError = LocalHerdrTransport.LocalHerdrTransportError

    /// A response line longer than this is cut off here, newline or not.
    private static let lineLimit = 1 * 1024 * 1024
    private static let readChunkSize = 16 * 1024

    private let socketPath: String
    private let requestLine: Data
    private let queue: DispatchQueue

    /// Non-nil exactly while the caller is still waiting for an outcome.
    private var continuation: CheckedContinuation<Data, Error>?
    /// Cancellation can be delivered before `begin` has run — a task that is
    /// already cancelled runs its cancellation handler first — and has to
    /// stop `begin` from opening a socket at all.
    private var isCancelled = false
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// How many of the sources above still have the descriptor registered
    /// with the kernel. See `sourceDidCancel`.
    private var registeredSources = 0
    private var sentCount = 0
    private var received = Data()

    init(socketPath: String, requestLine: Data, queue: DispatchQueue) {
        self.socketPath = socketPath
        self.requestLine = requestLine
        self.queue = queue
    }

    /// Sends the request and returns the response line, without its newline.
    /// Throws `CancellationError` as soon as the calling task is cancelled,
    /// however long the server would still have held the request.
    func response() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.begin(continuation) }
            }
        } onCancel: {
            queue.async { self.cancel() }
        }
    }

    private func begin(_ continuation: CheckedContinuation<Data, Error>) {
        guard !isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        do {
            descriptor = try HerdrSocket.open(path: socketPath)
        } catch {
            finish(.failure(error))
            return
        }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { self.readAvailable() }
        readSource.setCancelHandler { self.sourceDidCancel() }
        self.readSource = readSource
        registeredSources += 1
        readSource.activate()

        writePending()
    }

    private func cancel() {
        isCancelled = true
        finish(.failure(CancellationError()))
    }

    /// The one place an exchange ends. Whatever gets here first decides the
    /// outcome; anything arriving later finds no continuation and returns.
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        continuation.resume(with: result)
    }

    /// The descriptor is closed here rather than in `finish`: a dispatch
    /// source keeps its descriptor registered until its cancellation handler
    /// has run, and closing earlier would free the number for the next
    /// `socket()` while that registration still refers to it. With a write
    /// source as well as the read source, that means waiting for the last
    /// of them.
    private func sourceDidCancel() {
        registeredSources -= 1
        guard registeredSources == 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func writePending() {
        while sentCount < requestLine.count {
            let (count, error) = requestLine.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Int, Int32) in
                let count = Darwin.send(descriptor, raw.baseAddress?.advanced(by: sentCount), raw.count - sentCount, 0)
                return (count, errno)
            }
            if count > 0 {
                sentCount += count
            } else if count < 0 && error == EINTR {
                continue
            } else if count < 0 && (error == EAGAIN || error == EWOULDBLOCK) {
                // The socket buffer is full (a request larger than it, or a
                // server slow to read): carry on once there is room again.
                waitUntilWritable()
                return
            } else {
                finish(.failure(TransportError.connectFailed(String(localized: "write failed: \(systemErrorDescription(error))", bundle: .shepherdKit))))
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func waitUntilWritable() {
        guard writeSource == nil else { return }
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        writeSource.setEventHandler { self.writePending() }
        writeSource.setCancelHandler { self.sourceDidCancel() }
        self.writeSource = writeSource
        registeredSources += 1
        writeSource.activate()
    }

    /// Takes what has arrived and finishes once it holds a whole line. The
    /// peer closing first counts as the end of the line too, unless it sent
    /// nothing at all.
    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: min(Self.readChunkSize, Self.lineLimit - received.count))
        let (count, error) = chunk.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> (Int, Int32) in
            let count = Darwin.recv(descriptor, raw.baseAddress, raw.count, 0)
            return (count, errno)
        }
        if count > 0 {
            if let newlineIndex = chunk[..<count].firstIndex(of: 0x0A) {
                received.append(contentsOf: chunk[..<newlineIndex])
                finish(.success(received))
            } else {
                received.append(contentsOf: chunk[..<count])
                if received.count >= Self.lineLimit {
                    finish(.success(received))
                }
            }
        } else if count == 0 {
            finish(received.isEmpty ? .failure(TransportError.noResponse) : .success(received))
        } else if error != EINTR && error != EAGAIN && error != EWOULDBLOCK {
            finish(.failure(TransportError.connectFailed(String(localized: "read failed: \(systemErrorDescription(error))", bundle: .shepherdKit))))
        }
    }
}

/// Opening the socket every connection to herdr.sock starts with.
private nonisolated enum HerdrSocket {
    private typealias TransportError = LocalHerdrTransport.LocalHerdrTransportError

    /// Returns a connected, non-blocking socket.
    static func open(path: String) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLength else {
            throw TransportError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buffer = raw.bindMemory(to: CChar.self)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = CChar(bitPattern: byte)
            }
            buffer[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.connectFailed(systemErrorDescription(errno))
        }
        // Not to be inherited by the terminal attaches this app forks while
        // long-polls and subscriptions are open: herdr tells that a caller
        // has given up on a wait, or on a subscription, by its end of the
        // connection closing, and a copy held by a child would keep it open
        // for as long as that child runs. macOS has no SOCK_CLOEXEC to ask
        // for this in `socket()` itself.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        // Connecting comes before switching to non-blocking on purpose. A
        // Unix domain connect doesn't wait for the peer to accept: the
        // kernel either queues the connection on the listener there and
        // then or refuses it, so there is nothing for it to block on and no
        // in-progress state to handle.
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = systemErrorDescription(errno)
            Darwin.close(fd)
            throw TransportError.connectFailed(reason)
        }

        // A server that goes away mid-request must surface as a failed
        // write, not as a SIGPIPE that takes the whole app down.
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }
}

/// An `events.subscribe` over a connection of its own, kept open for as long
/// as the subscription lasts.
///
/// Built like `SocketExchange` — a non-blocking socket driven by dispatch
/// sources on `queue`, every stored property touched on `queue` only, which
/// is what makes this safe to share — but where an exchange ends with its
/// one response line, this hands the first line, herdr's acknowledgement,
/// to `open`, and every line after it to the stream `open` returns, until
/// herdr or the reader closes the connection. Lines are taken off the socket
/// as they arrive and wait in that stream, however slowly it is read.
private nonisolated final class SocketSubscription: @unchecked Sendable {
    private typealias TransportError = LocalHerdrTransport.LocalHerdrTransportError

    private static let readChunkSize = 16 * 1024

    private let socketPath: String
    private let requestLine: Data
    private let queue: DispatchQueue
    /// Gets the first line, and ends right after it.
    private let acknowledgement: AsyncThrowingStream<Data, any Error>.Continuation
    /// Gets every line after the first.
    private let lines: AsyncThrowingStream<Data, any Error>.Continuation

    /// Set by `end`, after which nothing is read or written any more — and
    /// before `begin` has run, keeps it from opening a socket at all.
    private var isEnded = false
    private var isAcknowledged = false
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// See `SocketExchange.sourceDidCancel`.
    private var registeredSources = 0
    private var sentCount = 0
    private var buffer = HerdrLineBuffer()

    private init(
        socketPath: String,
        requestLine: Data,
        queue: DispatchQueue,
        acknowledgement: AsyncThrowingStream<Data, any Error>.Continuation,
        lines: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
        self.socketPath = socketPath
        self.requestLine = requestLine
        self.queue = queue
        self.acknowledgement = acknowledgement
        self.lines = lines
    }

    /// Opens the connection, sends the request, and returns once herdr has
    /// acknowledged it (see `HerdrTransport.subscribe`).
    static func open(socketPath: String, requestLine: Data, queue: DispatchQueue) async throws -> HerdrSubscriptionLines {
        let (acknowledgementStream, acknowledgement) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (lineStream, lines) = AsyncThrowingStream<Data, any Error>.makeStream()
        let subscription = SocketSubscription(
            socketPath: socketPath,
            requestLine: requestLine,
            queue: queue,
            acknowledgement: acknowledgement,
            lines: lines
        )
        let close: @Sendable () -> Void = { queue.async { subscription.end() } }
        // The caller giving up on the acknowledgement — its task cancelled
        // while it waits — gives up on the subscription. The stream ending
        // because the acknowledgement came doesn't.
        acknowledgement.onTermination = { termination in
            if case .cancelled = termination { close() }
        }
        // The reader stopping, for whatever reason, ends the connection.
        lines.onTermination = { _ in close() }
        queue.async { subscription.begin() }
        var first: Data?
        do {
            for try await line in acknowledgementStream {
                first = line
                break
            }
            try Task.checkCancellation()
            try HerdrStreamLine.checkAcknowledgement(first)
        } catch {
            close()
            throw error
        }
        return HerdrSubscriptionLines(lines: lineStream, close: close)
    }

    private func begin() {
        guard !isEnded else { return }
        do {
            descriptor = try HerdrSocket.open(path: socketPath)
        } catch {
            end(throwing: error)
            return
        }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { self.readAvailable() }
        readSource.setCancelHandler { self.sourceDidCancel() }
        self.readSource = readSource
        registeredSources += 1
        readSource.activate()

        writePending()
    }

    /// The one place a subscription ends: the reader closing it, herdr
    /// closing it, or the connection failing. Whatever gets here first
    /// decides how the streams end; anything later finds nothing to do.
    private func end(throwing error: (any Error)? = nil) {
        guard !isEnded else { return }
        isEnded = true
        if let error {
            acknowledgement.finish(throwing: error)
            lines.finish(throwing: error)
        } else {
            acknowledgement.finish()
            lines.finish()
        }
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
    }

    /// As in `SocketExchange`: the descriptor is closed once the last
    /// source registered on it has been cancelled.
    private func sourceDidCancel() {
        registeredSources -= 1
        guard registeredSources == 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func writePending() {
        while sentCount < requestLine.count {
            let (count, error) = requestLine.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Int, Int32) in
                let count = Darwin.send(descriptor, raw.baseAddress?.advanced(by: sentCount), raw.count - sentCount, 0)
                return (count, errno)
            }
            if count > 0 {
                sentCount += count
            } else if count < 0 && error == EINTR {
                continue
            } else if count < 0 && (error == EAGAIN || error == EWOULDBLOCK) {
                waitUntilWritable()
                return
            } else {
                end(throwing: TransportError.connectFailed(String(localized: "write failed: \(systemErrorDescription(error))", bundle: .shepherdKit)))
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func waitUntilWritable() {
        guard writeSource == nil else { return }
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        writeSource.setEventHandler { self.writePending() }
        writeSource.setCancelHandler { self.sourceDidCancel() }
        self.writeSource = writeSource
        registeredSources += 1
        writeSource.activate()
    }

    /// Takes what has arrived and passes on every line it completes. herdr
    /// closing the connection ends the subscription — after an error line
    /// (`events_lost`, say), or because it is going away; before the
    /// acknowledgement, `open` reads that as there having been none.
    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: Self.readChunkSize)
        let (count, error) = chunk.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> (Int, Int32) in
            let count = Darwin.recv(descriptor, raw.baseAddress, raw.count, 0)
            return (count, errno)
        }
        if count > 0 {
            let complete: [Data]
            do {
                complete = try buffer.append(chunk[..<count])
            } catch {
                end(throwing: error)
                return
            }
            for line in complete {
                if isAcknowledged {
                    lines.yield(line)
                } else {
                    isAcknowledged = true
                    acknowledgement.yield(line)
                    acknowledgement.finish()
                }
            }
        } else if count == 0 {
            end()
        } else if error != EINTR && error != EAGAIN && error != EWOULDBLOCK {
            end(throwing: TransportError.connectFailed(String(localized: "read failed: \(systemErrorDescription(error))", bundle: .shepherdKit)))
        }
    }
}
#endif
