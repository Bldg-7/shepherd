import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct PiClassificationTests {
    static func open(_ kind: String = "main", version: String = "1.4.0", contract: String? = "2",
                     native: String? = "pi-native", responses: Bool = false, extra: [[String]] = []) -> AgentProxyTeeFrame.Open {
        var headers = [["x-3rdr-pi-class", kind], ["content-type", "application/json"]] + extra
        if let contract { headers.append(["x-3rdr-pi-contract", contract]) }
        if let native { headers.append(["x-3rdr-pi-session", native]) }
        return AgentProxyTeeFrame.Open(routeID: "route", upstream: responses ? "chatgpt" : "anthropic", method: "POST",
            path: responses ? "/backend-api/codex/responses" : "/v1/messages", headers: headers,
            routeIdentity: .init(kind: .pi, session: "default", paneID: "pane", terminalID: "terminal", cliVersion: version))
    }
    static func run(check: (Bool, String) -> Void) throws {
        let body = Data("{}".utf8)
        for version in ["1.3.0", "1.4.0"] {
            for responses in [false, true] {
                let classified = RequestClassification.classify(open(version: version, responses: responses), body: body)
                check(classified.kind == .main && classified.mainConversationKey?.nativeSession == "pi-native" && classified.mainConversationKey?.agent == "pi", "verified Pi contract2 main for \(version) provider\(responses)")
            }
        }
        for input in [open(contract: nil), open(contract: "1"), open(version: "1.5.0"), open(native: nil), open(native: "bad id"),
                      open(extra: [["x-openai-subagent", "collab_spawn"]]), open(extra: [["x-codex-parent-thread-id", "parent"]]),
                      open(extra: [["X-3rdr-Pi-Contract", "2"]])] {
            check(RequestClassification.classify(input, body: body).mainConversationKey == nil, "legacy/unknown/conflicting Pi tagging fails closed")
        }
        check(RequestClassification.classify(open("auxiliary", native: nil), body: body).kind == .auxiliary, "warming/auxiliary requires no fabricated native identity")
        let compact = RequestClassification.classify(open("compaction"), body: body)
        check(compact.kind == .compaction && compact.mainConversationKey == nil, "compaction purpose cannot become main")
        let h = ConversationCaptureTests.Harness()
        try h.json(.open, 1, open()); try h.request(1); try h.head(1); try h.answer(1, "main answer"); try h.end(1)
        let before = h.snapshot!
        check(before.summary.key.agent == "pi" && before.items.last?.message.blocks.first?.text == "main answer", "verified Pi tee request reaches native conversation")
        try h.json(.open, 2, open("compaction")); try h.request(2, "not a user message"); try h.head(2); try h.answer(2, "visible summary"); try h.end(2)
        check(h.snapshot?.items.last?.origin == .summary && Array(h.snapshot!.items.prefix(before.items.count)) == before.items, "Pi operation-bound compaction preserves visible history")
        let count = h.capture.reconciler.store.count, seq = h.capture.reconciler.store.sequence
        try h.json(.open, 3, open("auxiliary", native: nil)); try h.request(3, "warm"); try h.head(3); try h.answer(3, "not main"); try h.end(3)
        check(h.capture.reconciler.store.count == count && h.capture.reconciler.store.sequence == seq, "auxiliary Pi response cannot alter main history")
    }
}
