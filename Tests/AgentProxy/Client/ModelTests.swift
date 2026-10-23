import Foundation
import ShepherdKit
import AgentProxyCore

actor ModelTransport: HerdrTransport {
    var store = ConversationStore()
    var subscriptions: [String: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    var cursors: [String: ConversationReadAPI.Cursor] = [:]
    var held: [(AsyncThrowingStream<Data, any Error>.Continuation, Data)] = []
    var holdNext = false
    var closeCount = 0
    func prepare(native: String, text: String) throws {
        let message = try RequestProjection.project(JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": text]]]), provider: .anthropic).messages[0]
        _ = try store.upsert(key: ConversationKey(agent: "claude", herdrSession: "default", nativeSession: native)!,
            context: ConversationContext(routeID: "route", paneID: "pane", terminalID: "terminal")!,
            items: [ConversationItem(id: native, message: message, origin: .observed, status: .complete)], status: .complete)
        for (id, cursor) in cursors {
            if let change = ConversationReadAPI.update(after: cursor, store: store) {
                cursors[id] = ConversationReadAPI.Cursor(change)
                subscriptions[id]?.yield(ConversationReadAPI.encodeUpdate(change))
            }
        }
    }
    func hold() { holdNext = true }
    func releaseHeld() {
        for (continuation, data) in held { continuation.yield(data); continuation.finish() }
        held.removeAll()
    }
    func heldCount() -> Int { held.count }
    func liveCount() -> Int { subscriptions.count }
    func close(_ id: String) { closeCount += 1; subscriptions.removeValue(forKey: id)?.finish(); cursors.removeValue(forKey: id) }
    func openLineStream(endpoint: HerdrLineEndpoint, request: Data) async throws -> HerdrLineStream {
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let id = object["id"] as! String
        let bytes = ConversationReadAPI.answer(request, store: store)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        if holdNext { holdNext = false; held.append((continuation, bytes)) }
        else {
            continuation.yield(bytes)
            if object["method"] as? String == "conversation.subscribe" {
                subscriptions[id] = continuation
                cursors[id] = ConversationReadAPI.Cursor(try ConversationReadAPI.decodeWire(ConversationReadAPI.Reply.self, from: bytes).result!)
            } else { continuation.finish() }
        }
        return HerdrLineStream(lines: stream, close: { Task { await self.close(id) } })
    }
}

@main struct ModelTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        func until(_ condition: () async -> Bool) async {
            let end = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await condition()) { precondition(ContinuousClock.now < end, "model event deadline"); await Task.yield() }
        }
        func selection(_ native: String) -> ConversationSelection {
            .init(terminalID: "terminal", herdrSession: "default", agent: "claude", nativeSession: native)
        }
        let transport = ModelTransport()
        try await transport.prepare(native: "one", text: "first")
        try await transport.prepare(native: "two", text: "second")
        let model = CapturedConversationModel()
        model.connect(transport: transport, selection: selection("one"))
        await until { model.hasConversation }
        check(model.window.items.first?.blocks.first?.text == "first", "model selects native identity rather than newest other session")
        model.prefersScreen = true
        try await transport.prepare(native: "one", text: "live")
        await until { model.window.items.first?.blocks.first?.text == "live" }
        check(!model.showsConversation, "explicit Screen preference survives live content")
        model.pause()
        await until { await transport.liveCount() == 0 }
        check(model.window.items.first?.blocks.first?.text == "live", "pause closes stream but keeps bounded display state")
        try await transport.prepare(native: "one", text: "while paused")
        model.resume()
        await until { model.window.items.first?.blocks.first?.text == "while paused" }
        check(await transport.liveCount() == 1, "foreground resume owns exactly one subscription")
        await transport.hold()
        model.update(selection: selection("two"))
        await until { await transport.heldCount() == 1 }
        model.update(selection: selection("one"))
        await until { model.hasConversation }
        await transport.releaseHeld()
        for _ in 0..<50 { await Task.yield() }
        check(model.window.summary?.nativeSession == "one", "late cancelled selection cannot overwrite new scope")
        model.stop()
        await until { await transport.liveCount() == 0 }
        check(!model.hasConversation && model.window.items.isEmpty, "navigation cleanup releases conversation and stream")
        model.connect(transport: transport, selection: selection("not-captured"))
        for _ in 0..<100 { await Task.yield() }
        check(!model.hasConversation && model.notice == nil, "opt-out/missing conversation quietly retains screen fallback")
        model.stop()
        print("Conversation model: \(count) passed, 0 failed")
    }
}
