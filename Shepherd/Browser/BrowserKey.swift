#if os(macOS)
import Foundation

/// Which pane a browser belongs to. A pane ID like "w1:p1" exists in every
/// herdr, so it is qualified by everything that tells one herdr from another
/// (plan item B1 in docs/agent-browser-plan.md): the Shepherd Machine, the
/// herdr machine behind it if any, and the herdr session.
nonisolated struct BrowserKey: Hashable, Codable, Sendable {
    let machineID: UUID
    /// `HerdrMachine.id` of the herdr machine the pane is on, or nil for the
    /// host's own herdr.
    let herdrMachineID: String?
    /// The herdr session, "default" for herdr's default one — the name the
    /// shepherd-browser skill derives from `HERDR_SOCKET_PATH` (B5).
    let session: String
    let paneID: String

    init(machineID: UUID, herdrMachineID: String?, session: String, paneID: String) {
        self.machineID = machineID
        self.herdrMachineID = herdrMachineID
        self.session = session
        self.paneID = paneID
    }

    func replacingPaneID(_ paneID: String) -> BrowserKey {
        BrowserKey(machineID: machineID, herdrMachineID: herdrMachineID, session: session, paneID: paneID)
    }

    init(machine: Machine, pane: AgentSummary) {
        self.machineID = machine.id
        self.herdrMachineID = pane.herdrMachine?.id
        self.session = Self.session(named: pane.herdrMachine?.session ?? machine.sessionName)
        self.paneID = pane.paneID
    }

    /// A herdr session's name as a key has it: "default" for herdr's
    /// default session, which a Machine leaves unnamed.
    static func session(named name: String) -> String {
        name.isEmpty ? "default" : name
    }

    /// Whether the pane is one of those `reconcile` was told about: on the
    /// same Machine and herdr machine.
    func isOn(machineID: UUID, herdrMachineID: String?) -> Bool {
        self.machineID == machineID && self.herdrMachineID == herdrMachineID
    }
}

/// Where a pane browser keeps cookies, logins and the rest of what sites
/// store (decision 1): a profile of its own, or the one all panes can share.
nonisolated enum ProfileChoice: Hashable, Codable, Sendable {
    /// A folder of its own, named by `folder`, deleted with the pane (F11).
    case isolated(folder: String)
    case shared

    private static let isolatedFolderPrefix = "Pane-"

    static func newIsolated() -> ProfileChoice {
        .isolated(folder: isolatedFolderPrefix + UUID().uuidString)
    }

    /// Whether a folder in the browser's root folder is a pane's profile —
    /// rather than one of the many Chromium keeps there itself.
    static func isIsolatedFolderName(_ name: String) -> Bool {
        name.hasPrefix(isolatedFolderPrefix)
    }

    /// The name of the profile's folder, which is right inside the browser's
    /// root folder (see `BrowserStore.rootFolder`).
    var folderName: String {
        switch self {
        case .isolated(let folder): folder
        case .shared: "Shared"
        }
    }

    /// The folder of a profile that is the pane's own; nil for the shared
    /// one.
    var isolatedFolder: String? {
        if case .isolated(let folder) = self { folder } else { nil }
    }

    var isShared: Bool {
        if case .shared = self { true } else { false }
    }
}

/// What is kept of one pane browser across launches, in `browsers.json`: so
/// that its tabs come back with the app, and so that its profile folder can
/// be found and deleted once the pane is gone, even when that happens while
/// the app isn't running (F9, F11).
nonisolated struct BrowserRecord: Codable, Sendable {
    var key: BrowserKey
    /// The terminal in the pane when the browser was opened. A pane with the
    /// same ID but another terminal is another pane (B3).
    var terminalID: String
    var profile: ProfileChoice
    var tabURLs: [String]
    var selectedTab: Int
}

/// The contents of `browsers.json`.
nonisolated struct BrowserIndex: Codable, Sendable {
    var browsers: [BrowserRecord] = []
    /// Profile folders to delete, by name. A folder is only
    /// deleted once nothing uses it any more; the ones that couldn't be by
    /// the time the app quit are deleted at the next launch.
    var foldersToDelete: [String] = []
    var aliases: [BrowserAlias]? = nil
}

nonisolated struct BrowserAlias: Codable, Sendable {
    let previous: BrowserKey
    let current: BrowserKey
    let terminalID: String
}
#endif
