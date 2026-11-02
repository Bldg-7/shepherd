import Foundation

/// Live channel-0 connection for bounded request/response RPCs. Owns one
/// transport and one epoch; no reconnect or retry. Streaming methods are
/// explicitly refused until attach/event channel ownership is implemented.
public actor CoreRPCConnection {
    public enum State: Sendable { case idle, connecting, ready, closed }
    public struct Snapshot: Sendable {
        public let state: State
        public let awaitingReplies: Int
        public let occupiedRequestSlots: Int
        public let queuedWriteBytes: Int
    }
    public private(set) var state: State = .idle
    public private(set) var hello: CoreHello?
    public nonisolated let epoch: UUID
    private let transport: any CoreByteTransport
    private var decoder: CoreHandshakeDecoder
    private var requests: CoreRPCRequests
    private let maximumQueuedWriteBytes: Int
    private var handshake: CheckedContinuation<CoreHello, Error>?
    private var handshakeDeadline: ContinuousClock.Instant?
    private var waiters: [UInt64: CheckedContinuation<CoreRPCReply, Error>] = [:]
    private struct Write: Sendable {
        let bytes: Data
        let token: CoreRPCRequests.Token?
        let deadline: ContinuousClock.Instant
    }
    private var writes: [Write] = []
    private var inFlight: Write?
    private var queuedWriteBytes = 0
    private var starter: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cleanup: Task<Void, Error>?

    public init(transport: any CoreByteTransport, requiredMethods: Set<String> = ["terminal.list"],
                maximumRequests: Int = 64, maximumPendingPayloadBytes: Int = 1 << 20,
                maximumQueuedWriteBytes: Int = 2 << 20) throws {
        guard (1...(32 << 20)).contains(maximumQueuedWriteBytes) else { throw CoreRPCFailure.invalidLimits }
        self.transport = transport
        self.maximumQueuedWriteBytes = maximumQueuedWriteBytes
        requests = try CoreRPCRequests(maximumRequests: maximumRequests, maximumPendingPayloadBytes: maximumPendingPayloadBytes)
        epoch = requests.epoch
        decoder = CoreHandshakeDecoder(requiredMethods: requiredMethods)
    }

    deinit {
        starter?.cancel(); reader?.cancel(); writer?.cancel(); timer?.cancel()
        let transport = transport
        if cleanup == nil { Task { try? await transport.close() } }
    }

    public func connect(timeout: Duration = .seconds(10)) async throws -> CoreHello {
        try Task.checkCancellation()
        try validate(timeout)
        guard state == .idle else { throw CoreConnectionFailure.alreadyStarted }
        state = .connecting
        handshakeDeadline = .now.advanced(by: timeout)
        return try await withTaskCancellationHandler {
            do {
                let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<CoreHello, Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()); fail(CancellationError()); return }
                    handshake = c; scheduleTimer()
                    let transport = transport
                    starter = Task.detached { [weak self] in
                        do { try await transport.start(); await self?.transportStarted() }
                        catch { await self?.transportFailed(error) }
                    }
                }
                try Task.checkCancellation()
                return result
            } catch {
                // A failed/canceled handshake must await owned-child cleanup.
                try await close()
                throw error
            }
        } onCancel: { Task { await self.fail(CancellationError()) } }
    }

    /// A timeout/cancellation says only that this caller stopped waiting.
    /// A mutating command may already have run; it is never replayed here.
    public func call(_ method: String, parameters: Data = Data("{}".utf8),
                     timeout: Duration = .seconds(30)) async throws -> CoreRPCReply {
        try Task.checkCancellation(); try validate(timeout)
        guard state == .ready, let hello else { throw CoreConnectionFailure.notReady }
        guard method != "hello" else { throw CoreConnectionFailure.reservedMethod }
        guard method != "terminal.attach", method != "events.subscribe" else { throw CoreConnectionFailure.streamingNotSupported }
        guard hello.methods.contains(method) else { throw CoreConnectionFailure.methodUnavailable }
        let request = try requests.begin(method: method, parameters: parameters, deadline: .now.advanced(by: timeout))
        let token = request.context.token
        return try await withTaskCancellationHandler {
            do {
                return try await withCheckedThrowingContinuation { c in
                    if Task.isCancelled {
                        requests.discardUnsent(token); c.resume(throwing: CancellationError()); return
                    }
                    waiters[token.id] = c
                    do {
                        try enqueue(Write(bytes: request.frame.encoded(), token: token, deadline: request.context.deadline))
                        scheduleTimer()
                    } catch {
                        requests.discardUnsent(token)
                        waiters.removeValue(forKey: token.id)?.resume(throwing: error)
                    }
                }
            } catch {
                if state == .closed { try await close() }
                throw error
            }
        } onCancel: { Task { await self.cancel(token) } }
    }

    public func close() async throws {
        fail(CoreConnectionFailure.closed)
        try await cleanup?.value
    }

    public func snapshot() -> Snapshot {
        Snapshot(state: state, awaitingReplies: waiters.count,
                 occupiedRequestSlots: requests.occupiedSlots, queuedWriteBytes: queuedWriteBytes)
    }

    private func validate(_ timeout: Duration) throws {
        guard timeout > .zero, timeout <= .seconds(3600) else { throw CoreConnectionFailure.invalidTimeout }
    }
    private func transportStarted() {
        guard state == .connecting else { return }
        let transport = transport
        reader = Task.detached { [weak self] in
            do {
                while let bytes = try await transport.read() {
                    try Task.checkCancellation()
                    await self?.receive(bytes)
                }
                await self?.endOfInput()
            } catch { await self?.transportFailed(error) }
        }
        do { try enqueue(Write(bytes: decoder.request(), token: nil, deadline: handshakeDeadline ?? .now)) }
        catch { fail(error) }
    }
    private func enqueue(_ write: Write) throws {
        guard write.bytes.count <= maximumQueuedWriteBytes - queuedWriteBytes else { throw CoreConnectionFailure.writeLimitExceeded }
        writes.append(write); queuedWriteBytes += write.bytes.count
        guard writer == nil else { return }
        let transport = transport
        writer = Task.detached { [weak self] in
            while let item = await self?.nextWrite() {
                do { try await transport.write(item.bytes); await self?.written(item) }
                catch { await self?.transportFailed(error); return }
            }
        }
    }
    private func nextWrite() -> Write? {
        while state != .closed, !writes.isEmpty {
            let next = writes.removeFirst()
            // The timer may not have run yet. Never START writing an already
            // expired queued operation. In-flight frames still finish intact.
            if next.deadline <= .now {
                queuedWriteBytes -= next.bytes.count
                if let token = next.token {
                    requests.discardUnsent(token)
                    waiters.removeValue(forKey: token.id)?.resume(throwing: CoreConnectionFailure.requestTimedOut)
                    scheduleTimer()
                    continue
                }
                fail(CoreConnectionFailure.handshakeTimedOut); return nil
            }
            inFlight = next
            return next
        }
        writer = nil
        return nil
    }
    private func written(_ item: Write) {
        guard state != .closed else { return }
        queuedWriteBytes -= item.bytes.count; inFlight = nil
    }
    private func removeQueued(_ token: CoreRPCRequests.Token) -> Bool {
        guard let index = writes.firstIndex(where: { $0.token == token }) else { return false }
        queuedWriteBytes -= writes.remove(at: index).bytes.count
        requests.discardUnsent(token)
        return true
    }
    private func cancel(_ token: CoreRPCRequests.Token) {
        guard state == .ready, token.epoch == epoch else { return }
        if !removeQueued(token) { requests.cancel(token) }
        waiters.removeValue(forKey: token.id)?.resume(throwing: CancellationError())
        // Never cancel the writer for one RPC: finish an in-flight frame.
        scheduleTimer()
    }
    private func scheduleTimer() {
        timer?.cancel(); timer = nil
        guard let deadline = state == .connecting ? handshakeDeadline : requests.nextDeadline, state != .closed else { return }
        timer = Task.detached { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            await self?.expired()
        }
    }
    private func expired() {
        let now = ContinuousClock.now
        if state == .connecting, let deadline = handshakeDeadline, now >= deadline {
            fail(CoreConnectionFailure.handshakeTimedOut); return
        }
        for context in requests.expire(at: now) {
            _ = removeQueued(context.token)
            waiters.removeValue(forKey: context.token.id)?.resume(throwing: CoreConnectionFailure.requestTimedOut)
        }
        scheduleTimer()
    }
    private func receive(_ bytes: Data) {
        guard state != .closed else { return }
        do {
            var accepted: CoreHello?
            // Callbacks touch request state, not the decoder itself.
            try decoder.receive(bytes, onHello: { accepted = $0 }, onFrame: { try receiveFrame($0) })
            if let accepted {
                guard state == .connecting, let deadline = handshakeDeadline, ContinuousClock.now < deadline else {
                    throw CoreConnectionFailure.handshakeTimedOut
                }
                hello = accepted; state = .ready; handshakeDeadline = nil
                handshake?.resume(returning: accepted); handshake = nil
            }
            scheduleTimer()
        } catch { fail(error) }
    }
    private func receiveFrame(_ frame: CoreFrame) throws {
        guard frame.channel == 0 else { throw CoreConnectionFailure.streamingNotSupported }
        switch try requests.receive(frame, from: epoch, at: .now) {
        case .reply(let context, let reply):
            waiters.removeValue(forKey: context.token.id)?.resume(returning: reply)
        case .late(let context, _, let reason):
            // Only non-streaming RPCs can be issued by this connection yet.
            let error: any Error = reason == .cancelled ? CancellationError() : CoreConnectionFailure.requestTimedOut
            waiters.removeValue(forKey: context.token.id)?.resume(throwing: error)
        }
    }
    private func endOfInput() {
        guard state != .closed else { return }
        do { try decoder.finish(); fail(CoreConnectionFailure.closed) }
        catch { fail(error) }
    }
    private func transportFailed(_ error: any Error) {
        if error is CancellationError { fail(CancellationError()) }
        else if let error = error as? CoreProcessFailure { fail(error) }
        else { fail(CoreConnectionFailure.transportFailed) }
    }
    private func fail(_ error: any Error) {
        guard state != .closed else { return }
        state = .closed; hello = nil
        decoder = CoreHandshakeDecoder(requiredMethods: decoder.requiredMethods)
        starter?.cancel(); starter = nil; reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil; timer?.cancel(); timer = nil
        handshake?.resume(throwing: error); handshake = nil; handshakeDeadline = nil
        for c in waiters.values { c.resume(throwing: error) }
        waiters.removeAll(); _ = requests.close()
        writes.removeAll(); inFlight = nil; queuedWriteBytes = 0
        let transport = transport
        cleanup = Task.detached { try await transport.close() }
    }
}
