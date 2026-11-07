import Foundation

@main @MainActor private struct HcProgramStatusPresentationTests {
    static var checks = 0
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name); checks += 1
    }
    static func main() {
        let known: [(String, AgentState)] = [("working", .working), ("blocked", .blocked),
            ("done", .done), ("error", .blocked), ("idle", .idle)]
        for (word, expected) in known {
            check(HcProgramStatusPresentation.state(reported: true, word: word) == expected, "native OSC state: \(word)")
            check(HcProgramStatusPresentation.state(reported: false, word: word) == nil, "unreported \(word) is unavailable, not an agent fact")
        }
        for word in [nil, "", "running", "active", "needs_input", "clear", "unknown", "Working", "working ", "ready", "busy"] as [String?] {
            check(HcProgramStatusPresentation.state(reported: true, word: word) == nil, "no inferred status from \(String(describing: word))")
            check(HcProgramStatusPresentation.state(reported: false, word: word) == nil, "unreported words never prove readiness")
        }
        print("PASS \(checks) native program-status presentation checks; no GUI or CLI run")
    }
}
