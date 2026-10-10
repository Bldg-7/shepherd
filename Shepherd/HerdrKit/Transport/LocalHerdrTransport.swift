import Foundation

#if os(macOS)
import Darwin

/// Talks to this same Mac's own herdr instance directly over its Unix domain
/// socket — no SSH, no credential, because there's no network hop at all.
/// Mirrors `SSHHerdrTransport`'s one-connection-per-request design: herdr.sock
/// answers exactly one request per connection and closes it, regardless of
/// transport (confirmed live with a plain local socket — see
/// SSHHerdrTransport.swift's header comment for the full story).
actor LocalHerdrTransport: HerdrTransport {
    enum LocalHerdrTransportError: Error, LocalizedError {
        case socketPathTooLong
        case connectFailed(String)
        case noResponse

        var errorDescription: String? {
            switch self {
            case .socketPathTooLong: String(localized: "herdr.sock's path is too long for a Unix domain socket")
            case .connectFailed(let reason): String(localized: "Couldn't reach herdr.sock: \(reason)")
            case .noResponse: String(localized: "herdr.sock closed the connection without responding")
            }
        }
    }

    static var defaultSocketPath: String {
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
    /// Where every request's socket work happens — see `SocketExchange`.
    /// Serial, and shared by all of this transport's requests: nothing run
    /// on it ever blocks, so one queue carries any number of them.
    private let ioQueue = DispatchQueue(label: "LocalHerdrTransport.io")
    private var nextRequestID = 0

    init(socketPath: String = LocalHerdrTransport.defaultSocketPath) {
        self.socketPath = socketPath
    }

    // Nothing to keep open between calls — see send() below.
    func connect() async throws {}
    func disconnect() async {}

    /// The actor's part in a request is to hand out its id. The round trip
    /// itself is awaited with the actor released, so requests don't queue
    /// behind each other: the status board keeps several `events.wait`
    /// long-polls open per pane, each held by herdr for up to 25 s, and needs to hear
    /// from whichever resolves first — and to get a `pane.list` through
    /// while the rest are still waiting.
    func send(method: String, params: JSONValue) async throws -> JSONValue {
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

    func runHerdr(_ arguments: [String]) async throws -> Data {
        try await HerdrExecutable.runLocally(arguments)
    }

    func runScript(_ script: String) async throws -> Data {
        let command = LocalCommand.Command(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        return try await LocalCommand.run(command) { status, stderr in
            HostScriptError(status: status, message: stderr)
        }
    }

    func events() -> AsyncStream<JSONValue> {
        // Same limitation as SSHHerdrTransport: herdr.sock has no real push
        // stream to offer (even events.subscribe's ack never arrives before
        // the connection drops). AgentBoardView polls agent.list instead.
        AsyncStream { $0.finish() }
    }
}

/// One request and its one-line response, over a connection of its own.
///
/// The socket is non-blocking and driven by dispatch sources instead of by a
/// thread sitting in `recv`: a long-poll spends nearly all of its life
/// waiting, a board with 30 panes has around 90 of them open at a time, and a
/// parked thread apiece would run GCD's pool dry. It is also what makes
/// cancellation prompt — there is no blocked call to wake, only a source to
/// cancel.
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
            descriptor = try Self.openSocket(path: socketPath)
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
                finish(.failure(TransportError.connectFailed(String(localized: "write failed: \(systemErrorDescription(error))"))))
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
            finish(.failure(TransportError.connectFailed(String(localized: "read failed: \(systemErrorDescription(error))"))))
        }
    }

    /// Returns a connected, non-blocking socket.
    private static func openSocket(path: String) throws -> Int32 {
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
        // long-polls are open: herdr tells that a caller has given up on a
        // wait by its end of the connection closing, and a copy held by a
        // child would keep it open for as long as that child runs. macOS
        // has no SOCK_CLOEXEC to ask for this in `socket()` itself.
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
#endif
