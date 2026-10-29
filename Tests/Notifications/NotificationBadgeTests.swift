import Foundation

// Only AgentKind's runtime/launch dependencies are a seam; the production
// pane models, the badge count and the preferences are compiled intact.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}

/// The Dock badge's count, the machines turned off, and the preferences'
/// defaults, in a user defaults suite of the test's own.
@main @MainActor enum NotificationBadgeTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

    static func pane(_ id: String, _ status: String, agent: String? = "claude") -> AgentSummary {
        var json = "{\"pane_id\":\"\(id)\",\"terminal_id\":\"term_\(id)\",\"agent_status\":\"\(status)\",\"revision\":1"
        if let agent { json += ",\"agent\":\"\(agent)\"" }
        json += "}"
        return AgentSummary(json: try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))!
    }

    static func main() {
        badge()
        preferences()
        print("PASS \(checks) notification badge checks: blocked agents only, host and herdr machines summed, failing and muted machines left out; defaults, kinds, muted machines kept and forgotten")
    }

    static func badge() {
        let a = UUID(), b = UUID(), c = UUID()
        let mixed = [pane("p1", "blocked"), pane("p2", "working"), pane("p3", "done"), pane("p4", "idle"), pane("p5", "blocked", agent: "codex"),
                     pane("p6", "unknown"), pane("p7", "blocked", agent: nil)]
        func machine(_ id: UUID, _ panes: [AgentSummary], failing: Bool = false,
                     nested: [NotificationBadge.HerdrMachineAgents] = []) -> NotificationBadge.MachineAgents {
            NotificationBadge.MachineAgents(machineID: id, panes: panes, isFailing: failing, herdrMachines: nested)
        }
        check(NotificationBadge.count([], muted: []) == 0, "no machines: 0")
        check(NotificationBadge.count([machine(a, mixed)], muted: []) == 2,
              "blocked agents only: not working, done, idle, unknown, nor a plain terminal herdr calls blocked")
        let nested = [NotificationBadge.HerdrMachineAgents(panes: [pane("n1", "blocked"), pane("n2", "blocked")], isFailing: false),
                      NotificationBadge.HerdrMachineAgents(panes: [pane("n3", "blocked")], isFailing: true)]
        check(NotificationBadge.count([machine(a, mixed, nested: nested)], muted: []) == 4,
              "host and herdr machines summed; a herdr machine that failed to list left out")
        check(NotificationBadge.count([machine(a, mixed), machine(b, [pane("q1", "blocked")])], muted: []) == 3, "across machines")
        check(NotificationBadge.count([machine(a, mixed), machine(b, [pane("q1", "blocked")], failing: true)], muted: []) == 2,
              "a machine whose connection is failing: left out")
        check(NotificationBadge.count([machine(a, mixed, failing: true, nested: nested)], muted: []) == 0,
              "its herdr machines with it")
        check(NotificationBadge.count([machine(a, mixed, nested: nested), machine(b, [pane("q1", "blocked")]), machine(c, [pane("r1", "blocked")])],
                                      muted: [a, c]) == 1, "machines turned off: left out, herdr machines and all")
    }

    static func preferences() {
        let suite = "SHPHRD-55.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = NotificationPreferences(defaults: defaults)
        check(fresh.notifiesNeedsInput && fresh.notifiesFinished && fresh.notifiesExited && fresh.showsBadge,
              "every kind and the badge on to begin with")
        check(fresh.kinds == NotificationKinds(needsInput: true, finished: true, exited: true) && fresh.kinds.any, "the kinds, quitting included")
        check(fresh.mutedMachineIDs.isEmpty, "no machine turned off")
        check(NotificationPreferences.exitedKey == "Notifications.agentExited" && NotificationPreferences.badgeKey == "Notifications.dockBadge"
              && NotificationPreferences.mutedMachinesKey == "Notifications.mutedMachines", "their keys")

        let a = UUID(), b = UUID(), c = UUID()
        fresh.notifiesExited = false
        fresh.showsBadge = false
        fresh.setMuted(true, a)
        fresh.setMuted(true, b)
        fresh.setMuted(true, b)
        check(fresh.isMuted(a) && fresh.isMuted(b) && !fresh.isMuted(c), "turned off, each machine on its own")
        check(Set(defaults.stringArray(forKey: NotificationPreferences.mutedMachinesKey) ?? []) == [a.uuidString, b.uuidString],
              "only the machines turned off are kept")
        fresh.setMuted(false, a)

        let again = NotificationPreferences(defaults: defaults)
        check(!again.notifiesExited && !again.showsBadge && again.notifiesFinished, "kept across launches")
        check(again.mutedMachineIDs == [b] && !again.isMuted(c), "turned on again, and a machine never seen is on")
        check(!NotificationKinds(needsInput: false, finished: false, exited: false).any, "nothing on")

        again.keepMuted(onlyAmong: [a, c])
        check(again.mutedMachineIDs.isEmpty && (defaults.stringArray(forKey: NotificationPreferences.mutedMachinesKey) ?? ["x"]).isEmpty,
              "a removed machine's setting is forgotten")
        again.setMuted(true, c)
        again.keepMuted(onlyAmong: [a, c])
        check(again.mutedMachineIDs == [c], "a machine still there keeps its setting")
    }
}
