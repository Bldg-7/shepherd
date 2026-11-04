import Foundation

/// Bounded read-only NDJSON over an independently owned byte stream per request.
/// No herdr.sock, terminal RPC, core handshake, runtime injection or proxy launch.
/// The factory validates the current saved host/pin before each new stream.
public actor ConversationLineConnection: ConversationLineTransport {
    public enum Failure: Error { case closed, capacity, cleanupUnconfirmed }
    public typealias Factory = @Sendable (HerdrLineEndpoint) async throws -> any CoreByteTransport
    private let factory: Factory
    private var generation = UUID()
    private var stopped = false
    private var cleanupFailed = false
    private var opening: [UUID: Task<any CoreByteTransport, Error>] = [:]
    private var active: [UUID: ConversationLineLifetime] = [:]
    public init(factory: @escaping Factory) { self.factory = factory }
    deinit {
        for job in opening.values { job.cancel() }
        for life in active.values { _ = life.stop() }
    }

    public func openLineStream(endpoint: HerdrLineEndpoint, request: Data) async throws -> HerdrLineStream {
        try Task.checkCancellation()
        guard !stopped, !cleanupFailed else { throw Failure.closed }
        guard opening.count + active.count < 8 else { throw Failure.capacity }
        guard !request.isEmpty, request.count <= 64 << 10, request.last == 10, !request.dropLast().contains(10) else { throw HerdrLineStreamError.invalidRequest }
        let id = UUID(), epoch = generation, factory = factory
        let job = Task { try await factory(endpoint) }; opening[id] = job
        let transport: any CoreByteTransport
        do {
            transport = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        } catch { opening[id] = nil; throw error }
        opening[id] = nil
        guard !stopped, epoch == generation, !Task.isCancelled else { try await transport.close(); throw Failure.closed }
        let (lines, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        let life = ConversationLineLifetime(transport: transport, continuation: continuation)
        active[id] = life
        life.armDeadline()
        continuation.onTermination = { _ in _ = life.stop() }
        do {
            try await withTaskCancellationHandler {
                try await transport.start()
                try Task.checkCancellation()
                try await transport.write(request)
                try Task.checkCancellation()
            } onCancel: { _ = life.stop() }
            guard !stopped, epoch == generation else { throw Failure.closed }
            // Explicitly owned below; do not inherit the owner actor's executor
            // and keep it alive forever on a quiet subscription.
            let reader = Task.detached { [weak self] in
                await life.read()
                do { try await life.stop().value; await self?.retire(id, failed: false) }
                catch { await self?.retire(id, failed: true) }
            }
            life.install(reader)
            return HerdrLineStream(lines: lines, close: { _ = life.stop() })
        } catch {
            let failure = error
            do { try await life.stop().value; active[id] = nil }
            catch { cleanupFailed = true; throw Failure.cleanupUnconfirmed }
            throw failure
        }
    }
    private func retire(_ id: UUID, failed: Bool) {
        active[id] = nil
        if failed { cleanupFailed = true }
    }
    public func close() async throws {
        stopped = true; generation = UUID()
        let jobs = Array(opening.values), streams = Array(active.values)
        opening.removeAll(); active.removeAll()
        for job in jobs { job.cancel() }
        // Start all close operations before awaiting any of them.
        let cleanups = streams.map { $0.stop() }
        for job in jobs {
            if case .success(let transport) = await job.result {
                do { try await transport.close() } catch { cleanupFailed = true }
            }
        }
        for cleanup in cleanups { do { try await cleanup.value } catch { cleanupFailed = true } }
        if cleanupFailed { throw Failure.cleanupUnconfirmed }
    }
}

/// Only cancellation/first-reply/cleanup ownership crosses executors. Framing
/// stays in one reader task; the queue holds at most two <=2MiB lines. A slow
/// reader gets a reset error, never a silently dropped conversation delta.
private nonisolated final class ConversationLineLifetime: @unchecked Sendable {
    let transport: any CoreByteTransport
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var cleanup: Task<Void, Error>?
    private var received = false
    private var expired = false
    init(transport: any CoreByteTransport, continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.transport = transport; self.continuation = continuation
    }
    func armDeadline() {
        lock.lock()
        if cleanup == nil {
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.timeout()
            }
        }
        lock.unlock()
    }
    func install(_ reader: Task<Void, Never>) {
        lock.lock(); let closed = cleanup != nil
        if !closed { self.reader = reader }
        lock.unlock()
        if closed { reader.cancel() }
    }
    private func timeout() {
        lock.lock(); let expire = !received && cleanup == nil
        if expire { expired = true }
        lock.unlock()
        if expire { continuation.finish(throwing: HerdrLineStreamError.timedOut); _ = stop() }
    }
    private func emit(_ line: Data) throws {
        lock.lock(); let closed = cleanup != nil || expired; received = true
        let deadline = deadline; self.deadline = nil; lock.unlock()
        deadline?.cancel()
        guard !closed else { throw CancellationError() }
        switch continuation.yield(line) {
        case .enqueued: break
        case .dropped: throw HerdrLineStreamError.slowConsumer
        case .terminated: throw CancellationError()
        @unknown default: throw HerdrLineStreamError.closed
        }
    }
    func read() async {
        var parser = BoundedHostLines()
        do {
            while let bytes = try await transport.read() {
                try Task.checkCancellation()
                try parser.append(bytes) { try emit($0) }
            }
            if parser.hasIncompleteLine { throw HerdrLineStreamError.closed }
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
    @discardableResult func stop() -> Task<Void, Error> {
        lock.lock()
        if let cleanup { lock.unlock(); return cleanup }
        let transport = transport
        let cleanup = Task { try await transport.close() }; self.cleanup = cleanup
        let reader = reader, deadline = deadline; self.reader = nil; self.deadline = nil
        lock.unlock()
        reader?.cancel(); deadline?.cancel()
        continuation.finish(throwing: HerdrLineStreamError.closed)
        return cleanup
    }
}
