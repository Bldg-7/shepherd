import Foundation

/// One herdr server, as notifications tell them apart: a machine's own
/// herdr, or one of the herdr machines it reaches (see `HerdrMachine`).
public nonisolated struct NotificationServerKey: Hashable, Sendable {
    public init(connection: Machine.ConnectionIdentity, herdrMachineID: String?) {
        self.connection = connection
        self.herdrMachineID = herdrMachineID
    }

    public let connection: Machine.ConnectionIdentity
    /// The herdr machine's profile ID, or nil for the machine's own herdr.
    public let herdrMachineID: String?
}

/// One pane, as notifications tell them apart: its terminal, which its
/// herdr server never uses for another.
public nonisolated struct NotificationPaneKey: Hashable, Sendable {
    public let server: NotificationServerKey
    public let terminalID: String

    public init(server: NotificationServerKey, terminalID: String) {
        self.server = server
        self.terminalID = terminalID
    }

    /// A pane listed on the board of `connection`'s machine.
    public init(_ pane: AgentSummary, on connection: Machine.ConnectionIdentity) {
        self.init(server: NotificationServerKey(connection: connection, herdrMachineID: pane.herdrMachine?.id),
                  terminalID: pane.terminalID)
    }
}

/// Where a click on a notification takes the person: the pane it was about,
/// on the machine it is on. Kept in the notification itself, so that it
/// still leads there after the app has started over.
public nonisolated struct NotificationRoute: Equatable, Sendable {
    public let machineID: UUID
    public let herdrMachineID: String?
    public let paneID: String
    public let terminalID: String

    public init(machineID: UUID, herdrMachineID: String?, paneID: String, terminalID: String) {
        self.machineID = machineID
        self.herdrMachineID = herdrMachineID
        self.paneID = paneID
        self.terminalID = terminalID
    }

    /// The pane's ID as the board has it (`AgentSummary.id`).
    public var boardPaneID: String {
        herdrMachineID.map { "\($0)/\(paneID)" } ?? paneID
    }

    private enum Key {
        static let machine = "shepherd.machine"
        static let herdrMachine = "shepherd.herdr-machine"
        static let pane = "shepherd.pane"
        static let terminal = "shepherd.terminal"
    }

    public var userInfo: [String: String] {
        var info = [Key.machine: machineID.uuidString, Key.pane: paneID, Key.terminal: terminalID]
        info[Key.herdrMachine] = herdrMachineID
        return info
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let machine = (userInfo[Key.machine] as? String).flatMap(UUID.init(uuidString:)),
              let pane = userInfo[Key.pane] as? String,
              let terminal = userInfo[Key.terminal] as? String else { return nil }
        self.init(machineID: machine, herdrMachineID: userInfo[Key.herdrMachine] as? String, paneID: pane, terminalID: terminal)
    }
}

/// A clicked notification's pane, for as long as the window is on its way
/// there (see `ContentView`).
public struct NotificationNavigationRequest: Equatable {
    public let id = UUID()
    public let route: NotificationRoute
    /// Whether the active machine was switched to the pane's machine for it
    /// already. Once it has been, the active machine changing again is the
    /// person going elsewhere, and the request is given up.
    public var switchedMachine = false

    public init(route: NotificationRoute, switchedMachine: Bool = false) {
        self.route = route
        self.switchedMachine = switchedMachine
    }
}
