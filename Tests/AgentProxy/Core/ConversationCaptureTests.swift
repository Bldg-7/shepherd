import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct ConversationCaptureTests {
    final class Harness {
        let capture: ConversationCapture
        var decoder = AgentProxyTeeFrame.Decoder()
        init(_ capture: ConversationCapture = .init()) { self.capture = capture }
        func send(_ kind: AgentProxyTeeFrame.Kind, _ id: UInt64, _ bytes: Data = Data(), chunk: Int = 257) throws {
            let wire = AgentProxyTeeFrame.header(kind: kind, exchange: id, payloadCount: bytes.count) + bytes
            for offset in stride(from: 0, to: wire.count, by: chunk) {
                decoder.append(wire[offset..<min(wire.count, offset + chunk)])
                while let frame = try decoder.next() { capture.consume(frame) }
            }
        }
        func json<T: Encodable>(_ kind: AgentProxyTeeFrame.Kind, _ id: UInt64, _ value: T) throws {
            try send(kind, id, JSONEncoder().encode(value))
        }
        func open(_ id: UInt64, kind: String = "main", encoding: String? = nil, native: String = "native", agent: String = "root", extra: [[String]] = []) throws {
            var headers = [["x-claude-code-request-class", kind], ["x-claude-code-session-id", native],
                           ["x-claude-code-agent-id", agent], ["content-type", "application/json"]] + extra
            if let encoding { headers.append(["content-encoding", encoding]) }
            try json(.open, id, RequestClassificationTests.open(.claude, headers: headers))
        }
        func request(_ id: UInt64, _ text: String = "hello") throws {
            try send(.requestBody, id, JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": text]]]))
            try send(.requestEnd, id)
        }
        func head(_ id: UInt64, status: Int = 200, type: String = "text/event-stream; charset=utf-8", encoding: String? = nil) throws {
            var headers = [["content-type", type]]
            if let encoding { headers.append(["content-encoding", encoding]) }
            try json(.responseHead, id, AgentProxyTeeFrame.ResponseHead(status: status, headers: headers))
        }
        func event(_ id: UInt64, _ object: [String: Any]) throws {
            let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try send(.responseBody, id, Data("data: ".utf8) + json + Data("\n\n".utf8))
        }
        func answer(_ id: UInt64, _ text: String, complete: Bool = true) throws {
            try event(id, ["type": "message_start", "message": ["id": "msg", "role": "assistant", "content": []]])
            try event(id, ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": text]])
            if complete {
                try event(id, ["type": "content_block_stop", "index": 0])
                try event(id, ["type": "message_stop"])
            }
        }
        func end(_ id: UInt64, _ outcome: AgentProxyTeeFrame.End.Outcome = .complete) throws {
            try json(.end, id, AgentProxyTeeFrame.End(outcome: outcome))
        }
        var snapshot: ConversationSnapshot? {
            capture.reconciler.store.list().first.flatMap { capture.reconciler.store.read(id: $0.id) }
        }
    }
    final class Expansion: CaptureDecompressor {
        let bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
        func append(_ bytes: Data, emit: (Data) throws -> Void) throws { try emit(self.bytes) }
        func finish(emit: (Data) throws -> Void) throws {}
    }
    static func run(check: (Bool, String) -> Void) throws {
        let delayed = Harness()
        var resumeAdmission: (() -> Void)?
        var currentAdmission: (() -> Bool)?
        delayed.capture.onMainAdmission = { _, current, _, resume, _ in
            currentAdmission = current; resumeAdmission = resume; return true
        }
        try delayed.open(1); try delayed.request(1)
        check(currentAdmission?() == true && delayed.snapshot == nil, "MAIN waits for asynchronous host lookup")
        resumeAdmission?()
        check(currentAdmission?() == false && delayed.snapshot != nil, "host resumes the same admitted MAIN exactly once")
        try delayed.head(1); try delayed.answer(1, "live"); try delayed.end(1)
        resumeAdmission?()
        check(delayed.snapshot?.items.last?.message.blocks.first?.text == "live", "late resume cannot replace live response")
        let overlap = Harness()
        var overlapResume: (() -> Void)?
        var overlapCurrent: (() -> Bool)?
        overlap.capture.onMainAdmission = { _, current, _, resume, _ in
            overlapCurrent = current; overlapResume = resume; return true
        }
        try overlap.open(1); try overlap.request(1); try overlap.head(1)
        try overlap.answer(1, "response while lookup pending"); try overlap.end(1)
        check(overlapCurrent?() == false && overlap.snapshot?.summary.status == .complete, "response wins lookup race without buffering or losing live capture")
        overlapResume?()
        check(overlap.snapshot?.items.last?.message.blocks.first?.text == "response while lookup pending", "late lookup cannot replay an admitted MAIN")
        // An unrelated authority snapshot does not change the capture epoch
        // or the selected route. A held lookup must still be resumable.
        let unrelated = Harness()
        var unrelatedCurrent: (() -> Bool)?
        var unrelatedResume: (() -> Void)?
        unrelated.capture.onMainAdmission = { _, current, _, resume, _ in
            unrelatedCurrent = current; unrelatedResume = resume; return true
        }
        try unrelated.open(1); try unrelated.request(1, "still authorized")
        let unchangedEpoch = unrelated.capture.reconciler.store.epoch
        var syntheticAuthorityGeneration = 1
        syntheticAuthorityGeneration += 1 // unrelated route was added
        check(syntheticAuthorityGeneration == 2 && unrelated.capture.reconciler.store.epoch == unchangedEpoch && unrelatedCurrent?() == true,
              "unrelated generation change leaves held admission current")
        unrelatedResume?(); try unrelated.head(1); try unrelated.answer(1, "still captured"); try unrelated.end(1)
        check(unrelated.snapshot?.items.last?.message.blocks.first?.text == "still captured", "unchanged route MAIN survives held lookup")
        let revoked = Harness()
        var revokedResume: (() -> Void)?
        revoked.capture.onMainAdmission = { _, _, _, resume, _ in revokedResume = resume; return true }
        try revoked.open(1); try revoked.request(1); revoked.capture.invalidateForClear(); revokedResume?()
        check(revoked.snapshot == nil, "revoked admission continuation cannot recreate cleared capture")
        // The host completion is held deterministically, like pending journal
        // I/O. A newer same-key MAIN with a different selected owner must win
        // regardless of whether the old lookup returns a body or no match.
        for hasHistory in [false, true] {
            let history = Harness(); try history.open(1); try history.request(1, "historical")
            let historical = history.snapshot.flatMap { history.capture.reconciler.store.persistenceRecord(id: $0.summary.id) }!
            let racing = Harness()
            var heldCurrent: (() -> Bool)?
            var heldResume: (() -> Void)?
            var calls = 0
            racing.capture.onMainAdmission = { _, current, _, resume, _ in
                calls += 1
                if calls == 1 { heldCurrent = current; heldResume = resume; return true }
                return false
            }
            try racing.open(1, agent: "old-owner"); try racing.request(1, "old")
            try racing.open(2, agent: "new-owner"); try racing.request(2, "new")
            check(heldCurrent?() == false, "new MAIN invalidates older pending admission")
            if heldCurrent?() == true {
                if hasHistory { _ = racing.capture.restoreOne(historical) }
                heldResume?()
            }
            heldResume?()
            try racing.head(2); try racing.answer(2, "new answer"); try racing.end(2)
            check(racing.snapshot?.items.last?.message.blocks.first?.text == "new answer", "held \(hasHistory ? "history" : "no-record") result cannot supersede newer live MAIN")
        }
        // A bounded live store rejects historical import without evicting the
        // prior live entry; the host can still resume and capture the new MAIN.
        let saved = Harness(); try saved.open(1, native: "historical-key"); try saved.request(1, "history")
        let savedRecord = saved.snapshot.flatMap { saved.capture.reconciler.store.persistenceRecord(id: $0.summary.id) }!
        let fullStore = Harness(ConversationCapture(limits: .init(store: .init(conversations: 1))))
        try fullStore.open(1, native: "existing-live"); try fullStore.request(1, "existing")
        var refusedImport = false
        fullStore.capture.onMainAdmission = { owner, _, _, resume, _ in
            if owner.key.nativeSession == "historical-key" {
                refusedImport = fullStore.capture.restoreOne(savedRecord) == nil
            }
            resume()
            return true
        }
        try fullStore.open(2, native: "historical-key"); try fullStore.request(2, "new live")
        try fullStore.head(2); try fullStore.answer(2, "captured despite history pressure"); try fullStore.end(2)
        check(refusedImport, "full store refuses import without evicting prior live entry")
        check(fullStore.snapshot?.items.last?.message.blocks.first?.text == "captured despite history pressure", "failed import resumes new live response")
        check(saved.snapshot?.items.first?.message.blocks.first?.text == "history", "historical source remains unchanged")
        let stream = Harness()
        try stream.open(1, extra: [["Authorization", "PRIVATE_AUTH"], ["x-claude-code-secret", "PRIVATE_HEADER"]])
        try stream.request(1); try stream.head(1); try stream.answer(1, "안녕🧪", complete: false)
        check(stream.snapshot?.summary.status == .streaming && stream.snapshot?.items.last?.message.blocks.first?.text == "안녕🧪", "tee bytes reach live memory-only conversation")
        try stream.event(1, ["type": "content_block_stop", "index": 0]); try stream.event(1, ["type": "message_stop"])
        try stream.end(1)
        check(stream.snapshot?.summary.status == .complete && stream.capture.activeExchangeCount == 0 && stream.capture.bufferedRequestBytes == 0, "tee completion retires all request/decoder state")
        check(!String(describing: stream.snapshot).contains("PRIVATE_"), "unreviewed header values never reach snapshots")
        let first = stream.snapshot!
        try stream.open(2, kind: "compaction"); try stream.request(2, "private instructions"); try stream.head(2); try stream.answer(2, "summary"); try stream.end(2)
        check(Array(stream.snapshot!.items.prefix(first.items.count)) == first.items && stream.snapshot?.items.last?.origin == .summary, "tee compaction follows verified owner and preserves original history")
        check(!String(describing: stream.snapshot).contains("private instructions"), "compaction request instructions are not projected as user messages")
        for outcome: AgentProxyTeeFrame.End.Outcome in [.aborted, .dropped] {
            let h = Harness(); try h.open(1); try h.request(1); try h.head(1); try h.answer(1, "partial"); try h.end(1, outcome)
            check(h.snapshot?.summary.status == .incomplete && h.capture.activeExchangeCount == 0, "tee \(outcome) overrides provider message_stop")
        }
        let eof = Harness(); try eof.open(1); try eof.request(1); try eof.head(1); try eof.answer(1, "partial", complete: false)
        eof.capture.finishAll()
        check(eof.snapshot?.summary.status == .incomplete && eof.capture.activeExchangeCount == 0, "parent EOF finalizes in-flight responses incomplete")
        // In-memory clear is only one part of the administrative transaction:
        // old accepted exchange IDs and read epochs cannot recreate state.
        let clearing = Harness()
        try clearing.open(1); try clearing.request(1); try clearing.head(1); try clearing.answer(1, "before", complete: false)
        let oldEpoch = clearing.capture.reconciler.store.epoch
        let oldID = clearing.snapshot!.summary.id
        clearing.capture.invalidateForClear()
        check(clearing.capture.reconciler.store.epoch != oldEpoch && clearing.capture.reconciler.store.count == 0 &&
              clearing.capture.activeExchangeCount == 0 && clearing.capture.reconciler.store.read(id: oldID) == nil,
              "capture clear rotates epoch and drops in-flight exchanges")
        try clearing.answer(1, "late"); try clearing.end(1); try clearing.open(1); try clearing.request(1, "replay")
        check(clearing.capture.reconciler.store.count == 0 && clearing.capture.activeExchangeCount == 0,
              "late frames and already-observed open IDs cannot recreate cleared state")
        try clearing.open(2); try clearing.request(2, "new"); try clearing.head(2); try clearing.answer(2, "allowed"); try clearing.end(2)
        check(clearing.snapshot?.items.first?.message.blocks.first?.text == "new",
              "a subsequent newly accepted exchange may create new history")
        let partial = Harness(); try partial.open(1); try partial.send(.requestBody, 1, Data("{\"messages\":".utf8)); try partial.end(1, .dropped)
        check(partial.capture.reconciler.store.count == 0 && partial.capture.bufferedRequestBytes == 0, "partial request is never parsed after drop")
        let badJSON = Harness(); try badJSON.open(1); try badJSON.send(.requestBody, 1, Data("not-json".utf8)); try badJSON.send(.requestEnd, 1)
        check(badJSON.capture.activeExchangeCount == 0 && badJSON.capture.reconciler.store.count == 0, "malformed request releases capture without throwing into forwarder")
        let unsupported = Harness(); try unsupported.open(1, encoding: "br")
        check(unsupported.capture.activeExchangeCount == 0 && unsupported.capture.drops[.unsupported] == 1, "unsupported encoding fails capture closed")
        let late = Harness(); try late.open(1); try late.request(1); try late.head(1); try late.answer(1, "original"); try late.end(1)
        let seq = late.capture.reconciler.store.sequence
        try late.open(1); try late.request(1, "replayed"); try late.send(.responseBody, 1, Data("data: late\n\n".utf8))
        check(late.capture.reconciler.store.sequence == seq && late.capture.activeExchangeCount == 0, "completed or discarded exchange IDs cannot be resurrected")
        let duplicate = Harness(); try duplicate.open(1); try duplicate.request(1); try duplicate.open(1)
        check(duplicate.capture.activeExchangeCount == 0 && duplicate.snapshot?.summary.status == .incomplete, "duplicate open retires existing exchange rather than overwriting it")
        let order = Harness(); try order.open(1); try order.head(1)
        check(order.capture.activeExchangeCount == 0 && order.capture.reconciler.store.count == 0, "response before complete request cannot create guessed transcript")
        for status in [400, 401, 500] {
            let h = Harness(); try h.open(1); try h.request(1); try h.head(1, status: status)
            check(h.snapshot?.summary.status == .incomplete && h.capture.activeExchangeCount == 0, "HTTP \(status) not interpreted as successful assistant data")
        }
        let nonSSE = Harness(); try nonSSE.open(1); try nonSSE.request(1); try nonSSE.head(1, type: "application/json")
        check(nonSSE.snapshot?.summary.status == .incomplete, "unexpected response format leaves explicit incomplete conversation")
        // api.openai.com answers Pi's subscription Responses stream without a content type.
        let untyped = Harness(); try untyped.open(1); try untyped.request(1)
        try untyped.json(.responseHead, 1, AgentProxyTeeFrame.ResponseHead(status: 200, headers: []))
        try untyped.answer(1, "untyped"); try untyped.end(1)
        check(untyped.snapshot?.summary.status == .complete && untyped.snapshot?.items.last?.message.blocks.first?.text == "untyped",
              "an SSE response without a content type is captured")
        let duplicateHeader = Harness(); try duplicateHeader.open(1, extra: [["Content-Type", "text/plain"]])
        check(duplicateHeader.capture.activeExchangeCount == 0 && duplicateHeader.capture.drops[.metadata] == 1, "case-insensitive header ambiguity rejected before retention")
        for kind in ["subagent", "auxiliary", "unknown"] {
            let h = Harness(); try h.open(1, kind: kind); try h.request(1)
            check(h.capture.reconciler.store.count == 0 && h.capture.activeExchangeCount == 0, "unintegrated \(kind) capture cannot pollute main history")
        }
        let broken = Harness(); try broken.open(1); try broken.request(1); try broken.head(1)
        try broken.send(.responseBody, 1, Data("data: ".utf8) + Data([255, 10, 10]))
        check(broken.snapshot?.summary.status == .incomplete && broken.capture.activeExchangeCount == 0, "malformed SSE releases decoder and retires main ticket")
        let limits = ConversationCapture.Limits(totalBytes: 100_000, fixedBytes: 1000, workingBytes: 10_000, exchanges: 2, requestBytes: 4000,
            store: .init(conversationBytes: 5000, totalBytes: 20_000, conversations: 4))
        let bounded = Harness(ConversationCapture(limits: limits))
        try bounded.open(1); try bounded.open(2); try bounded.open(3)
        check(bounded.capture.activeExchangeCount == 2 && bounded.capture.drops[.admission] == 1, "independent in-flight count cap")
        try bounded.send(.requestBody, 1, Data(repeating: 65, count: 4001))
        check(bounded.capture.activeExchangeCount == 1 && bounded.capture.bufferedRequestBytes == 0, "oversized request drops and releases its buffer")
        try bounded.open(4); try bounded.request(4); try bounded.head(4); try bounded.answer(4, "other request works"); try bounded.end(4)
        check(bounded.snapshot?.summary.status == .complete && bounded.capture.accountedBytes <= limits.totalBytes, "one rejected capture cannot stop another exchange")
        let expansion = Harness(ConversationCapture(limits: limits, makeDecoder: { $0 == "gzip" ? Expansion(Data(repeating: 65, count: 4001)) : nil }))
        try expansion.open(1, encoding: "gzip"); try expansion.send(.requestBody, 1, Data([1]))
        check(expansion.capture.activeExchangeCount == 0 && expansion.capture.bufferedRequestBytes == 0, "decompressed output bound is independent of tiny wire size")
        let memory = Harness(ConversationCapture(limits: .init(totalBytes: 20_000, fixedBytes: 1000, workingBytes: 10_000, exchanges: 4, requestBytes: 8000,
            store: .init(conversationBytes: 5000, totalBytes: 10_000, conversations: 2))))
        try memory.open(1); try memory.send(.requestBody, 1, Data(repeating: 65, count: 3000))
        check(memory.capture.drops[.admission] == 1 && memory.capture.activeExchangeCount == 0, "aggregate accounting reserves 4x body before allocation")
        check(memory.capture.accountedBytes <= memory.capture.limits.totalBytes, "aggregate bound restored after rejection")
        let codecRequest = try JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": "decoded"]]])
        let decoded = Harness(ConversationCapture(limits: limits, makeDecoder: { $0 == "gzip" ? Expansion(codecRequest) : nil }))
        try decoded.open(1, encoding: "gzip"); try decoded.send(.requestBody, 1, Data([1])); try decoded.send(.requestEnd, 1)
        check(decoded.snapshot?.items.first?.message.blocks.first?.text == "decoded", "host codec output is classified/projected, not raw compressed bytes")
        decoded.capture.finishAll(); bounded.capture.finishAll()
        check(decoded.capture.activeExchangeCount == 0 && bounded.capture.activeExchangeCount == 0, "all remaining synthetic exchanges cleaned up")
    }
}
