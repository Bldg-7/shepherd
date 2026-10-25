import Foundation

public protocol MachineSecretStore {
    func saveSecret(_ data: Data, tag: String) throws
    func loadSecret(tag: String) throws -> Data?
    func deleteSecret(tag: String) throws
}

public struct KeychainStore: MachineSecretStore {
    public init() {}
    public func saveSecret(_ data: Data, tag: String) throws {}
    public func loadSecret(tag: String) throws -> Data? { nil }
    public func deleteSecret(tag: String) throws {}
}

public nonisolated struct HerdrMachine: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let target: String
    public let session: String
    public let enabled: Bool
    public init(id: String, label: String, target: String, session: String, enabled: Bool) {
        self.id = id; self.label = label; self.target = target; self.session = session; self.enabled = enabled
    }
}

public nonisolated enum AgentState: String, Sendable { case idle, working, blocked, done, unknown }

public nonisolated struct AgentSummary: Identifiable, Equatable, Sendable {
    public let paneID: String
    public let previousPaneID: String?
    public let tabID: String?
    public let workspaceID: String?
    public let terminalID: String
    public let herdrMachine: HerdrMachine?
    public let source: String?
    public let interactiveReady: Bool?
    public let launchPending: Bool?
    public let screenDetectionSkipped: Bool?
    public let stateChangeSequence: Int?
    public let agentName: String?
    public let terminalTitle: String?
    public let label: String?
    public let workingDirectory: String?
    public let state: AgentState
    public let revision: Int
    public var id: String { herdrMachine.map { "\($0.id)/\(paneID)" } ?? paneID }
    public init(label: String, herdrMachine: HerdrMachine? = nil) {
        paneID = "pane"; previousPaneID = nil; tabID = nil; workspaceID = nil; terminalID = "terminal"
        self.herdrMachine = herdrMachine; source = "harness"; interactiveReady = true; launchPending = false
        screenDetectionSkipped = false; stateChangeSequence = 1; agentName = "fixture"; terminalTitle = label
        self.label = label; workingDirectory = "/owned"; state = .working; revision = 1
    }
}

public nonisolated struct PanePlacement: Equatable, Sendable {
    public let paneID: String; public let x: Double; public let y: Double; public let width: Double; public let height: Double
}
public nonisolated struct TabSummary: Identifiable, Equatable, Sendable {
    public let tabID: String; public let workspaceID: String?; public let label: String; public let focusedPaneID: String?
    public let panes: [AgentSummary]; public let placements: [PanePlacement]
    public var id: String { tabID }
}
public nonisolated struct WorkspaceSummary: Identifiable, Equatable, Sendable {
    public let workspaceID: String; public let label: String; public var id: String { workspaceID }
}

@MainActor public final class MachineMonitor {
    public nonisolated struct HerdrMachineGroup: Identifiable, Equatable, Sendable {
        public let machine: HerdrMachine
        public var agents: [AgentSummary]
        public var tabs: [TabSummary]?
        public var workspaces: [WorkspaceSummary]?
        public var error: String?
        public var hasLoaded: Bool
        public var id: String { machine.id }
        public init(machine: HerdrMachine, agents: [AgentSummary] = [], tabs: [TabSummary]? = nil, workspaces: [WorkspaceSummary]? = nil, error: String? = nil, hasLoaded: Bool = false) {
            self.machine = machine; self.agents = agents; self.tabs = tabs; self.workspaces = workspaces; self.error = error; self.hasLoaded = hasLoaded
        }
    }
    public nonisolated enum SnapshotPublication: Sendable, Equatable { case host, herdrMachines }
    public var panes: [AgentSummary] = []
    public var tabs: [TabSummary]?
    public var workspaces: [WorkspaceSummary]?
    public var herdrMachineGroups: [HerdrMachineGroup] = []
    public var hasLoaded = false
}

@MainActor public final class MachineMonitors {
    public static let shared = MachineMonitors()
    private var monitors: [Machine.ConnectionIdentity: MachineMonitor] = [:]
    public var observePublication: (@MainActor (Machine, MachineMonitor.SnapshotPublication) -> Void)?
    private init() {}
    public func monitor(for machine: Machine, in store: MachineStore) -> MachineMonitor {
        if let monitor = monitors[machine.connectionIdentity] { return monitor }
        let monitor = MachineMonitor(); monitors[machine.connectionIdentity] = monitor; return monitor
    }
    public func publish(_ scope: MachineMonitor.SnapshotPublication, for machine: Machine, in store: MachineStore) {
        _ = monitor(for: machine, in: store)
        observePublication?(machine, scope)
    }
}
