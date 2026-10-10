import Foundation

enum AgentState: String, Codable, Sendable {
    case idle
    case working
    case blocked
    case done
    case unknown

    /// herdr idle/done are input-ready candidates (seen/unseen presentation).
    /// This alone proves neither safe restart nor persisted conversation.
    nonisolated var isQuiescent: Bool {
        switch self {
        case .idle, .done: true
        case .working, .blocked, .unknown: false
        }
    }

    /// How the status reads on screen. The raw value is herdr's wire name,
    /// not something to show a person — least of all in another language.
    var title: LocalizedStringResource {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Blocked"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }
}

/// Status-board row: one pane from herdr's `session.snapshot` (or, from a
/// herdr too old for that, `pane.list`), together with the agent herdr
/// recognises in it — or none, for a pane that is a plain terminal (a shell,
/// a dev server). Verified against a real `herdr 0.9.1` instance's
/// `agent.list` response on 2026-10-01 and its `pane.list` and
/// `session.snapshot` responses on 2026-10-03, which give every pane in the
/// same shape — the
/// field names below
/// (terminal_id/agent/terminal_title_stripped/agent_status/agent_session.source/revision/cwd)
/// are confirmed, not guessed.
///
/// `Equatable` so that a refresh can tell "the same pane, unchanged" from
/// "the same pane, with news" and leave the former alone. It is deliberately
/// not `Hashable`, and never a selection value: anything keyed on the whole
/// summary would lose track of a pane the moment its state, title or revision
/// changed — a pane is identified by `id` alone.
nonisolated struct AgentSummary: Identifiable, Equatable, Sendable {
    let paneID: String
    let previousPaneID: String?
    /// The tab the pane is in. Nil only from a herdr that doesn't say.
    let tabID: String?
    /// The workspace the pane is in. Nil only from a herdr that doesn't say.
    let workspaceID: String?
    /// The terminal running in the pane, which is what an attach connects
    /// to (`herdr terminal attach`). herdr's `agent attach` gets there from
    /// the pane by way of its agent, so a pane with no agent can only be
    /// attached to by this.
    let terminalID: String
    /// The herdr machine the pane is on, or nil for the host's own herdr.
    /// Pane IDs are only unique within one herdr server, so "w1:p1" on the
    /// host and "w1:p1" on a machine are different panes.
    let herdrMachine: HerdrMachine?
    let source: String?
    let sessionReference: AgentSessionReference?
    let interactiveReady: Bool?
    let launchPending: Bool?
    let screenDetectionSkipped: Bool?
    let stateChangeSequence: Int?
    /// The agent herdr recognises in the pane, or nil for a pane it has
    /// recognised none in.
    let agentName: String?
    let terminalTitle: String?
    /// The name the pane was given (`pane.rename`), if it was given one.
    let label: String?
    /// The working directory of what runs in the pane — of the program in
    /// the foreground when herdr knows it, the shell's otherwise.
    let workingDirectory: String?
    /// herdr reports `unknown` for a pane with no agent, so for one of
    /// those this says nothing (see `hasAgent`).
    let state: AgentState
    /// Bumps whenever the pane's output/state changes — used as the
    /// `min_revision` watermark for `events.wait` long-polling.
    let revision: Int

    /// The pane ID, qualified by the herdr machine it is on.
    var id: String { herdrMachine.map { "\($0.id)/\(paneID)" } ?? paneID }

    /// Whether an agent runs in the pane.
    var hasAgent: Bool { agentName != nil }

    /// What the pane is called on screen: the name it was given, else the
    /// title of what runs in it.
    var automaticTitle: String {
        terminalTitle.map { AgentTitleDisplay.terminal($0, agentName: agentName) } ?? agentName ?? paneID
    }
    var title: String { label ?? automaticTitle }

    init?(json: JSONValue, on herdrMachine: HerdrMachine? = nil) {
        guard let paneID = json["pane_id"]?.stringValue, !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let terminalID = json["terminal_id"]?.stringValue, !terminalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.paneID = paneID
        self.previousPaneID = json["previous_pane_id"]?.stringValue
        self.tabID = json["tab_id"]?.stringValue
        self.workspaceID = json["workspace_id"]?.stringValue
        self.terminalID = terminalID
        self.herdrMachine = herdrMachine
        self.source = json["agent_session"]?["source"]?.stringValue
        self.sessionReference = json["agent_session"].flatMap(AgentSessionReference.init(json:))
        if case .bool(let ready) = json["interactive_ready"] { self.interactiveReady = ready } else { self.interactiveReady = nil }
        if case .bool(let pending) = json["launch_pending"] { self.launchPending = pending } else { self.launchPending = nil }
        if case .bool(let skipped) = json["screen_detection_skipped"] { self.screenDetectionSkipped = skipped } else { self.screenDetectionSkipped = nil }
        self.stateChangeSequence = json["state_change_seq"]?.intValue
        self.agentName = json["agent"]?.stringValue
        self.terminalTitle = json["terminal_title_stripped"]?.stringValue
        self.label = json["label"]?.stringValue
        self.workingDirectory = json["foreground_cwd"]?.stringValue ?? json["cwd"]?.stringValue
        self.revision = json["revision"]?.intValue ?? 0
        if let rawState = json["agent_status"]?.stringValue, let state = AgentState(rawValue: rawState) {
            self.state = state
        } else {
            self.state = .unknown
        }
    }

    private init(paneID: String, terminalID: String, source: String?, agentName: String?, terminalTitle: String?, workingDirectory: String?, state: AgentState, revision: Int) {
        self.paneID = paneID
        self.previousPaneID = nil
        self.tabID = nil
        self.workspaceID = nil
        self.terminalID = terminalID
        self.herdrMachine = nil
        self.source = source
        self.sessionReference = nil
        self.interactiveReady = nil
        self.launchPending = nil
        self.screenDetectionSkipped = nil
        self.stateChangeSequence = nil
        self.agentName = agentName
        self.terminalTitle = terminalTitle
        self.label = nil
        self.workingDirectory = workingDirectory
        self.state = state
        self.revision = revision
    }

    static let preview = AgentSummary(
        paneID: "w1:p1",
        terminalID: "term_1",
        source: "herdr:claude",
        agentName: "claude",
        terminalTitle: "DEMO-1781",
        workingDirectory: "/Users/example/Projects/demo",
        state: .working,
        revision: 1
    )
}
