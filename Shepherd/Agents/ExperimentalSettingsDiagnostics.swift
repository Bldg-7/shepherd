import Foundation

/// Presentation-only policy: no probes or changes to runtime availability.
nonisolated enum ExperimentalSettingsDiagnostics {
    static func messages(browserEnabled: Bool, refusal: String?, errors: [String?]) -> [String] {
        var seen = Set<String>()
        return ([refusal] + (browserEnabled ? errors : [])).compactMap { value in
            guard let message = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty, seen.insert(message).inserted else { return nil }
            return message
        }
    }

    static func shouldShow(browserEnabled: Bool, messages: [String], preparationFailed: Bool,
                           availability: [AgentCLIAvailability]) -> Bool {
        if !messages.isEmpty { return true }
        guard browserEnabled else { return false }
        if preparationFailed { return true }
        let managed = availability.filter { $0.kind.supportsManagedBrowserLaunch }
        if managed.contains(where: { $0.readiness == .unsupported || $0.readiness == .unsupportedPrerequisite || $0.readiness == .integrationUnavailable }) {
            return true
        }
        // Not installing an optional second CLI is not itself an error.
        return !managed.isEmpty && managed.allSatisfy { $0.readiness == .missing }
    }
}
