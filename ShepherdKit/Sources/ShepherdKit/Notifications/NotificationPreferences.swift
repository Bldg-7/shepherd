import Foundation
import Observation

/// Which agent events the person wants notifications for, whether the Dock
/// icon shows the agents waiting for their input, and which machines they
/// want nothing from, kept in the user defaults. Everything is on until
/// turned off: notifications are what the feature is for, and macOS asks
/// the person before the first one is shown.
@MainActor @Observable
public final class NotificationPreferences {
    public static let needsInputKey = "Notifications.agentNeedsInput"
    public static let finishedKey = "Notifications.agentFinished"
    public static let exitedKey = "Notifications.agentExited"
    public static let badgeKey = "Notifications.dockBadge"
    public static let mutedMachinesKey = "Notifications.mutedMachines"

    @ObservationIgnored private let defaults: UserDefaults

    public var notifiesNeedsInput: Bool {
        didSet { defaults.set(notifiesNeedsInput, forKey: Self.needsInputKey) }
    }

    public var notifiesFinished: Bool {
        didSet { defaults.set(notifiesFinished, forKey: Self.finishedKey) }
    }

    public var notifiesExited: Bool {
        didSet { defaults.set(notifiesExited, forKey: Self.exitedKey) }
    }

    /// The number of agents waiting for input on the Dock icon.
    public var showsBadge: Bool {
        didSet { defaults.set(showsBadge, forKey: Self.badgeKey) }
    }

    /// The machines turned off: nothing about them is watched, notified or
    /// counted. Only these are kept, so that a machine added later is on.
    /// A herdr machine goes with the machine it is saved on.
    public private(set) var mutedMachineIDs: Set<UUID> {
        didSet { defaults.set(mutedMachineIDs.map(\.uuidString).sorted(), forKey: Self.mutedMachinesKey) }
    }

    public var kinds: NotificationKinds {
        NotificationKinds(needsInput: notifiesNeedsInput, finished: notifiesFinished, exited: notifiesExited)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifiesNeedsInput = defaults.object(forKey: Self.needsInputKey) as? Bool ?? true
        notifiesFinished = defaults.object(forKey: Self.finishedKey) as? Bool ?? true
        notifiesExited = defaults.object(forKey: Self.exitedKey) as? Bool ?? true
        showsBadge = defaults.object(forKey: Self.badgeKey) as? Bool ?? true
        mutedMachineIDs = Set((defaults.stringArray(forKey: Self.mutedMachinesKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    public func isMuted(_ machineID: UUID) -> Bool {
        mutedMachineIDs.contains(machineID)
    }

    public func setMuted(_ muted: Bool, _ machineID: UUID) {
        guard muted != isMuted(machineID) else { return }
        if muted {
            mutedMachineIDs.insert(machineID)
        } else {
            mutedMachineIDs.remove(machineID)
        }
    }

    /// Forgets machines that are no longer among `machineIDs`: removed ones.
    public func keepMuted(onlyAmong machineIDs: Set<UUID>) {
        let kept = mutedMachineIDs.intersection(machineIDs)
        if kept != mutedMachineIDs {
            mutedMachineIDs = kept
        }
    }
}
