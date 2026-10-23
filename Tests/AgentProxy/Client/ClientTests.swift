import Foundation
import AgentProxyCore

// Only the already-authenticated transport seam. The real SSH implementation
// is compiled separately with ShepherdKit; these tests perform no SSH/auth.
public protocol HerdrTransport: Actor {
    func openLineStream(endpoint: HerdrLineEndpoint, request: Data) async throws -> HerdrLineStream
}

nonisolated func fixtureItem(_ id: String, _ text: String) throws -> ConversationItem {
    let request = try RequestProjection.project(JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": text]]]), provider: .anthropic)
    return ConversationItem(id: id, message: request.messages[0], origin: .observed, status: .complete)
}

actor FakeConversationTransport: HerdrTransport {
    var store = ConversationStore()
    let key = ConversationKey(agent: "claude", herdrSession: "default", nativeSession: "native")!
    let context = ConversationContext(routeID: "route", paneID: "pane", terminalID: "terminal")!
    var subscriber: AsyncThrowingStream<Data, any Error>.Continuation?
    var cursor: ConversationReadAPI.Cursor?
    var closes = 0
    var wrongID = false
    var empty = false
    func configure(wrongID: Bool = false, empty: Bool = false) { self.wrongID = wrongID; self.empty = empty }
    func populate(_ items: [ConversationItem]) throws { _ = try store.upsert(key: key, context: context, items: items, status: .streaming) }
    func push(_ items: [ConversationItem]) throws {
        try populate(items)
        if let cursor, let update = ConversationReadAPI.update(after: cursor, store: store) {
            self.cursor = ConversationReadAPI.Cursor(update)
            subscriber?.yield(ConversationReadAPI.encodeUpdate(update))
        }
    }
    func close(subscription: Bool) { closes += 1; if subscription { subscriber?.finish(); subscriber = nil } }
    func openLineStream(endpoint: HerdrLineEndpoint, request: Data) async throws -> HerdrLineStream {
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        if empty { continuation.finish() }
        else {
            var response = ConversationReadAPI.answer(request, store: store)
            if wrongID {
                var value = try JSONSerialization.jsonObject(with: response) as! [String: Any]
                value["id"] = "wrong"; response = try JSONSerialization.data(withJSONObject: value)
            }
            continuation.yield(response)
            if object["method"] as? String == "conversation.subscribe" {
                subscriber = continuation
                cursor = ConversationReadAPI.Cursor(try ConversationReadAPI.decodeWire(ConversationReadAPI.Reply.self, from: response).result!)
            } else { continuation.finish() }
        }
        let subscription = object["method"] as? String == "conversation.subscribe"
        return HerdrLineStream(lines: stream, close: { Task { await self.close(subscription: subscription) } })
    }
}

@main struct ClientTests {
    static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL: " + label) }; passed += 1
        }
        let transport = FakeConversationTransport()
        let original = try (0..<40).map { try fixtureItem("i\($0)", "message\($0)") }
        try await transport.populate(original)
        let client = ConversationClient(transport: transport)
        let scope = ConversationSelection(terminalID: "terminal", herdrSession: "", agent: "claude", nativeSession: nil)
        let selected = try await client.select(scope)!
        check(selected.header.nativeSession == "native", "latest terminal fallback matches default namespace")
        let missing = try await client.select(.init(terminalID: "terminal", herdrSession: "default", agent: "claude", nativeSession: "different"))
        check(missing == nil, "known native session cannot fall back to another session in same terminal")
        let native = try await client.select(.init(terminalID: "old-terminal", herdrSession: "default", agent: "claude", nativeSession: "native"))
        check(native != nil, "exact native ID survives a resumed terminal move")
        check(try await client.select(.init(terminalID: "terminal", herdrSession: "other", agent: "claude", nativeSession: nil)) == nil, "herdr namespaces cannot cross")
        let updates = try await client.subscribe(id: selected.header.id, epoch: selected.epoch)
        defer { updates.close() }
        var iterator = updates.makeAsyncIterator()
        var window = ConversationWindow()
        let initial = try await iterator.next()!
        try window.apply(initial)
        check(window.items.count == 16 && window.nextBeforeItemID != nil, "initial bounded window")
        let anchor = window.nextBeforeItemID!
        let older = try await client.read(id: selected.header.id, epoch: selected.epoch, before: anchor)
        let live = Array(original.dropLast()) + [try fixtureItem("i39", "changed"), try fixtureItem("i40", "new")]
        try await transport.push(live)
        let delta = try await iterator.next()!
        try window.apply(delta)
        let liveSeq = window.seq
        try window.prepend(older, before: anchor)
        check(window.items.first?.id == "i8" && window.items.last?.id == "i40", "older page merges with concurrent live suffix")
        check(window.seq == liveSeq && window.items.first(where: { $0.id == "i39" })?.blocks.first?.text == "changed", "pagination neither rolls back live edits nor advances stream sequence")
        do { try window.apply(delta); check(false, "duplicate delta") } catch { check(true, "replayed delta is rejected") }
        let replaced = [try fixtureItem("replacement", "new history")]
        try await transport.push(replaced)
        let reset = try await iterator.next()!
        try window.apply(reset)
        check(reset.reset && window.items.map(\.id) == ["replacement"], "history reset replaces rather than concatenates old history")
        do { try window.prepend(older, before: anchor); check(false, "stale pagination") } catch { check(true, "old history generation cannot prepend after reset") }
        updates.close()

        await transport.configure(wrongID: true)
        do { _ = try await client.select(scope); check(false, "wrong reply ID") } catch { check(true, "response ID binding") }
        await transport.configure(empty: true)
        do { _ = try await client.select(scope); check(false, "closed before acknowledgement") } catch { check(true, "EOF does not fabricate a reply") }
        var framing = BoundedHostLines(); var lines: [Data] = []
        try framing.append(Data("first\nsec".utf8)) { lines.append($0) }
        try framing.append(Data("ond\n".utf8)) { lines.append($0) }
        check(lines.map { String(decoding: $0, as: UTF8.self) } == ["first", "second"] && !framing.hasIncompleteLine, "fragmented complete lines")
        do {
            var oversized = BoundedHostLines()
            try oversized.append([UInt8](repeating: 65, count: BoundedHostLines.maximumLineBytes) + [10]) { _ in }
            check(false, "oversized completed line")
        } catch { check(true, "completed line overflow cannot bypass framing bound") }
        do {
            let deep = Data(("{\"x\":" + String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100) + "}").utf8)
            _ = try ConversationWire.reply(deep, id: "x"); check(false, "deep JSON")
        } catch { check(true, "wire decoder preflights JSON nesting") }
        check(try HerdrLineEndpoint.conversations.path(home: "/Users/test").hasSuffix("/ac.sock"), "fixed paired-Mac endpoint")
        do { _ = try HerdrLineEndpoint.conversations.path(home: "relative"); check(false, "relative home") }
        catch { check(true, "relative remote home rejected") }
        check(try HerdrLineEndpoint.debugConversations.path(home: "/Users/test").hasSuffix("/ac-debug.sock"), "debug endpoint separate")
        print("Conversation client: \(passed) passed, 0 failed")
    }
}
