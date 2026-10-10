import Foundation

/// Cosmetic only: preserve raw OSC/herdr titles, labels and all identity data.
/// Never use the result to infer agent kind, session identity or authorization.
nonisolated enum AgentTitleDisplay {
    static func terminal(_ raw: String, agentName: String?) -> String {
        guard agentName == "pi" else { return raw }
        for prefix in ["π - ", "pi - "] where raw.hasPrefix(prefix) {
            let remainder = String(raw.dropFirst(prefix.count))
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? raw : remainder
        }
        return raw
    }
}
