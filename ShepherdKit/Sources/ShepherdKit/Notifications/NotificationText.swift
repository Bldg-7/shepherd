import Foundation

/// What a notification says: its title, subtitle and body.
public nonisolated enum NotificationText {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let subtitle: String
        public let body: String
        public init(title: String, subtitle: String, body: String) {
            self.title = title; self.subtitle = subtitle; self.body = body
        }
    }
}
