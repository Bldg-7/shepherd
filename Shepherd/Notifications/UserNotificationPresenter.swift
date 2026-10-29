import Foundation
import UserNotifications

/// Whether macOS lets Shepherd show notifications.
nonisolated enum NotificationAuthorization: Equatable, Sendable {
    /// Not asked yet in this run of the app.
    case unknown
    /// The person hasn't been asked yet.
    case notDetermined
    case denied
    case allowed
}

/// The app's one way to the system's notifications — the only file that
/// uses UserNotifications. Shows a notification, takes it away again, sets
/// the Dock icon's badge, asks for permission, and hands a click on a
/// notification to whoever asked for it (see `becomeDelegate`).
final class UserNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private var onOpen: ((NotificationRoute) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    /// Receives clicked notifications from now on, and has notifications
    /// shown while the app is in front, too. To be called before the app
    /// finishes launching, so that a click that launched it isn't missed.
    func becomeDelegate(onOpen: @escaping (NotificationRoute) -> Void) {
        self.onOpen = onOpen
        center.delegate = self
    }

    func authorization() async -> NotificationAuthorization {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional: return .allowed
        @unknown default: return .allowed
        }
    }

    /// Whether the person has turned badges off for Shepherd in System
    /// Settings — or they were never asked for: an app that asked for
    /// permission without them, as Shepherd did before it had a badge.
    func badgesAreOff() async -> Bool {
        await center.notificationSettings().badgeSetting != .enabled
    }

    /// Asks the person, the first time; after that macOS answers by itself
    /// with what they chose.
    func requestAuthorization() async -> NotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await authorization()
    }

    /// The number on the Dock icon; none for 0. Nothing shows while badges
    /// aren't allowed.
    func setBadge(_ count: Int) {
        center.setBadgeCount(max(count, 0)) { @Sendable _ in }
    }

    /// Takes the number off the Dock icon before the app quits, waiting a
    /// moment for it to be done: nothing asynchronous gets to run once the
    /// app is quitting.
    func clearBadgeBeforeQuitting() {
        let done = DispatchSemaphore(value: 0)
        // Not on the main thread, which is waiting.
        center.setBadgeCount(0) { @Sendable _ in done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    /// Shows a notification, in place of one shown before with the same
    /// `identifier`. Asks for permission first if the person hasn't been
    /// asked yet. Returns the permission it went by.
    func present(identifier: String, content: NotificationText.Content, route: NotificationRoute,
                 threadIdentifier: String) async -> NotificationAuthorization {
        var status = await authorization()
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        guard status == .allowed else { return status }
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.subtitle = content.subtitle
        notification.body = content.body
        notification.sound = .default
        notification.threadIdentifier = threadIdentifier
        notification.userInfo = route.userInfo
        try? await center.add(UNNotificationRequest(identifier: identifier, content: notification, trigger: nil))
        return status
    }

    /// Takes away the notifications with these identifiers, from the screen
    /// and from Notification Center.
    func retract(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Takes away every notification about the machines with these IDs,
    /// whichever run of the app showed it.
    func retract(machineIDs: Set<UUID>) async {
        guard !machineIDs.isEmpty else { return }
        let identifiers = await center.deliveredNotifications().compactMap { notification in
            NotificationRoute(userInfo: notification.request.content.userInfo)
                .flatMap { machineIDs.contains($0.machineID) ? notification.request.identifier : nil }
        }
        retract(identifiers: identifiers)
    }

    /// A notification about a pane the person isn't looking at is worth
    /// showing with Shepherd in front too: the coordinator has already left
    /// out the ones about the pane they are looking at.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            onOpen?(route)
        }
    }
}
