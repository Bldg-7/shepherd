import Foundation

/// The production policy and notification text, with the event types; the
/// example events are the ones the deriver is checked against.
@main @MainActor enum NotificationPolicyTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static var examples: URL!
    static func example(_ name: String) -> AgentEvent {
        try! AgentEvent.decode(Data(contentsOf: examples.appending(path: name)))
    }

    static func main() {
        examples = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        policy()
        text()
        print("PASS \(checks) notification policy checks: kinds on and off, viewed pane, 10 s repeat, expiry, resumed retracts, unknown kinds by urgency; title, subtitle and body")
    }

    static func policy() {
        let needsInput = example("needs-input.json")
        let finished = example("finished.json")
        let resumed = example("resumed.json")
        let newer = example("from-a-newer-producer.json")
        let now = needsInput.observedAt.addingTimeInterval(2)
        let all = NotificationKinds(needsInput: true, finished: true)
        func decide(_ event: AgentEvent, _ enabled: NotificationKinds = all, viewed: Bool = false, last: Date? = nil, at time: Date? = nil) -> NotificationPolicy.Decision {
            NotificationPolicy.decide(event, enabled: enabled, isViewed: viewed, lastPresented: last, now: time ?? event.observedAt.addingTimeInterval(2))
        }

        check(decide(needsInput) == .present && decide(finished) == .present, "both kinds on: shown")
        check(decide(needsInput, NotificationKinds(needsInput: false, finished: true)) == .drop(.turnedOff), "needs input off: dropped")
        check(decide(finished, NotificationKinds(needsInput: false, finished: true)) == .present, "the other kind is unaffected")
        check(decide(finished, NotificationKinds(needsInput: true, finished: false)) == .drop(.turnedOff), "finished off: dropped")
        check(!NotificationKinds(needsInput: false, finished: false).any && all.any, "any kind on")

        check(decide(needsInput, viewed: true) == .drop(.viewed), "the pane in front of the person: dropped")
        check(decide(needsInput, last: now.addingTimeInterval(-9.9), at: now) == .drop(.repeated), "the same kind for the same pane 9.9 s ago: dropped")
        check(decide(needsInput, last: now.addingTimeInterval(-10), at: now) == .present, "10 s later: shown again")
        check(decide(needsInput, at: needsInput.expiresAt!) == .drop(.expired), "at its expiry: dropped")
        check(decide(needsInput, at: needsInput.expiresAt!.addingTimeInterval(-1)) == .present, "a second before: shown")
        check(decide(needsInput, NotificationKinds(needsInput: false, finished: true), viewed: true) == .drop(.turnedOff), "turned off is the first reason")

        let none = NotificationKinds(needsInput: false, finished: false)
        check(decide(resumed) == .retract && decide(resumed, none) == .retract && decide(resumed, viewed: true) == .retract,
              "resumed takes back what was shown, whatever the settings")

        // Kinds this reader doesn't know go by their urgency.
        check(decide(newer) == .present, "unknown kind, info: shown")
        check(decide(newer, NotificationKinds(needsInput: true, finished: false)) == .drop(.turnedOff), "info follows the finished setting")
        var attention = newer
        attention.urgency = .attention
        check(decide(attention, NotificationKinds(needsInput: true, finished: false)) == .present
              && decide(attention, NotificationKinds(needsInput: false, finished: true)) == .drop(.turnedOff), "attention follows the needs-input setting")
        var silent = newer
        silent.urgency = .silent
        check(decide(silent) == .drop(.silent), "unknown kind, silent: not shown")
        silent.urgency = AgentEvent.Urgency(rawValue: "critical")
        check(decide(silent) == .drop(.silent), "unknown kind, unknown urgency: not shown")
        check(decide(newer, viewed: true) == .drop(.viewed) && decide(newer, at: newer.observedAt.addingTimeInterval(86_400 * 30)) == .present,
              "no expiry: never expires")
    }

    static func text() {
        let needsInput = example("needs-input.json")
        let finished = example("finished.json")
        check(NotificationText.content(for: needsInput, showsMachine: false)
              == NotificationText.Content(title: "claude needs your input", subtitle: "", body: "SHPHRD-17 · shepherd"),
              "needs input: agent in the title, pane and workspace in the body")
        check(NotificationText.content(for: finished, showsMachine: true)
              == NotificationText.Content(title: "claude finished", subtitle: "This Mac", body: "SHPHRD-17 · shepherd"),
              "finished, with the machine in the subtitle")
        check(NotificationText.content(for: example("resumed.json"), showsMachine: true) == nil, "resumed: nothing to show")

        var bare = needsInput
        bare.display = AgentEvent.Display(paneTitle: "  ", workspaceLabel: "web")
        bare.subject.agent = nil
        check(NotificationText.content(for: bare, showsMachine: true)
              == NotificationText.Content(title: "An agent needs your input", subtitle: "", body: "web"),
              "no agent, blank title, no machine name: what there is")
        bare.display = AgentEvent.Display()
        bare.subject.agent = "codex"
        bare.kind = .finished
        check(NotificationText.content(for: bare, showsMachine: false)?.title == "codex finished", "the agent from the subject when display has none")

        let newer = example("from-a-newer-producer.json")
        check(NotificationText.content(for: newer, showsMachine: false)?.title == "codex has an update", "unknown kind, info")
        var attention = newer
        attention.urgency = .attention
        check(NotificationText.content(for: attention, showsMachine: false)?.title == "codex needs your attention", "unknown kind, attention")
        attention.urgency = .silent
        check(NotificationText.content(for: attention, showsMachine: false) == nil, "unknown kind, silent: nothing")
    }
}
