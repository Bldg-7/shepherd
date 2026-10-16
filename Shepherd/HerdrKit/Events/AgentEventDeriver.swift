import Foundation

/// One pane as one look at a herdr server found it: what `AgentEventDeriver`
/// compares with the look before.
nonisolated struct AgentObservation: Equatable, Sendable {
    var paneID: String
    var terminalID: String
    var tabID: String?
    var workspaceID: String?
    /// The agent herdr recognises in the pane, or nil for a plain terminal.
    var agent: String?
    var state: AgentState
    var stateChangeSeq: Int?
    var paneTitle: String
    var tabLabel: String?
    var workspaceLabel: String?

    /// Every pane of one herdr's snapshot, with the names of the tab and the
    /// workspace it is in.
    static func all(panes: [AgentSummary], tabs: [TabSummary]?, workspaces: [WorkspaceSummary]?) -> [AgentObservation] {
        let tabLabels = Dictionary((tabs ?? []).map { ($0.tabID, $0.title) }, uniquingKeysWith: { first, _ in first })
        let workspaceLabels = Dictionary((workspaces ?? []).map { ($0.workspaceID, $0.label) }, uniquingKeysWith: { first, _ in first })
        return panes.map { pane in
            AgentObservation(
                paneID: pane.paneID,
                terminalID: pane.terminalID,
                tabID: pane.tabID,
                workspaceID: pane.workspaceID,
                agent: pane.agentName,
                state: pane.state,
                stateChangeSeq: pane.stateChangeSequence,
                paneTitle: pane.title,
                tabLabel: pane.tabID.flatMap { tabLabels[$0] },
                workspaceLabel: pane.workspaceID.flatMap { workspaceLabels[$0] }
            )
        }
    }
}

/// The herdr server a deriver looks at, and what goes into the events it
/// makes besides what each pane says.
nonisolated struct AgentEventSource: Equatable, Sendable {
    var herdr: AgentEvent.HerdrInstance
    /// The name of the machine the server runs on, as the person knows it.
    var machineLabel: String?
    var producer: AgentEvent.Producer
}

/// Turns looks at one herdr server into events: compares each look with the
/// one before, pane by pane, and makes an event for each change of status
/// that one is made for. Only the comparison: when to look, and whether a
/// change has held long enough to be told about, is up to its caller.
///
/// - A pane is its terminal, so a pane ID that comes back with another
///   terminal in it is another pane. And within a pane, one agent: a
///   change is only one when the same agent is there before and after.
/// - The first look at a pane says how it is, not what changed: nothing
///   comes of it. The same goes for a whole look that is a baseline — the
///   first after connecting (the caller says so), one after a gap longer
///   than `maximumGap`, or one in which herdr's change count went back,
///   which it only does when the server has started over.
/// - `unknown` says nothing about an agent, and is passed over: a change
///   is from the last status that wasn't.
/// - An agent that finishes within `startupGrace` of being first seen in
///   its pane is only starting up, and that isn't told about.
nonisolated struct AgentEventDeriver: Sendable {
    static let startupGrace: TimeInterval = 10
    static let maximumGap: TimeInterval = 60
    /// How long an event stays worth showing (`expires_at`).
    static let lifetime: TimeInterval = 3600

    var source: AgentEventSource
    private(set) var lastObservedAt: Date?
    /// By terminal ID.
    private var panes: [String: Memory] = [:]

    private struct Memory: Sendable {
        var observation: AgentObservation
        /// The last status that wasn't `unknown`, if there was one.
        var knownState: AgentState?
        /// When the agent was first seen in the pane, if that was after a
        /// baseline — otherwise it was there all along.
        var agentSince: Date?
        /// When the agent last started working, if that was seen.
        var workingSince: Date?
    }

    init(source: AgentEventSource) {
        self.source = source
    }

    /// The events `observations`, made `now`, give rise to — none for a
    /// baseline (see the type's notes).
    mutating func observe(_ observations: [AgentObservation], at now: Date, asBaseline: Bool = false) -> [AgentEvent] {
        let gap = lastObservedAt.map { now.timeIntervalSince($0) } ?? .infinity
        lastObservedAt = now
        let restarted = observations.contains { observation in
            guard let sequence = observation.stateChangeSeq,
                  let previous = panes[observation.terminalID]?.observation.stateChangeSeq else { return false }
            return sequence < previous
        }
        if asBaseline || gap > Self.maximumGap || restarted {
            panes = [:]
            for observation in observations where panes[observation.terminalID] == nil {
                panes[observation.terminalID] = Memory(
                    observation: observation,
                    knownState: observation.state == .unknown ? nil : observation.state
                )
            }
            return []
        }
        var next: [String: Memory] = [:]
        var events: [AgentEvent] = []
        for observation in observations where next[observation.terminalID] == nil {
            guard var memory = panes[observation.terminalID], memory.observation.agent == observation.agent else {
                // A pane opened since the last look, or an agent that came,
                // went or was replaced in it.
                next[observation.terminalID] = Memory(
                    observation: observation,
                    knownState: observation.state == .unknown ? nil : observation.state,
                    agentSince: observation.agent == nil ? nil : now,
                    workingSince: observation.state == .working ? now : nil
                )
                continue
            }
            memory.observation = observation
            if observation.agent != nil, observation.state != .unknown {
                if let previous = memory.knownState, previous != observation.state,
                   let kind = Self.kind(from: previous, to: observation.state) {
                    let startingUp = memory.agentSince.map { now.timeIntervalSince($0) < Self.startupGrace } ?? false
                    if !(kind == .finished && startingUp) {
                        let worked = kind == .finished ? memory.workingSince.map { Int(now.timeIntervalSince($0)) } : nil
                        events.append(event(kind, for: observation, from: previous, at: now, workedSeconds: worked))
                    }
                }
                if observation.state == .working, memory.knownState != .working {
                    memory.workingSince = now
                }
                memory.knownState = observation.state
            }
            next[observation.terminalID] = memory
        }
        panes = next
        return events
    }

    /// The pane in `terminalID` as last seen.
    func latest(terminalID: String) -> AgentObservation? {
        panes[terminalID]?.observation
    }

    /// What a change from one status to another is, if anything.
    static func kind(from previous: AgentState, to current: AgentState) -> AgentEvent.Kind? {
        switch (previous, current) {
        case (.blocked, .blocked), (.working, .working): nil
        case (_, .blocked): .needsInput
        case (.working, .idle), (.working, .done), (.blocked, .idle), (.blocked, .done): .finished
        case (_, .working): .resumed
        default: nil
        }
    }

    /// Whether the pane `event` is about is still as the event says,
    /// in another look at its herdr taken since.
    static func stillHolds(_ event: AgentEvent, in observations: [AgentObservation]) -> Bool {
        guard let pane = observations.first(where: { $0.terminalID == event.subject.terminalID }),
              pane.agent == event.subject.agent else { return false }
        switch event.kind {
        case .needsInput: return pane.state == .blocked
        case .finished: return pane.state == .idle || pane.state == .done
        case .resumed: return pane.state == .working
        default: return false
        }
    }

    private func event(_ kind: AgentEvent.Kind, for pane: AgentObservation, from previous: AgentState,
                       at now: Date, workedSeconds: Int?) -> AgentEvent {
        let observedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let instanceID = source.herdr.instanceID
        return AgentEvent(
            id: AgentEvent.identifier(instanceID: instanceID, terminalID: pane.terminalID,
                                      stateChangeSeq: pane.stateChangeSeq, observedAt: observedAt, kind: kind),
            kind: kind,
            urgency: kind.urgency ?? .info,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(Self.lifetime),
            subject: AgentEvent.Subject(
                herdr: source.herdr,
                terminalID: pane.terminalID,
                paneID: pane.paneID,
                tabID: pane.tabID,
                workspaceID: pane.workspaceID,
                agent: pane.agent,
                collapseKey: AgentEvent.collapseKey(instanceID: instanceID, terminalID: pane.terminalID)
            ),
            transition: AgentEvent.Transition(from: previous.rawValue, to: pane.state.rawValue,
                                              stateChangeSeq: pane.stateChangeSeq, workedSeconds: workedSeconds),
            display: AgentEvent.Display(agentName: pane.agent, paneTitle: pane.paneTitle, tabLabel: pane.tabLabel,
                                        workspaceLabel: pane.workspaceLabel, machineLabel: source.machineLabel),
            producer: source.producer
        ).fittedToSizeLimit()
    }
}
