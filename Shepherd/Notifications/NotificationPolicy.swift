import Foundation

/// Which kinds of agent event the person wants notifications for (see
/// `NotificationPreferences`).
nonisolated struct NotificationKinds: Equatable, Sendable {
    var needsInput: Bool
    var finished: Bool

    /// Whether there is any notification to give at all.
    var any: Bool { needsInput || finished }
}

/// Whether an agent event that has held is shown, takes back the one shown
/// for its pane, or is dropped. Only the decision: the caller keeps track
/// of what it has shown, and of what the person is looking at.
nonisolated enum NotificationPolicy {
    /// The least time between two notifications of one kind for one pane.
    /// An agent that goes back and forth faster than this is told about
    /// once.
    static let repeatInterval: TimeInterval = 10

    enum Decision: Equatable, Sendable {
        case present
        /// Take away what is shown for the event's pane.
        case retract
        case drop(Reason)
    }

    enum Reason: Equatable, Sendable {
        /// The person has turned this kind off.
        case turnedOff
        /// The person is looking at the pane.
        case viewed
        /// One like it was shown for the pane a moment ago.
        case repeated
        /// Old news.
        case expired
        /// A kind this reader doesn't know, at an urgency that says not to
        /// show it.
        case silent
    }

    /// - `isViewed`: whether the pane is on screen in front of the person.
    /// - `lastPresented`: when a notification of this kind for this pane
    ///   (by `collapse_key`) was last shown, if ever.
    ///
    /// A kind this reader doesn't know goes by its urgency: `attention` is
    /// shown as needing input is, `info` as finishing is, and `silent` not
    /// at all.
    static func decide(_ event: AgentEvent, enabled: NotificationKinds, isViewed: Bool, lastPresented: Date?, now: Date) -> Decision {
        if let expiresAt = event.expiresAt, expiresAt <= now { return .drop(.expired) }
        let wanted: Bool
        switch event.kind {
        case .resumed:
            return .retract
        case .needsInput:
            wanted = enabled.needsInput
        case .finished:
            wanted = enabled.finished
        default:
            switch event.urgency {
            case .attention: wanted = enabled.needsInput
            case .info: wanted = enabled.finished
            default: return .drop(.silent)
            }
        }
        guard wanted else { return .drop(.turnedOff) }
        guard !isViewed else { return .drop(.viewed) }
        if let lastPresented, now.timeIntervalSince(lastPresented) < repeatInterval { return .drop(.repeated) }
        return .present
    }
}
