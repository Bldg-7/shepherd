import Foundation

@main struct ExperimentalSettingsDiagnosticsTests {
    static func availability(_ readiness: AgentCLIAvailability.Readiness, kind: AgentKind = .claude) -> AgentCLIAvailability {
        AgentCLIAvailability(nodeVersion: "20.0.0", nodeSupported: readiness != .unsupportedPrerequisite,
            kind: kind, executable: kind.rawValue, version: nil, readiness: readiness,
            sessionPlugin: kind == .claude, sessionConfiguration: kind == .codex, hookRewrite: false)
    }
    static func main() {
        let ready = availability(.availableAuthenticationUnknown)
        let missing = availability(.missing, kind: .codex)
        func show(_ values: [AgentCLIAvailability], failed: Bool = false) -> Bool {
            ExperimentalSettingsDiagnostics.shouldShow(browserEnabled: true, messages: [],
                                                        preparationFailed: failed, availability: values)
        }
        precondition(!show([]), "not checked yet is not a problem")
        precondition(!show([ready]), "normal ready state has no diagnostics")
        precondition(!show([ready, missing]), "an unused optional CLI need not be installed")
        let pi = availability(.missing, kind: .pi)
        precondition(!show([ready, pi]), "an optional missing Pi must not create a normal-state warning")
        precondition(show([missing, pi]), "all missing managed CLIs are actionable")
        precondition(!show([missing, availability(.availableAuthenticationUnknown, kind: .pi)]), "Pi alone can satisfy managed CLI availability")
        precondition(show([availability(.integrationUnavailable, kind: .pi)]), "a stale/unqualified Pi runtime needs attention")
        precondition(show([missing]), "no available agent CLI is actionable")
        precondition(show([ready, availability(.unsupported, kind: .codex)]))
        precondition(show([availability(.unsupportedPrerequisite)]))
        precondition(show([], failed: true), "failure still offers retry even without message text")
        let messages = ExperimentalSettingsDiagnostics.messages(browserEnabled: true, refusal: " denied ",
            errors: [nil, "denied", "\n", "same failure", " same failure\n", "another failure"])
        precondition(messages == ["denied", "same failure", "another failure"])
        let off = ExperimentalSettingsDiagnostics.messages(browserEnabled: false, refusal: nil,
                                                           errors: ["stale agent failure", "stale port error"])
        precondition(off.isEmpty)
        precondition(!ExperimentalSettingsDiagnostics.shouldShow(browserEnabled: false, messages: off,
                                                                preparationFailed: true, availability: [missing]))
        let refusal = ExperimentalSettingsDiagnostics.messages(browserEnabled: false, refusal: "Cannot disable", errors: ["old failure"])
        precondition(refusal == ["Cannot disable"])
        precondition(ExperimentalSettingsDiagnostics.shouldShow(browserEnabled: false, messages: refusal,
                                                               preparationFailed: false, availability: []))
        print("PASS diagnostics visibility: healthy/waiting hidden, optional missing CLI hidden, actual failures visible, duplicates/empty messages removed, stale OFF errors hidden, refusal retained")
    }
}
