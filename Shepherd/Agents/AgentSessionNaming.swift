import Foundation

/// A pane renamed in this app (Rename Pane, in a row's menu or by a
/// double-click on the title) passes its new name on, once, to the session of
/// the Claude Code or Codex agent in it: the agent's own `/rename <name>`,
/// submitted to it with herdr's `agent.prompt` (bracketed paste, then Enter).
/// That is typed into the agent, so it is held back until the agent is idle
/// or done with nothing in its editor, and checked once more against the same
/// session just before it goes (`AgentSessionNamer`). A Pi launched by this
/// app is named through its extension instead (`PiHostBridge.nameSession`).
///
/// Nothing else is passed on: a name taken away, a tab's name, a rename made
/// in herdr or another client, a pane with no agent in it. Nor is anything
/// kept in step afterwards, or read back from the agent.
nonisolated enum AgentSessionNaming {
    /// The longest name passed on, in characters.
    static let maximumLength = 200

    /// The session name for a pane's new name, or nil for none: without
    /// whitespace at either end, every control character and line break
    /// (U+2028 and U+2029 included) made a space, so that the name stays one
    /// line of the agent's input, and cut to `maximumLength`.
    static func sessionName(from paneName: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in paneName.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        let name = String(String(scalars).trimmingCharacters(in: .whitespaces).prefix(maximumLength))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// What is submitted to Claude Code or Codex for `name`.
    static func command(for name: String) -> String { "/rename " + name }

    /// What to pass on after `commit` went through, or nil for nothing: a
    /// tab, a name taken away, a pane with no agent herdr knows in it.
    @MainActor static func rename(after commit: TitleRenameCommit, machineID: UUID) -> AgentSessionRename? {
        guard case .pane(let pane) = commit.item, let name = sessionName(from: commit.name),
              let kind = pane.agentName.flatMap(AgentKind.init(herdrName:)) else { return nil }
        return AgentSessionRename(machineID: machineID, pane: pane, kind: kind, name: name)
    }

    /// What to do with `rename` given the pane as herdr has it now (`current`,
    /// nil if it isn't listed). The session it was meant for is gone once the
    /// pane, its terminal, its machine, the kind of agent in it or the
    /// agent's session is another; a session herdr doesn't name on either
    /// side is not taken for another one.
    static func verdict(_ rename: AgentSessionRename, current: AgentSummary?) -> AgentSessionRename.Verdict {
        guard let current, current.paneID == rename.paneID, current.terminalID == rename.terminalID,
              current.herdrMachine?.id == rename.herdrMachine?.id,
              current.agentName.flatMap(AgentKind.init(herdrName:)) == rename.kind else { return .discard }
        let session = AgentSessionRename.sessionKey(current)
        if let expected = rename.session, let session, expected != session { return .discard }
        guard current.launchPending != true, current.state.isQuiescent,
              rename.session == nil || session != nil else { return .wait }
        return .apply
    }

    /// Whether the agent's editor is empty in `ansi`, the pane's visible
    /// screen: `AgentIdleStopPolicy.isEmptyEditor`, and for Claude Code also
    /// a prompt showing nothing but a suggestion of its own (a placeholder:
    /// its first character as the cursor, inverted, and the rest dim, or all
    /// of it dim without the terminal's focus). The idle stop before a resume
    /// keeps to the stricter rule.
    static func isEmptyEditor(kind: AgentKind, ansi: String) -> Bool {
        if AgentIdleStopPolicy.isEmptyEditor(kind: kind, ansi: ansi) { return true }
        guard kind == .claude else { return false }
        var lines = ansi.components(separatedBy: .newlines)
        // The editor is the last prompt on screen; the conversation's own
        // prompts are above it.
        guard let index = lines.lastIndex(where: { plain($0).trimmingCharacters(in: .whitespaces).hasPrefix("❯") }),
              showsOnlySuggestion(lines[index]) else { return false }
        lines[index] = "❯"
        return AgentIdleStopPolicy.isEmptyEditor(kind: kind, ansi: lines.joined(separator: "\n"))
    }

    private static func plain(_ ansi: String) -> String {
        ansi.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    /// Whether `line` is Claude Code's prompt with only a placeholder after
    /// it. Typed text is never dim, so a draft — whatever the cursor is on —
    /// is never taken for one.
    static func showsOnlySuggestion(_ line: String) -> Bool {
        let cells = styledCharacters(line).drop(while: { $0.scalar.properties.isWhitespace })
        guard cells.first?.scalar == "❯" else { return false }
        let content = cells.dropFirst().drop(while: { $0.scalar.properties.isWhitespace && !$0.inverse })
        guard let cursor = content.first else { return false }
        let rest = content.dropFirst().filter { !$0.scalar.properties.isWhitespace }
        return (cursor.inverse || cursor.dim) && !rest.isEmpty && rest.allSatisfy(\.dim)
    }

    /// A character of a line of a pane's ANSI, and whether it is drawn dim
    /// (SGR 2) or inverted (SGR 7).
    nonisolated struct StyledCharacter {
        let scalar: Unicode.Scalar
        let dim: Bool
        let inverse: Bool
    }

    /// The characters `line` shows, each with the dim and inverse attributes
    /// its SGR sequences leave it with. Other escape sequences, and control
    /// and format characters, show nothing.
    static func styledCharacters(_ line: String) -> [StyledCharacter] {
        var result: [StyledCharacter] = []
        var dim = false, inverse = false
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            guard scalar == "\u{1b}" else {
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: break
                default: result.append(StyledCharacter(scalar: scalar, dim: dim, inverse: inverse))
                }
                continue
            }
            guard index < scalars.count, scalars[index] == "[" else {
                index += 1 // a two-character escape
                continue
            }
            index += 1
            var parameters = ""
            while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                parameters.unicodeScalars.append(scalars[index])
                index += 1
            }
            guard index < scalars.count else { break }
            let final = scalars[index]
            index += 1
            guard final == "m" else { continue }
            // An empty parameter is 0; one with sub-parameters (`38:2:…`) sets no attribute here.
            var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { $0.isEmpty ? 0 : Int($0) ?? -1 }[...]
            while let code = codes.popFirst() {
                switch code {
                case 0: dim = false; inverse = false
                case 2: dim = true
                case 22: dim = false
                case 7: inverse = true
                case 27: inverse = false
                case 38, 48, 58:
                    // An extended colour's own numbers are not attributes.
                    switch codes.popFirst() {
                    case 5: codes = codes.dropFirst(1)
                    case 2: codes = codes.dropFirst(3)
                    default: break
                    }
                default: break
                }
            }
        }
        return result
    }
}

/// A name to pass on to the session of the agent in a pane, and the session
/// it is for, as the pane was when it was renamed.
nonisolated struct AgentSessionRename: Equatable, Sendable {
    /// One pane: the board keeps one name waiting for each.
    nonisolated struct Key: Hashable, Sendable {
        let machineID: UUID
        let herdrMachineID: String?
        let paneID: String
    }

    nonisolated enum Verdict: Equatable, Sendable {
        /// Check the editor and the session again, and submit the command.
        case apply
        /// Not now: the agent is busy, blocked, unknown or starting.
        case wait
        /// Never: the session it was meant for is gone.
        case discard
    }

    let id = UUID()
    let machineID: UUID
    let herdrMachine: HerdrMachine?
    let paneID: String
    let terminalID: String
    let kind: AgentKind
    /// The agent's session as herdr named it, if it did.
    let session: String?
    let name: String

    init(machineID: UUID, pane: AgentSummary, kind: AgentKind, name: String) {
        self.machineID = machineID
        herdrMachine = pane.herdrMachine
        paneID = pane.paneID
        terminalID = pane.terminalID
        self.kind = kind
        session = Self.sessionKey(pane)
        self.name = name
    }

    var key: Key { Key(machineID: machineID, herdrMachineID: herdrMachine?.id, paneID: paneID) }
    var command: String { AgentSessionNaming.command(for: name) }

    static func sessionKey(_ pane: AgentSummary) -> String? {
        pane.sessionReference.map { $0.kind.rawValue + ":" + $0.value }
    }
}

/// Keeps the names waiting to be passed on, for as long as the app runs, and
/// passes each on when a snapshot of its herdr shows the agent ready for it
/// (`AgentSessionNaming`). One for each pane: a newer rename replaces the
/// one waiting. A blocked agent or a connection that fails is tried again at
/// a later snapshot; one whose session is gone is let go of.
@MainActor final class AgentSessionNamer {
    static let shared = AgentSessionNamer()

    /// A connection of its own for one attempt, made the way the board's
    /// own changes make theirs.
    typealias Connect = @MainActor @Sendable () throws -> HerdrClient

    private(set) var pending: [AgentSessionRename.Key: AgentSessionRename] = [:]
    private var attempts: [AgentSessionRename.Key: Task<Void, Never>] = [:]
    private var lastAttempt: [AgentSessionRename.Key: ContinuousClock.Instant] = [:]
    /// The pane as the last snapshot of its herdr had it, and how to reach
    /// that herdr: for a name that replaced one under way, tried once that
    /// attempt ends rather than at the next snapshot.
    private var lastSeen: [AgentSessionRename.Key: (pane: AgentSummary?, connect: Connect)] = [:]
    /// How long a pane's agent is left alone after an attempt that found it
    /// not ready, however many snapshots come meanwhile: each attempt is a
    /// connection of its own, over SSH for a remote Machine.
    private let retryInterval: Duration

    init(retryInterval: Duration = .seconds(3)) {
        self.retryInterval = retryInterval
    }

    func add(_ rename: AgentSessionRename) {
        pending[rename.key] = rename
        lastAttempt[rename.key] = nil
    }

    /// Takes in a complete snapshot of one herdr's panes — the host's own
    /// (`herdrMachineID` nil) or one of its herdr machines' — on the Machine
    /// with `machineID`.
    func observe(_ panes: [AgentSummary], machineID: UUID, herdrMachineID: String?, connect: @escaping Connect) {
        for (key, rename) in pending where key.machineID == machineID && key.herdrMachineID == herdrMachineID {
            let current = panes.first { $0.paneID == rename.paneID }
            lastSeen[key] = (current, connect)
            consider(rename, current: current, connect: connect)
        }
    }

    /// Lets go of the names waiting for panes on herdr machines the host no
    /// longer has.
    func keep(herdrMachineIDs: Set<String>, machineID: UUID) {
        for key in pending.keys where key.machineID == machineID && key.herdrMachineID.map({ !herdrMachineIDs.contains($0) }) == true {
            forget(key)
        }
    }

    /// Returns once no attempt is under way.
    func settle() async {
        while let attempt = attempts.values.first { await attempt.value }
    }

    private func consider(_ rename: AgentSessionRename, current: AgentSummary?, connect: @escaping Connect) {
        let key = rename.key
        switch AgentSessionNaming.verdict(rename, current: current) {
        case .discard:
            forget(key)
        case .wait:
            break
        case .apply:
            guard attempts[key] == nil,
                  lastAttempt[key].map({ $0.duration(to: .now) >= retryInterval }) ?? true else { break }
            lastAttempt[key] = .now
            attempts[key] = Task { [weak self] in
                await self?.attempt(rename, connect: connect)
            }
        }
    }

    private func forget(_ key: AgentSessionRename.Key) {
        pending[key] = nil
        lastAttempt[key] = nil
        lastSeen[key] = nil
    }

    private func attempt(_ rename: AgentSessionRename, connect: Connect) async {
        let outcome: AgentSessionRename.Verdict
        do {
            outcome = await Self.submit(rename, using: try connect()) { [weak self] in self?.pending[rename.key]?.id == rename.id }
        } catch {
            outcome = .wait
        }
        let key = rename.key
        attempts[key] = nil
        if let newer = pending[key], newer.id != rename.id {
            // Renamed again meanwhile: the newer name, by the pane last seen.
            if let seen = lastSeen[key] { consider(newer, current: seen.pane, connect: seen.connect) }
        } else if outcome != .wait {
            // Sent, or never to be.
            forget(key)
        }
    }

    /// One attempt over a new connection: the editor must be empty, and the
    /// agent, read again just before, the same session idle or done. `.apply`
    /// for the command submitted.
    static func submit(_ rename: AgentSessionRename, using client: HerdrClient,
                       stillWanted: @MainActor () -> Bool) async -> AgentSessionRename.Verdict {
        do {
            try await client.connect()
            let screen = try await client.visiblePaneANSI(paneID: rename.paneID, on: rename.herdrMachine)
            guard AgentSessionNaming.isEmptyEditor(kind: rename.kind, ansi: screen) else {
                await client.disconnect()
                return .wait
            }
            let agent = try await client.agentGet(paneID: rename.paneID, on: rename.herdrMachine)
            let verdict = AgentSessionNaming.verdict(rename, current: agent)
            // Replaced while this one was under way: the newer one goes by itself.
            guard verdict == .apply, stillWanted() else {
                await client.disconnect()
                return verdict == .discard ? .discard : .wait
            }
            try await client.agentPrompt(paneID: rename.paneID, text: rename.command, on: rename.herdrMachine)
            await client.disconnect()
            return .apply
        } catch let error as HerdrErrorPayload where ["agent_not_found", "pane_not_found"].contains(error.code) {
            await client.disconnect()
            return .discard
        } catch {
            // agent_blocked, a timeout, a connection that failed: next time.
            await client.disconnect()
            return .wait
        }
    }
}
