import Foundation
import Observation

/// Which agent events the person wants notifications for, kept in the
/// user defaults. Both are on until turned off: notifications are what the
/// feature is for, and macOS asks the person before the first one is shown.
@MainActor @Observable
final class NotificationPreferences {
    static let needsInputKey = "Notifications.agentNeedsInput"
    static let finishedKey = "Notifications.agentFinished"

    @ObservationIgnored private let defaults: UserDefaults

    var notifiesNeedsInput: Bool {
        didSet { defaults.set(notifiesNeedsInput, forKey: Self.needsInputKey) }
    }

    var notifiesFinished: Bool {
        didSet { defaults.set(notifiesFinished, forKey: Self.finishedKey) }
    }

    var kinds: NotificationKinds {
        NotificationKinds(needsInput: notifiesNeedsInput, finished: notifiesFinished)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifiesNeedsInput = defaults.object(forKey: Self.needsInputKey) as? Bool ?? true
        notifiesFinished = defaults.object(forKey: Self.finishedKey) as? Bool ?? true
    }
}
