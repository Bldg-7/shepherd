import Foundation

// Only AgentKind's runtime/launch dependencies are a seam; the production
// pane, tab and workspace models, the event types and the deriver are
// compiled intact.
nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

@main @MainActor enum AgentEventTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static var examples: URL!
    static func example(_ name: String) -> Data {
        try! Data(contentsOf: examples.appending(path: name))
    }
    /// The same JSON, whatever the order of keys and the spacing.
    static func sameJSON(_ a: Data, _ b: Data) -> Bool {
        let left = try! JSONSerialization.jsonObject(with: a) as! NSDictionary
        let right = try! JSONSerialization.jsonObject(with: b) as! [AnyHashable: Any]
        return left.isEqual(to: right)
    }
    static func time(_ text: String) -> Date { try! Date(text, strategy: Date.ISO8601FormatStyle()) }

    static let thisMac = AgentEventSource(
        herdr: AgentEvent.HerdrInstance(instanceID: "79763D9A-997B-4E75-A3FA-6EF5D0338479", scope: .deviceLocal, session: "default"),
        machineLabel: "This Mac",
        producer: AgentEvent.Producer(kind: "shepherd-macos", version: "0.3.3", instance: "0C7A5D8E-2F43-4B1A-9E6D-5A1F3C2B7D90"))

    static func pane(_ state: AgentState, seq: Int? = nil, pane: String = "w1P:p1", terminal: String = "term_65d9f3796d97b84",
                     agent: String? = "claude", title: String = "SHPHRD-17") -> AgentObservation {
        AgentObservation(paneID: pane, terminalID: terminal, tabID: "w1P:t1", workspaceID: "w1P", agent: agent, state: state,
                         stateChangeSeq: seq, paneTitle: title, tabLabel: "Notifications", workspaceLabel: "shepherd")
    }

    static func main() {
        examples = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        digest()
        contract()
        deriverMakesTheExamples()
        deriverRules()
        observationsFromSnapshot()
        print("PASS \(checks) agent event checks: SHA-256 vectors, example JSON decode/encode/ids, unknown kinds and fields, 2 KB limit, baselines (first look, connection, gap, herdr restart), unknown skipped, terminal and agent identity, startup grace, every transition, held or not, snapshot labels")
    }

    static func digest() {
        check(AgentEventDigest.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 of nothing")
        check(AgentEventDigest.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of abc")
        check(AgentEventDigest.sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
              == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA-256 across two blocks")
        check(AgentEventDigest.sha256Hex(String(repeating: "a", count: 1_000_000))
              == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "SHA-256 of a million a's")
        check(AgentEventDigest.sha256Hex("에이전트 · エージェント 🐑") == "73bd40a4d5ff26d78ca7bd67926667927de6700382a816ab732267035e024227", "SHA-256 of UTF-8 beyond ASCII")
    }

    static func contract() {
        for name in ["needs-input.json", "resumed.json", "finished.json"] {
            let data = example(name)
            let event = try! AgentEvent.decode(data)
            check(sameJSON(try! AgentEvent.encode(event), data), name + ": encodes back to the example exactly")
            check(event.id == AgentEvent.identifier(instanceID: event.subject.herdr.instanceID, terminalID: event.subject.terminalID,
                                                    stateChangeSeq: event.transition.stateChangeSeq, observedAt: event.observedAt, kind: event.kind),
                  name + ": id is the hash the contract defines")
            check(event.subject.collapseKey == AgentEvent.collapseKey(instanceID: event.subject.herdr.instanceID, terminalID: event.subject.terminalID),
                  name + ": collapse_key is the hash the contract defines")
            check(event.subject.collapseKey.utf8.count <= AgentEvent.maximumCollapseKeySize, name + ": collapse_key within 64 bytes")
            check(try! AgentEvent.encode(event).count <= AgentEvent.maximumEncodedSize, name + ": within 2 KB")
            check(event.kind.urgency == event.urgency, name + ": urgency is the kind's")
        }
        let needsInput = try! AgentEvent.decode(example("needs-input.json"))
        check(needsInput.kind == .needsInput && needsInput.observedAt == time("2026-10-14T03:21:07Z")
              && needsInput.expiresAt == time("2026-10-14T04:21:07Z"), "times are ISO-8601 UTC")
        let encoded = String(decoding: try! AgentEvent.encode(needsInput), as: UTF8.self)
        check(encoded.contains("\"observed_at\":\"2026-10-14T03:21:07Z\"") && encoded.contains("\"state_change_seq\":412")
              && encoded.contains("\"instance_id\":") && !encoded.contains("instanceID"), "snake_case keys, whole-second UTC times")

        // What a newer producer might send: unknown kind, scope and fields,
        // fractions of a second, no display, no expiry.
        let newer = try! AgentEvent.decode(example("from-a-newer-producer.json"))
        check(newer.schemaVersion == 2 && newer.kind.rawValue == "agent.waiting_for_review" && newer.kind.urgency == nil
              && newer.urgency == .info, "an unknown kind decodes, with the urgency it was sent with")
        check(newer.subject.herdr.scope == .global && newer.subject.tabID == nil && newer.display == AgentEvent.Display()
              && newer.expiresAt == nil && newer.transition.to == "review", "unknown fields are passed over, missing optional ones are empty")
        check(abs(newer.observedAt.timeIntervalSince1970 - time("2026-10-14T05:00:00Z").timeIntervalSince1970 - 0.25) < 0.001,
              "fractions of a second are read")
        let unknownUrgency = String(decoding: example("needs-input.json"), as: UTF8.self)
            .replacingOccurrences(of: "\"attention\"", with: "\"critical\"")
        check((try? AgentEvent.decode(Data(unknownUrgency.utf8)))?.urgency.rawValue == "critical", "an unknown urgency decodes")
        let noID = String(decoding: example("needs-input.json"), as: UTF8.self)
            .replacingOccurrences(of: "\"id\": \"975cc268686c8090e353c549cfee2e87\",", with: "")
        check((try? AgentEvent.decode(Data(noID.utf8))) == nil, "an event without its id is refused")

        // 2 KB, however long the names: display texts are cut, nothing else.
        var long = needsInput
        long.display = AgentEvent.Display(agentName: String(repeating: "에", count: 300), paneTitle: String(repeating: "🐑", count: 500),
                                          tabLabel: String(repeating: "タ", count: 400), workspaceLabel: String(repeating: "w", count: 900),
                                          machineLabel: String(repeating: "機", count: 300))
        let fitted = long.fittedToSizeLimit()
        let fittedSize = try! AgentEvent.encode(fitted).count
        check(fittedSize <= AgentEvent.maximumEncodedSize, "long names fitted within 2 KB (\(fittedSize) bytes)")
        check(fitted.display.paneTitle?.hasSuffix("…") == true && fitted.display.paneTitle!.count <= 80, "cut texts end in an ellipsis")
        check(fitted.subject == needsInput.subject && fitted.transition == needsInput.transition && fitted.id == needsInput.id,
              "identity is never cut")
        check(needsInput.fittedToSizeLimit() == needsInput, "an event within the limit is left as it is")

        // No state_change_seq: the time stands in for it, so two changes still differ.
        let first = AgentEvent.identifier(instanceID: "i", terminalID: "t", stateChangeSeq: nil, observedAt: time("2026-10-14T03:00:00Z"), kind: .finished)
        let second = AgentEvent.identifier(instanceID: "i", terminalID: "t", stateChangeSeq: nil, observedAt: time("2026-10-14T03:05:00Z"), kind: .finished)
        check(first != second && first.count == 32, "without a change count, the time makes the id")
        check(first == String(AgentEventDigest.sha256Hex("i\nt\n@2026-10-14T03:00:00Z\nagent.finished").prefix(32)), "the id's input, spelled out")
    }

    /// The examples are what the deriver makes of a real sequence.
    static func deriverMakesTheExamples() {
        var deriver = AgentEventDeriver(source: thisMac)
        check(deriver.observe([pane(.working, seq: 400)], at: time("2026-10-14T03:20:40Z")).isEmpty, "first look: a baseline")
        let blocked = deriver.observe([pane(.blocked, seq: 412)], at: time("2026-10-14T03:21:07Z").addingTimeInterval(0.6))
        check(blocked.count == 1 && sameJSON(try! AgentEvent.encode(blocked[0]), example("needs-input.json")),
              "working → blocked is needs-input.json (the time in whole seconds)")
        let resumed = deriver.observe([pane(.working, seq: 415)], at: time("2026-10-14T03:22:00Z"))
        check(resumed.count == 1 && sameJSON(try! AgentEvent.encode(resumed[0]), example("resumed.json")), "blocked → working is resumed.json")
        check(deriver.observe([pane(.working, seq: 415)], at: time("2026-10-14T03:22:30Z")).isEmpty, "unchanged: nothing")
        var step = time("2026-10-14T03:22:30Z")
        while step < time("2026-10-14T03:34:00Z") {
            step = step.addingTimeInterval(30)
            check(deriver.observe([pane(.working, seq: 415)], at: step).isEmpty, "still working")
        }
        let finished = deriver.observe([pane(.idle, seq: 418)], at: time("2026-10-14T03:34:34Z"))
        check(finished.count == 1 && sameJSON(try! AgentEvent.encode(finished[0]), example("finished.json")),
              "working → idle is finished.json, 754 seconds after it went back to work")
    }

    static func deriverRules() {
        let start = time("2026-10-14T03:00:00Z")
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        func kinds(_ events: [AgentEvent]) -> [String] { events.map(\.kind.rawValue) }

        // Every transition between the four statuses.
        let states: [AgentState] = [.idle, .working, .blocked, .done]
        for from in states {
            for to in states {
                var deriver = AgentEventDeriver(source: thisMac)
                _ = deriver.observe([pane(from, seq: 1)], at: at(0))
                let events = deriver.observe([pane(to, seq: 2)], at: at(30))
                let expected: [String] = switch (from, to) {
                case (.idle, .blocked), (.working, .blocked), (.done, .blocked): ["agent.needs_input"]
                case (.working, .idle), (.working, .done), (.blocked, .idle), (.blocked, .done): ["agent.finished"]
                case (.idle, .working), (.blocked, .working), (.done, .working): ["agent.resumed"]
                default: []
                }
                check(kinds(events) == expected, "\(from) → \(to): \(expected)")
                if let event = events.first {
                    check(event.transition.from == from.rawValue && event.transition.to == to.rawValue
                          && event.urgency == event.kind.urgency, "\(from) → \(to): transition and urgency as herdr has them")
                }
            }
        }

        // unknown is no news: the change is from the status before it.
        var deriver = AgentEventDeriver(source: thisMac)
        _ = deriver.observe([pane(.working, seq: 1)], at: at(0))
        check(deriver.observe([pane(.unknown, seq: 2)], at: at(5)).isEmpty, "working → unknown: nothing")
        let afterUnknown = deriver.observe([pane(.blocked, seq: 3)], at: at(10))
        check(kinds(afterUnknown) == ["agent.needs_input"] && afterUnknown[0].transition.from == "working", "unknown → blocked: from working")
        deriver = AgentEventDeriver(source: thisMac)
        _ = deriver.observe([pane(.unknown)], at: at(0))
        check(deriver.observe([pane(.blocked)], at: at(5)).isEmpty, "first known status after only unknown: a baseline")

        // Baselines.
        deriver = AgentEventDeriver(source: thisMac)
        _ = deriver.observe([pane(.working, seq: 1)], at: at(0))
        check(deriver.observe([pane(.blocked, seq: 2)], at: at(5), asBaseline: true).isEmpty, "first look on a new connection: a baseline")
        check(kinds(deriver.observe([pane(.working, seq: 3)], at: at(10))) == ["agent.resumed"], "and compared from there")
        check(deriver.observe([pane(.idle, seq: 4)], at: at(71)).isEmpty, "more than 60 s since the last look: a baseline")
        check(kinds(deriver.observe([pane(.blocked, seq: 5)], at: at(130))) == ["agent.needs_input"], "59 s is no gap")
        check(deriver.observe([pane(.idle, seq: 2)], at: at(135)).isEmpty, "the change count went back — herdr started over: a baseline")
        check(kinds(deriver.observe([pane(.working, seq: 3)], at: at(140))) == ["agent.resumed"], "and counted from its new numbers")

        // A pane is its terminal, and one agent in it.
        deriver = AgentEventDeriver(source: thisMac)
        _ = deriver.observe([pane(.working, seq: 1)], at: at(0))
        check(deriver.observe([pane(.blocked, seq: 2, terminal: "term_other")], at: at(5)).isEmpty,
              "same pane ID, another terminal: another pane, first seen")
        check(kinds(deriver.observe([pane(.idle, seq: 3, terminal: "term_other")], at: at(20))) == ["agent.finished"], "which is then followed")
        check(deriver.observe([pane(.idle, seq: 3, terminal: "term_other"), pane(.blocked, seq: 4, pane: "w1P:p2", terminal: "term_new")], at: at(25)).isEmpty,
              "a pane opened since: first seen, nothing")
        check(deriver.observe([pane(.working, seq: 5, terminal: "term_other", agent: "codex")], at: at(30)).isEmpty, "another agent in the pane: first seen")
        check(deriver.observe([pane(.idle, seq: 6, terminal: "term_other", agent: "codex")], at: at(35)).isEmpty,
              "finishing within 10 s of being first seen: starting up, not told")
        _ = deriver.observe([pane(.working, seq: 7, terminal: "term_other", agent: "codex")], at: at(40))
        check(kinds(deriver.observe([pane(.idle, seq: 8, terminal: "term_other", agent: "codex")], at: at(50))) == ["agent.finished"],
              "finishing 10 s or more after: told")
        check(kinds(deriver.observe([pane(.blocked, seq: 9, terminal: "term_other", agent: "codex")], at: at(51))) == ["agent.needs_input"],
              "needing input is told however soon")
        check(deriver.observe([pane(.blocked, seq: 9, terminal: "term_other", agent: nil)], at: at(55)).isEmpty, "the agent gone: nothing")
        check(deriver.observe([pane(.working, seq: 10, terminal: "term_other", agent: nil)], at: at(60)).isEmpty, "a plain terminal: never anything")
        _ = deriver.observe([], at: at(65))
        check(deriver.observe([pane(.idle, seq: 11, terminal: "term_other", agent: nil)], at: at(70)).isEmpty, "a pane closed and back: first seen")

        // Several panes in one look, each on its own.
        deriver = AgentEventDeriver(source: thisMac)
        _ = deriver.observe([pane(.working, seq: 1, pane: "p1", terminal: "t1"), pane(.working, seq: 2, pane: "p2", terminal: "t2"),
                             pane(.idle, seq: 3, pane: "p3", terminal: "t3")], at: at(0))
        let several = deriver.observe([pane(.blocked, seq: 4, pane: "p1", terminal: "t1"), pane(.done, seq: 5, pane: "p2", terminal: "t2"),
                                       pane(.idle, seq: 3, pane: "p3", terminal: "t3")], at: at(5))
        check(kinds(several) == ["agent.needs_input", "agent.finished"] && several.map(\.subject.terminalID) == ["t1", "t2"], "one event per pane that changed")
        check(Set(several.map(\.id)).count == 2 && Set(several.map(\.subject.collapseKey)).count == 2, "their own ids and collapse keys")
        check(deriver.latest(terminalID: "t2")?.state == .done && deriver.latest(terminalID: "gone") == nil, "the last look at a pane")

        // Held or not, in a later look.
        let needsInput = several[0], finished = several[1]
        check(AgentEventDeriver.stillHolds(needsInput, in: [pane(.blocked, pane: "p1", terminal: "t1")]), "still blocked: holds")
        check(!AgentEventDeriver.stillHolds(needsInput, in: [pane(.working, pane: "p1", terminal: "t1")]), "back to working: doesn't")
        check(!AgentEventDeriver.stillHolds(needsInput, in: [pane(.unknown, pane: "p1", terminal: "t1")]), "unknown: doesn't")
        check(!AgentEventDeriver.stillHolds(needsInput, in: [pane(.blocked, pane: "p1", terminal: "t9")]), "the pane gone: doesn't")
        check(!AgentEventDeriver.stillHolds(needsInput, in: [pane(.blocked, pane: "p1", terminal: "t1", agent: "codex")]), "another agent: doesn't")
        check(AgentEventDeriver.stillHolds(finished, in: [pane(.idle, pane: "p2", terminal: "t2")])
              && AgentEventDeriver.stillHolds(finished, in: [pane(.done, pane: "p2", terminal: "t2")]), "finished: idle or done both hold")
        check(!AgentEventDeriver.stillHolds(finished, in: [pane(.working, pane: "p2", terminal: "t2")]), "finished, then working again: doesn't")

        // Without herdr's change count.
        deriver = AgentEventDeriver(source: thisMac)
        _ = deriver.observe([pane(.working)], at: at(0))
        let noCount = deriver.observe([pane(.blocked)], at: at(5))
        check(noCount.count == 1 && noCount[0].transition.stateChangeSeq == nil
              && noCount[0].id == AgentEvent.identifier(instanceID: thisMac.herdr.instanceID, terminalID: "term_65d9f3796d97b84",
                                                         stateChangeSeq: nil, observedAt: at(5), kind: .needsInput),
              "no change count: the time makes the id")
        check(noCount[0].display.machineLabel == "This Mac" && noCount[0].producer.kind == "shepherd-macos", "machine and producer from the source")
    }

    /// Labels come from the snapshot's tabs and workspaces.
    static func observationsFromSnapshot() {
        let json = """
        {"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","terminal_id":"term_1","agent":"claude","agent_status":"blocked",
                   "terminal_title_stripped":"Fix flaky test","label":"Flaky","revision":3},
                  {"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","terminal_id":"term_2","agent_status":"unknown","revision":1}],
         "agents":[{"pane_id":"w1:p1","state_change_seq":77}],
         "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"Login","number":1},{"tab_id":"w1:t2","workspace_id":"w1","number":2}],
         "workspaces":[{"workspace_id":"w1","label":"web","number":1}]}
        """
        let snapshot = HerdrSnapshot(snapshot: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        let observations = AgentObservation.all(panes: snapshot.panes, tabs: snapshot.tabs, workspaces: snapshot.workspaces)
        check(observations.count == 2, "every pane")
        let first = observations[0]
        check(first.paneTitle == "Flaky" && first.agent == "claude" && first.state == .blocked && first.stateChangeSeq == 77
              && first.tabLabel == "Login" && first.workspaceLabel == "web" && first.terminalID == "term_1", "title, agent, status, count, tab and workspace")
        check(observations[1].agent == nil && observations[1].tabLabel == "2", "a plain terminal; a tab herdr only numbers")
        check(AgentObservation.all(panes: snapshot.panes, tabs: nil, workspaces: nil)[0].tabLabel == nil, "a herdr too old for tabs: no labels")
    }
}
