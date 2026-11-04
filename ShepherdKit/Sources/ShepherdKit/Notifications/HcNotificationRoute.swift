import Foundation

/// Navigation data only. Never a run/kill/input authorization or a routing
/// alias. The app refetches this exact origin before selecting an existing view.
public nonisolated struct HcNotificationRoute: Equatable, Sendable {
    public let machineID: UUID
    public let coreID: String
    public let terminalID: String
    public init(machineID: UUID, coreID: String, terminalID: String) {
        self.machineID = machineID; self.coreID = coreID; self.terminalID = terminalID
    }
    public var userInfo: [String: String] {
        ["hc.machine":machineID.uuidString, "hc.core":coreID, "hc.terminal":terminalID]
    }
    public init?(userInfo: [AnyHashable: Any]) {
        guard let machine = (userInfo["hc.machine"] as? String).flatMap(UUID.init(uuidString:)),
              let core = userInfo["hc.core"] as? String, !core.isEmpty, core.utf8.count <= 256,
              let terminal = userInfo["hc.terminal"] as? String, terminal.range(of: "^t[1-9][0-9bcdfghjkmnpqrstvwxyz]{0,7}$", options: .regularExpression) != nil else { return nil }
        self.init(machineID: machine, coreID: core, terminalID: terminal)
    }
}
