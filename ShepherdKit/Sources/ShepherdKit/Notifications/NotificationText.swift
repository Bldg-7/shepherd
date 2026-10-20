import Foundation

/// What a notification for an agent event says, in the app's language: the
/// event's kind and agent as its title, the machine as its subtitle where
/// there is more than one to tell apart, and the pane's title and its
/// workspace's name as its body. The event carries only what these are made
/// of (see `AgentEvent.Display`).
public nonisolated enum NotificationText {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let subtitle: String
        public let body: String
    }

    /// Nil for an event that isn't shown (`agent.resumed`, or a kind this
    /// reader doesn't know whose urgency says not to). `showsMachine` puts
    /// the machine's name in the subtitle.
    public static func content(for event: AgentEvent, showsMachine: Bool) -> Content? {
        guard let title = title(for: event) else { return nil }
        let display = event.display
        let subtitle = showsMachine ? display.machineLabel ?? "" : ""
        let body = [display.paneTitle, display.workspaceLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return Content(title: title, subtitle: subtitle, body: body)
    }

    private static func title(for event: AgentEvent) -> String? {
        let agent = event.display.agentName.flatMap { $0.isEmpty ? nil : $0 } ?? event.subject.agent
        switch event.kind {
        case .needsInput:
            return agent.map { String(localized: "\($0) needs your input", bundle: .shepherdKit) } ?? String(localized: "An agent needs your input", bundle: .shepherdKit)
        case .finished:
            return agent.map { String(localized: "\($0) finished", bundle: .shepherdKit) } ?? String(localized: "An agent finished", bundle: .shepherdKit)
        case .resumed:
            return nil
        default:
            switch event.urgency {
            case .attention:
                return agent.map { String(localized: "\($0) needs your attention", bundle: .shepherdKit) } ?? String(localized: "An agent needs your attention", bundle: .shepherdKit)
            case .info:
                return agent.map { String(localized: "\($0) has an update", bundle: .shepherdKit) } ?? String(localized: "An agent has an update", bundle: .shepherdKit)
            default:
                return nil
            }
        }
    }
}
