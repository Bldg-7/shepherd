import Foundation
import AgentProxyProtocol

/// Synchronous, bounded decompression supplied by the recorder host. Emit small
/// chunks, reject excessive decoder windows, and throw on truncated/trailing
/// input in finish. The core never changes the independent forwarding stream.
public protocol CaptureDecompressor: AnyObject {
    func append(_ bytes: Data, emit: (Data) throws -> Void) throws
    func finish(emit: (Data) throws -> Void) throws
}

/// Serialized tee ingestion into memory-only conversations. No file I/O,
/// credentials, raw error logging, timers, sockets or model calls. Invoke on one
/// recorder queue. Snapshot/subscriber encoding must be separately admitted.
///
/// Accounting reserves framing, reconciliation metadata, per-exchange decoder/
/// parser/mutation workspace and 4x request bytes before buffering. It includes
/// retained store cost but is NOT an allocator/process RSS guarantee. Pressure
/// evicts oldest history and its owned streams, or drops capture without ever
/// holding up the forwarder. Limits are trusted process configuration, not RPC.
public final class ConversationCapture {
    public struct Limits {
        public let totalBytes: Int
        public let fixedBytes: Int
        public let workingBytes: Int
        public let exchanges: Int
        public let requestBytes: Int
        public let store: ConversationStore.Limits
        public init(totalBytes: Int = 128 << 20, fixedBytes: Int = 20 << 20,
                    workingBytes: Int = 16 << 20, exchanges: Int = 64,
                    requestBytes: Int = ConversationCaptureLimits.decompressedRequest,
                    store: ConversationStore.Limits = .init()) {
            precondition(totalBytes > 0 && totalBytes <= ConversationCaptureLimits.allConversations)
            precondition(fixedBytes >= 0 && workingBytes > 0 && fixedBytes <= totalBytes - workingBytes)
            precondition(exchanges > 0 && exchanges <= 64)
            precondition(requestBytes > 0 && requestBytes <= ConversationCaptureLimits.decompressedRequest)
            self.totalBytes = totalBytes; self.fixedBytes = fixedBytes; self.workingBytes = workingBytes
            self.exchanges = exchanges; self.requestBytes = requestBytes; self.store = store
        }
    }
    public enum DropReason: Hashable { case admission, metadata, ordering, unsupported, malformed, transport, evicted }
    private enum Failure: Error { case invalid, unsupported, admission, oversized }
    private final class Exchange {
        let open: AgentProxyTeeFrame.Open
        var body: BoundedCaptureBody
        var codec: (any CaptureDecompressor)?
        var requestEnded = false
        var awaitingMainAdmission = false
        var pendingMainResume: (() -> Void)?
        var responseStarted = false
        var decodedResponseBytes = 0
        var wireBytes = 0
        var main: ConversationReconciler.Ticket?
        var compact: ConversationReconciler.CompactionTicket?
        var child: ConversationReconciler.SubagentTicket?
        var decoder = ServerSentEventDecoder()
        var anthropic: AnthropicResponseAssembly?
        var responses: ResponsesAssembly?
        init(open: AgentProxyTeeFrame.Open, limit: Int, codec: (any CaptureDecompressor)?) {
            self.open = open; body = BoundedCaptureBody(maximumBytes: limit); self.codec = codec
        }
        var conversationID: String? { main?.conversationID ?? compact?.conversationID ?? child?.conversationID }
        func event(_ event: ServerSentEvent) { anthropic?.consume(event); responses?.consume(event) }
        var snapshot: CapturedResponse? { anthropic?.snapshot ?? responses?.snapshot }
    }
    public let limits: Limits
    public private(set) var reconciler: ConversationReconciler
    public private(set) var drops: [DropReason: Int] = [:]
    /// Optional host-owned asynchronous lookup before admitting a MAIN request.
    /// The host must invoke resume or cancel on this capture's owning queue.
    public var onMainAdmission: ((ConversationOwner, @escaping () -> Bool, @escaping () -> Bool, @escaping () -> Void, @escaping () -> Void) -> Bool)?
    private let makeDecoder: (String) -> (any CaptureDecompressor)?
    private var exchanges: [UInt64: Exchange] = [:]
    private var reservations: [UUID: Int] = [:]

    /// Host-only admission for client buffers and transient encoding. Tokens
    /// are bounded independently; never accept a requested size from the wire.
    public func reserve(bytes: Int) -> UUID? {
        guard bytes > 0, bytes <= limits.totalBytes, reservations.count < 32, makeRoom(bytes) else { return nil }
        let id = UUID(); reservations[id] = bytes; return id
    }
    public func release(_ id: UUID) { reservations.removeValue(forKey: id) }
    public var reservedBytes: Int { reservations.values.reduce(0, +) }
    // The forwarder allocates IDs and emits open synchronously on its one event
    // loop. Remember one watermark, not unbounded tombstones for dropped IDs.
    private var lastOpened: UInt64 = 0

    public init(limits: Limits = .init(), makeDecoder: @escaping (String) -> (any CaptureDecompressor)? = { _ in nil }) {
        self.limits = limits; self.makeDecoder = makeDecoder
        reconciler = ConversationReconciler(limits: limits.store)
    }
    /// Host must authorize the record against current route authority before
    /// calling. Reserve worst-case normalized import room without evicting live
    /// captures; low-memory imports are skipped rather than replacing them.
    public func restoreOne(_ record: ConversationStore.PersistentSnapshot.Record) -> String? {
        guard accountedBytes <= limits.totalBytes - min(limits.totalBytes, 8 << 20) else { return nil }
        return reconciler.restoreOne(record)
    }
    public var activeExchangeCount: Int { exchanges.count }
    public var bufferedRequestBytes: Int { exchanges.values.reduce(0) { $0 + $1.body.bufferedByteCount } }
    public var accountedBytes: Int {
        limits.fixedBytes + exchanges.count * limits.workingBytes + bufferedRequestBytes * 4 + reconciler.store.accountedBytes + reservedBytes
    }

    public func consume(_ frame: AgentProxyTeeFrame.Frame) {
        guard frame.payload.count <= AgentProxyTeeFrame.maximumPayloadBytes else { stop(frame.exchange, .malformed); return }
        if frame.kind == .open { open(frame); return }
        guard let exchange = exchanges[frame.exchange] else { return }
        // Never accumulate response bytes while disk I/O is pending. If the
        // response wins the race, continue live capture without importing over
        // it; the host keeps persistence blocked until it can safely map IDs.
        if exchange.awaitingMainAdmission {
            exchange.pendingMainResume?()
            guard exchanges[frame.exchange] === exchange else { return }
        }
        do {
            switch frame.kind {
            case .open, .routeSnapshot, .routeAcknowledgement: break
            case .requestBody:
                guard !exchange.requestEnded else { throw Failure.invalid }
                try wire(frame.payload.count, exchange)
                try decode(Data(frame.payload), exchange: exchange) { try self.requestBytes($0, exchange: exchange, id: frame.exchange) }
            case .requestEnd:
                guard !exchange.requestEnded, frame.payload.isEmpty else { throw Failure.invalid }
                try exchange.codec?.finish { try self.requestBytes($0, exchange: exchange, id: frame.exchange) }
                exchange.codec = nil
                guard let body = exchange.body.finish() else { throw Failure.invalid }
                exchange.requestEnded = true
                let classification = RequestClassification.classify(exchange.open, body: body)
                switch classification.kind {
                case .main:
                    guard let provider = classification.provider else { throw Failure.invalid }
                    let projection = try RequestProjection.project(body, provider: provider)
                    guard let owner = ConversationOwner(classification: classification) else { throw Failure.invalid }
                    let id = frame.exchange
                    exchange.awaitingMainAdmission = true
                    let current = { [weak self, weak exchange] in
                        guard let self, let exchange else { return false }
                        return self.exchanges[id] === exchange && exchange.awaitingMainAdmission
                    }
                    let live = { [weak self, weak exchange] in
                        guard let self, let exchange, self.exchanges[id] === exchange, let ticket = exchange.main else { return false }
                        return self.reconciler.isCurrentMain(ticket)
                    }
                    let resume = { [weak self, weak exchange] in
                        guard let self, let exchange, self.exchanges[id] === exchange, exchange.awaitingMainAdmission else { return }
                        exchange.awaitingMainAdmission = false
                        exchange.pendingMainResume = nil
                        do {
                            let begin = try self.reconciler.beginMain(classification: classification, request: projection)
                            exchange.main = begin.ticket
                            self.evicted(begin.evictedConversationIDs)
                            self.balance()
                        } catch { self.stop(id, .malformed) }
                    }
                    let cancel: () -> Void = { [weak self, weak exchange] in
                        guard let self, let exchange, self.exchanges[id] === exchange, exchange.awaitingMainAdmission else { return }
                        self.stop(id, .admission)
                    }
                    exchange.pendingMainResume = resume
                    if onMainAdmission?(owner, current, live, resume, cancel) != true { resume() }
                case .subagent:
                    guard let ticket = try reconciler.beginSubagent(classification: classification, requestBody: body) else { throw Failure.unsupported }
                    exchange.child = ticket
                case .compaction:
                    guard let ticket = reconciler.beginCompaction(classification: classification) else { throw Failure.unsupported }
                    exchange.compact = ticket
                default: throw Failure.unsupported
                }
                if classification.provider == .anthropic { exchange.anthropic = AnthropicResponseAssembly() }
                else { exchange.responses = ResponsesAssembly() }
            case .responseHead:
                guard exchange.requestEnded, !exchange.responseStarted else { throw Failure.invalid }
                let data = Data(frame.payload)
                _ = try RequestProjection.decodeObject(data)
                let head = try JSONDecoder().decode(AgentProxyTeeFrame.ResponseHead.self, from: data)
                let headers = try Self.headers(head.headers, response: true)
                guard (200..<300).contains(head.status), Self.mediaType(headers["content-type"]) == "text/event-stream" else { throw Failure.unsupported }
                exchange.codec = try codec(headers["content-encoding"])
                exchange.responseStarted = true
            case .responseBody:
                guard exchange.responseStarted else { throw Failure.invalid }
                try wire(frame.payload.count, exchange)
                try decode(Data(frame.payload), exchange: exchange) { try self.responseBytes($0, exchange: exchange) }
                if let snapshot = exchange.snapshot, let ticket = exchange.main {
                    if let applied = try reconciler.apply(snapshot, ticket: ticket) { evicted(applied.evictedConversationIDs) }
                    else { stop(frame.exchange, .evicted); return }
                }
            case .end:
                _ = try RequestProjection.decodeObject(Data(frame.payload))
                let end = try JSONDecoder().decode(AgentProxyTeeFrame.End.self, from: Data(frame.payload))
                var complete = end.outcome == .complete && exchange.responseStarted
                if complete {
                    do { try exchange.codec?.finish { try self.responseBytes($0, exchange: exchange) } }
                    catch { complete = false }
                }
                finish(frame.exchange, complete: complete)
                if !complete { count(.transport) }
            }
            balance()
        } catch Failure.admission { stop(frame.exchange, .admission) }
        catch Failure.unsupported { stop(frame.exchange, .unsupported) }
        catch { stop(frame.exchange, .malformed) }
    }

    /// Discard the current in-memory capture epoch and in-flight exchanges.
    /// The caller must separately fence queued tee opens, pending disk writes,
    /// read clients, and the authenticated administrative clear transaction.
    /// Keeping the open watermark prevents already-observed IDs from reopening.
    public func invalidateForClear() {
        exchanges.removeAll()
        reconciler = ConversationReconciler(limits: limits.store)
    }

    /// Called if the tee ends without per-exchange End frames. No partial
    /// request is parsed; visible responses are finalized as incomplete.
    public func finishAll() {
        for id in Array(exchanges.keys) { stop(id, .transport) }
    }

    private func open(_ frame: AgentProxyTeeFrame.Frame) {
        guard frame.exchange > lastOpened else { stop(frame.exchange, .ordering); return }
        lastOpened = frame.exchange
        do {
            let data = Data(frame.payload)
            _ = try RequestProjection.decodeObject(data)
            let raw = try JSONDecoder().decode(AgentProxyTeeFrame.Open.self, from: data)
            let headers = try Self.headers(raw.headers, response: false)
            guard let identity = raw.routeIdentity,
                  [raw.routeID, identity.session, identity.paneID, identity.terminalID, identity.cliVersion]
                    .allSatisfy({ RequestProjection.identifier($0) != nil }), raw.method == "POST",
                  (raw.upstream == "anthropic" && raw.path == "/v1/messages") ||
                  (raw.upstream == "chatgpt" && raw.path == "/backend-api/codex/responses") ||
                  (raw.upstream == "openai" && identity.kind == .pi && raw.path == "/v1/responses") else { throw Failure.unsupported }
            guard headers["content-type"] == nil || Self.mediaType(headers["content-type"]) == "application/json" else { throw Failure.unsupported }
            // Reapply the exact allowlist even if a malformed sender included a
            // credential header; never retain arbitrary raw Open header maps.
            let sanitized = AgentProxyTeeFrame.Open(routeID: raw.routeID, upstream: raw.upstream, method: raw.method,
                path: raw.path, headers: headers.map { [$0.key, $0.value] }, routeIdentity: raw.routeIdentity)
            guard exchanges.count < limits.exchanges, makeRoom(limits.workingBytes) else { throw Failure.admission }
            let decoder = try codec(headers["content-encoding"])
            exchanges[frame.exchange] = Exchange(open: sanitized, limit: limits.requestBytes, codec: decoder)
        } catch Failure.admission { count(.admission) }
        catch Failure.unsupported { count(.unsupported) }
        catch { count(.metadata) }
    }

    private func wire(_ bytes: Int, _ exchange: Exchange) throws {
        guard bytes <= AgentProxyTeeFrame.exchangeLimitBytes - exchange.wireBytes else { throw Failure.oversized }
        exchange.wireBytes += bytes
    }
    private func codec(_ value: String?) throws -> (any CaptureDecompressor)? {
        let encoding = value?.lowercased().trimmingCharacters(in: .whitespaces) ?? "identity"
        if encoding == "identity" { return nil }
        guard let decoder = makeDecoder(encoding) else { throw Failure.unsupported }
        return decoder
    }
    private func decode(_ bytes: Data, exchange: Exchange, emit: (Data) throws -> Void) throws {
        if let codec = exchange.codec { try codec.append(bytes, emit: emit) }
        else { try emit(bytes) }
    }
    private func requestBytes(_ bytes: Data, exchange: Exchange, id: UInt64) throws {
        guard bytes.count <= AgentProxyTeeFrame.maximumPayloadBytes,
              bytes.count <= limits.requestBytes - exchange.body.bufferedByteCount else { throw Failure.oversized }
        guard makeRoom(bytes.count * 4), exchanges[id] === exchange else { throw Failure.admission }
        guard exchange.body.append(bytes) else { throw Failure.oversized }
    }
    private func responseBytes(_ bytes: Data, exchange: Exchange) throws {
        guard bytes.count <= AgentProxyTeeFrame.maximumPayloadBytes,
              bytes.count <= ConversationCaptureLimits.decompressedRequest - exchange.decodedResponseBytes else { throw Failure.oversized }
        exchange.decodedResponseBytes += bytes.count
        try exchange.decoder.append(bytes) { exchange.event($0) }
        if exchange.snapshot?.status == .incomplete { throw Failure.invalid }
    }

    private func finish(_ id: UInt64, complete: Bool) {
        guard let exchange = exchanges.removeValue(forKey: id) else { return }
        exchange.codec = nil; exchange.decoder.finish()
        exchange.anthropic?.finish(transportComplete: complete)
        exchange.responses?.finish(transportComplete: complete)
        guard let snapshot = exchange.snapshot else { return }
        do {
            if let ticket = exchange.main {
                if let update = try reconciler.apply(snapshot, ticket: ticket, finished: true) { evicted(update.evictedConversationIDs) }
            } else if let ticket = exchange.child {
                if let update = try reconciler.completeSubagent(snapshot, ticket: ticket, transportComplete: complete) { evicted(update.evictedConversationIDs) }
            } else if let ticket = exchange.compact {
                if let update = try reconciler.completeCompaction(snapshot, ticket: ticket, transportComplete: complete) { evicted(update.evictedConversationIDs) }
            }
        } catch { count(.malformed) }
        balance()
    }
    private func stop(_ id: UInt64, _ reason: DropReason) { count(reason); finish(id, complete: false) }
    private func count(_ reason: DropReason) {
        let old = drops[reason, default: 0]
        if old < Int.max { drops[reason] = old + 1 }
    }
    private func evicted(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let removed = Set(ids)
        for (id, exchange) in exchanges where exchange.conversationID.map({ removed.contains($0) }) == true {
            exchanges.removeValue(forKey: id); count(.evicted)
        }
    }
    private func makeRoom(_ bytes: Int) -> Bool {
        guard bytes <= limits.totalBytes - limits.fixedBytes else { return false }
        while accountedBytes > limits.totalBytes - bytes {
            let ids = reconciler.evictOldest()
            guard !ids.isEmpty else { return false }
            evicted(ids)
        }
        return true
    }
    private func balance() {
        let stale = exchanges.values.compactMap(\.conversationID).filter { reconciler.store.read(id: $0) == nil }
        evicted(stale)
        _ = makeRoom(0)
    }
    private static func mediaType(_ value: String?) -> String? {
        value?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
    }
    private static func headers(_ pairs: [[String]], response: Bool) throws -> [String: String] {
        guard pairs.count <= 64 else { throw Failure.invalid }
        var values: [String: String] = [:]
        for pair in pairs {
            guard pair.count == 2, pair[0].utf8.count <= 128 else { throw Failure.invalid }
            let name = pair[0].lowercased()
            guard response ? AgentProxyTeeFrame.allowedResponseHeader(name) : AgentProxyTeeFrame.allowedRequestHeader(name) else { continue }
            guard pair[1].utf8.count <= 4096, values[name] == nil,
                  !pair[1].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalid }
            values[name] = pair[1]
        }
        return values
    }
}
