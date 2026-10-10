import Foundation

/// Empty-editor proof for the actually tested interactive CLI renderings.
/// herdr's quiescent/interactive_ready alone can also describe a review modal.
nonisolated enum AgentIdleStopPolicy {
    static func isEmptyEditor(kind: AgentKind, ansi: String) -> Bool {
        let plain = ansi.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let lower = plain.lowercased()
        guard !["esc to go back", "esc to close", "enter to confirm", "hooks need review", "requests your input", "do you want to proceed"].contains(where: lower.contains) else { return false }
        let lines = ansi.components(separatedBy: .newlines)
        switch kind {
        case .pi:
            // No ANSI heuristic may authorize stopping a Pi process.
            return false
        case .claude:
            return plain.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces) == "❯" }.count == 1
        case .codex:
            // In Codex0.154 an empty composer shows a dim SGR2 placeholder.
            // Typed draft text is not dim; unfamiliar rendering stays unavailable.
            let escape = "\u{1b}"
            let pattern = "^\\s*\(escape)\\[0m\(escape)\\[1m›\(escape)\\[0m \(escape)\\[0m\(escape)\\[2m[^\(escape)\\r\\n]+\(escape)\\[0m\\s*$"
            return lines.filter { $0.range(of: pattern, options: .regularExpression) != nil }.count == 1
        }
    }

    static func sameIdleSession(_ expected: AgentSummary, _ current: AgentSummary) -> Bool {
        expected.paneID == current.paneID && expected.terminalID == current.terminalID &&
        expected.herdrMachine?.id == current.herdrMachine?.id && expected.agentName == current.agentName &&
        expected.sessionReference == current.sessionReference && expected.stateChangeSequence == current.stateChangeSequence &&
        current.state.isQuiescent && current.interactiveReady == true && current.launchPending != true && current.screenDetectionSkipped != true
    }
}
