import Foundation

/// A herdr in memory for one pane's agent: what `agent.get` answers, what the
/// screen shows, and every `agent.prompt` and CLI command it is given — over
/// the socket API for the host's own panes, through `herdr --machine` for a
/// herdr machine's.
actor NamingHerdr: HerdrTransport {
    var agentRow: [String: JSONValue] = [:]
    var agentError: String?
    var screen = ""
    var readDelay: Duration = .zero
    var promptError: String?
    var connectFailure = false
    private(set) var prompts: [(paneID: String, text: String)] = []
    private(set) var commands: [[String]] = []
    private(set) var connects = 0
    private(set) var disconnects = 0

    func setAgent(_ row: [String: JSONValue]) { agentRow = row; agentError = nil }
    func setAgentError(_ code: String?) { agentError = code }
    func setScreen(_ text: String) { screen = text }
    func setReadDelay(_ delay: Duration) { readDelay = delay }
    func setPromptError(_ code: String?) { promptError = code }
    func setConnectFailure(_ failing: Bool) { connectFailure = failing }

    func connect() async throws {
        connects += 1
        if connectFailure { throw HostScriptError(status: 255, message: "ssh: connect to host owned.invalid: Connection refused") }
    }
    func disconnect() async { disconnects += 1 }

    func send(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "agent.get":
            if let agentError { throw HerdrErrorPayload(code: agentError, message: agentError) }
            return .object(["type": .string("agent_info"), "agent": .object(agentRow)])
        case "pane.read":
            if readDelay > .zero { try await Task.sleep(for: readDelay) }
            return .object(["type": .string("pane_read"), "read": .object(["pane_id": params["pane_id"] ?? .null, "text": .string(screen)])])
        case "agent.prompt":
            if let promptError { throw HerdrErrorPayload(code: promptError, message: promptError) }
            prompts.append((params["target"]?.stringValue ?? "", params["text"]?.stringValue ?? ""))
            return .object(["type": .string("ok")])
        default:
            throw HerdrErrorPayload(code: "unexpected", message: method)
        }
    }

    func runHerdr(_ arguments: [String]) async throws -> Data {
        commands.append(arguments)
        guard arguments.count >= 5, arguments[0] == "--machine" else { throw HerdrCommandError(status: 2, message: "unexpected herdr \(arguments)") }
        let command = Array(arguments[2...3]), paneID = arguments[4]
        func envelope(error code: String?, result: JSONValue) throws -> Data {
            guard let code else { return try JSONEncoder().encode(JSONValue.object(["result": result])) }
            return try JSONEncoder().encode(JSONValue.object(["error": .object(["code": .string(code), "message": .string(code)])]))
        }
        if command == ["pane", "read"] {
            if readDelay > .zero { try await Task.sleep(for: readDelay) }
            return Data(screen.utf8)
        }
        if command == ["agent", "get"] {
            return try envelope(error: agentError, result: .object(["type": .string("agent_info"), "agent": .object(agentRow)]))
        }
        if command == ["agent", "prompt"] {
            if promptError == nil { prompts.append((paneID, arguments.count > 5 ? arguments[5] : "")) }
            return try envelope(error: promptError, result: .object(["type": .string("ok")]))
        }
        throw HerdrCommandError(status: 2, message: "unexpected herdr \(arguments)")
    }

    func runScript(_ script: String) async throws -> Data {
        throw HostScriptError(status: 127, message: "no scripts here")
    }
}

@main struct SessionNamingTests {
    static var passed = 0

    static func check(_ value: Bool, _ name: String) {
        precondition(value, "FAIL: " + name)
        passed += 1
        print("PASS: " + name)
    }

    static let machineID = UUID()
    static let remote = HerdrMachine(id: "owned-remote", label: "Owned", target: "owned.invalid", session: "default", enabled: true)
    static let emptyClaude = "\u{1b}[0m╭───╮\n\u{1b}[0m❯ \u{1b}[7m \u{1b}[0m\n\u{1b}[0m╰───╯\n  ? for shortcuts"
    static let emptyCodex = "\u{1b}[0m\u{1b}[1m›\u{1b}[0m \u{1b}[0m\u{1b}[2mAsk Codex to do anything\u{1b}[0m"

    static func row(pane: String = "w1:p1", terminal: String = "term-1", agent: String? = "claude", state: String = "idle",
                    session: String? = "session-1", launchPending: Bool? = nil, label: String? = nil) -> [String: JSONValue] {
        var row: [String: JSONValue] = ["pane_id": .string(pane), "terminal_id": .string(terminal), "agent_status": .string(state), "revision": .number(3)]
        if let agent { row["agent"] = .string(agent) }
        if let session {
            row["agent_session"] = .object(["source": .string("herdr:\(agent ?? "none")"), "agent": .string(agent ?? "none"),
                                            "kind": .string("id"), "value": .string(session)])
        }
        if let launchPending { row["launch_pending"] = .bool(launchPending) }
        if let label { row["label"] = .string(label) }
        return row
    }

    static func pane(_ row: [String: JSONValue], on machine: HerdrMachine? = nil) -> AgentSummary {
        AgentSummary(json: .object(row), on: machine)!
    }

    static func rename(_ name: String, _ row: [String: JSONValue], on machine: HerdrMachine? = nil, machineID: UUID = machineID) -> AgentSessionRename? {
        AgentSessionNaming.rename(after: TitleRenameCommit(item: .pane(pane(row, on: machine)), name: name, shownTitle: name), machineID: machineID)
    }

    static func main() async throws {
        let native = "a1111111-1111-1111-1111-111111111111"
        func reference(_ agent: String, _ kind: String, _ value: String) -> AgentSessionReference {
            AgentSessionReference(json: .object(["source": .string("custom:pi"), "agent": .string(agent), "kind": .string(kind), "value": .string(value)]))!
        }
        let piPath = reference("pi", "path", "/owned/not-created/2026-10-23T00-00-00.000Z_\(native).jsonl")
        check(piPath.conversationID(for: .pi) == native, "Pi conversation matches reported native filename metadata without opening a file")
        check(piPath.resumeID(for: .pi) == nil, "conversation identity does not qualify legacy Pi resume")
        check(reference("pi", "path", "/owned/not-a-session.jsonl").conversationID(for: .pi) == nil, "unverified Pi filename does not invent a native identity")
        check(reference("pi", "path", "relative_\(native).jsonl").conversationID(for: .pi) == nil, "relative reported path rejected")
        check(reference("codex", "path", "/owned/\(native).jsonl").conversationID(for: .codex) == nil, "Pi filename convention is not applied to another CLI")
        check(reference("claude-code", "id", native).conversationID(for: .claude) == native, "native ID used directly when present")
        setvbuf(stdout, nil, _IOLBF, 0)
        names()
        commandsAndRegistration()
        verdicts()
        editors()
        try await store()
        try await transport()
        print("PASS \(passed) session naming checks")
    }

    // MARK: The name and the command

    static func names() {
        check(AgentSessionNaming.command(for: "Release notes") == "/rename Release notes", "command is the agent's own /rename with the name")
        let table: [(String, String?)] = [
            ("Release notes", "Release notes"),
            ("  padded\t ", "padded"),
            ("two\nlines", "two lines"),
            ("carriage\r\nreturn", "carriage  return"),
            ("line\u{2028}separator", "line separator"),
            ("paragraph\u{2029}separator", "paragraph separator"),
            ("next\u{85}line", "next line"),
            ("escape\u{1b}[31m", "escape [31m"),
            ("delete\u{7f}", "delete"),
            ("\u{1b}", nil),
            ("", nil),
            ("   ", nil),
            ("\n\u{2028}\t", nil),
            ("👨‍👩‍👧 family", "👨‍👩‍👧 family"),
            ("\"quoted\" & 'single' $HOME `tick`", "\"quoted\" & 'single' $HOME `tick`"),
            ("/rename nested", "/rename nested"),
        ]
        for (input, expected) in table {
            check(AgentSessionNaming.sessionName(from: input) == expected, "name \(input.debugDescription) -> \(expected.debugDescription)")
        }
        let long = String(repeating: "가", count: 250)
        check(AgentSessionNaming.sessionName(from: long) == String(repeating: "가", count: 200), "cut at 200 characters")
        let flags = String(repeating: "🇰🇷", count: 201)
        check(AgentSessionNaming.sessionName(from: flags)?.count == 200, "cut at 200 characters, not scalars")
        let spaceAtCut = String(repeating: "a", count: 199) + " b"
        check(AgentSessionNaming.sessionName(from: spaceAtCut) == String(repeating: "a", count: 199), "no space left at the end after the cut")
        check(AgentSessionNaming.sessionName(from: "  " + String(repeating: "b", count: 200) + "x") == String(repeating: "b", count: 200), "cut after the leading space is gone")
    }

    // MARK: What a rename registers

    static func commandsAndRegistration() {
        let claude = rename("Release", row())
        check(claude?.kind == .claude && claude?.name == "Release" && claude?.command == "/rename Release" && claude?.paneID == "w1:p1" &&
              claude?.terminalID == "term-1" && claude?.session == "id:session-1" && claude?.herdrMachine == nil, "a Claude Code pane's rename is registered")
        check(rename("Release", row(agent: "claude-code"))?.kind == .claude, "herdr's claude-code is Claude Code")
        check(rename("Release", row(agent: "codex"))?.kind == .codex, "a Codex pane's rename is registered")
        check(rename("Release", row(agent: "pi"))?.kind == .pi, "a Pi pane's rename goes to its launch, not to its input")
        check(rename("Release", row(agent: nil, session: nil)) == nil, "a pane with no agent registers nothing")
        check(rename("Release", row(agent: "gemini")) == nil, "an agent other than these registers nothing")
        check(rename("", row()) == nil, "a name taken away leaves the session's name as it is")
        check(rename("\n\t", row()) == nil, "a name of nothing but line breaks registers nothing")
        check(rename("two\nlines", row())?.command == "/rename two lines", "a rename's name is cleaned before it is registered")
        let tab = TabSummary(tab: .object(["tab_id": .string("w1:t1"), "workspace_id": .string("w1"), "label": .string("Tab")]), layout: nil, panes: [:], on: nil)!
        check(AgentSessionNaming.rename(after: TitleRenameCommit(item: .tab(tab), name: "Renamed", shownTitle: "Renamed"), machineID: machineID) == nil, "Rename Tab registers nothing")
        let onRemote = rename("Release", row(), on: remote)
        check(onRemote?.herdrMachine == remote && onRemote?.key == AgentSessionRename.Key(machineID: machineID, herdrMachineID: remote.id, paneID: "w1:p1"), "a herdr machine's pane keeps its machine")
    }

    // MARK: When to send, wait or let go

    static func verdicts() {
        let target = rename("Release", row())!
        let table: [(String, AgentSummary?, AgentSessionRename.Verdict)] = [
            ("idle", pane(row(state: "idle")), .apply),
            ("done", pane(row(state: "done")), .apply),
            ("working", pane(row(state: "working")), .wait),
            ("blocked", pane(row(state: "blocked")), .wait),
            ("unknown", pane(row(state: "unknown")), .wait),
            ("launch pending", pane(row(launchPending: true)), .wait),
            ("launch not pending", pane(row(launchPending: false)), .apply),
            ("session not named now", pane(row(session: nil)), .wait),
            ("pane closed", nil, .discard),
            ("another pane", pane(row(pane: "w1:p2")), .discard),
            ("terminal replaced", pane(row(terminal: "term-2")), .discard),
            ("agent kind changed", pane(row(agent: "codex")), .discard),
            ("agent gone", pane(row(agent: nil, state: "unknown", session: nil)), .discard),
            ("session changed", pane(row(session: "session-2")), .discard),
            ("session changed while working", pane(row(state: "working", session: "session-2")), .discard),
            ("same pane on a herdr machine", pane(row(), on: remote), .discard),
        ]
        for (name, current, expected) in table {
            check(AgentSessionNaming.verdict(target, current: current) == expected, "verdict \(name): \(expected)")
        }
        let unnamed = rename("Release", row(session: nil))!
        check(AgentSessionNaming.verdict(unnamed, current: pane(row(session: "session-9"))) == .apply, "a session herdr didn't name is not taken for another")
        check(AgentSessionNaming.verdict(unnamed, current: pane(row(session: nil))) == .apply, "neither side named")
    }

    // MARK: The editor

    static func editors() {
        let suggestion = "\u{1b}[0m╭───╮\n\u{1b}[0m❯ \u{1b}[0m\u{1b}[7mT\u{1b}[0m\u{1b}[2mry \"fix the failing test\"\u{1b}[0m\n\u{1b}[0m╰───╯"
        let unfocused = "\u{1b}[0m❯ \u{1b}[2mTry \"fix the failing test\"\u{1b}[22m\n  ? for shortcuts"
        let combined = "\u{1b}[0m❯ \u{1b}[0;7mT\u{1b}[0;2;38;5;246mry this\u{1b}[0m"
        let table: [(String, AgentKind, String, Bool)] = [
            ("Claude empty", .claude, emptyClaude, true),
            ("Claude plain empty", .claude, "❯\n", true),
            ("Claude suggestion, cursor inverted", .claude, suggestion, true),
            ("Claude suggestion without focus", .claude, unfocused, true),
            ("Claude suggestion, combined SGR", .claude, combined, true),
            ("Claude draft", .claude, "\u{1b}[0m❯ draft\u{1b}[7m \u{1b}[0m", false),
            ("Claude one typed character", .claude, "\u{1b}[0m❯ x\u{1b}[7m \u{1b}[0m", false),
            ("Claude draft, cursor on its first character", .claude, "\u{1b}[0m❯ \u{1b}[7mh\u{1b}[0mello", false),
            ("Claude command with its dim argument hint", .claude, "\u{1b}[0m❯ /rename\u{1b}[7m \u{1b}[0m\u{1b}[2m <name>\u{1b}[0m", false),
            ("Claude dim earlier prompt above a draft", .claude, "\u{1b}[2m❯ earlier\u{1b}[0m\n\u{1b}[0m❯ draft", false),
            ("Claude suggestion above, draft below", .claude, suggestion + "\n\u{1b}[0m❯ draft", false),
            ("Claude suggestion in a review modal", .claude, suggestion + "\nEsc to go back", false),
            ("Claude two empty prompts", .claude, "❯\n❯", false),
            ("Claude asking", .claude, "Do you want to proceed?\n❯ 1. Yes", false),
            ("Codex empty composer", .codex, emptyCodex, true),
            ("Codex draft", .codex, "\u{1b}[0m\u{1b}[1m›\u{1b}[0m draft", false),
            ("Codex with Claude's suggestion", .codex, suggestion, false),
            ("Pi never", .pi, emptyClaude, false),
        ]
        for (name, kind, ansi, expected) in table {
            check(AgentSessionNaming.isEmptyEditor(kind: kind, ansi: ansi) == expected, "editor \(name): \(expected)")
        }
        check(!AgentIdleStopPolicy.isEmptyEditor(kind: .claude, ansi: suggestion), "the idle stop before a resume still takes a suggestion for text")
    }

    // MARK: The names waiting, one for each pane

    static func store() async throws {
        let namer = AgentSessionNamer(retryInterval: .zero)
        let never: AgentSessionNamer.Connect = { preconditionFailure("no attempt expected") }
        let first = rename("First", row())!, second = rename("Second", row())!
        namer.add(first); namer.add(second)
        check(namer.pending.count == 1 && namer.pending[first.key]?.name == "Second", "a newer rename replaces the one waiting")
        let otherMachine = rename("Elsewhere", row(), machineID: UUID())!
        let onRemote = rename("Remote", row(), on: remote)!
        namer.add(otherMachine); namer.add(onRemote)
        check(namer.pending.count == 3, "the same pane ID on another Machine or herdr machine is another pane")
        namer.observe([pane(row(state: "working"))], machineID: machineID, herdrMachineID: nil, connect: never)
        check(namer.pending.count == 3, "a working agent waits")
        namer.observe([pane(row(session: "session-2"))], machineID: machineID, herdrMachineID: nil, connect: never)
        check(namer.pending[first.key] == nil && namer.pending[otherMachine.key] != nil && namer.pending[onRemote.key] != nil,
              "a changed session lets go of its own pane's name only")
        namer.add(rename("Again", row())!)
        namer.observe([], machineID: machineID, herdrMachineID: nil, connect: never)
        check(namer.pending[first.key] == nil && namer.pending.count == 2, "a closed pane lets go of its name")
        namer.observe([pane(row(state: "blocked"), on: remote)], machineID: machineID, herdrMachineID: remote.id, connect: never)
        check(namer.pending[onRemote.key] != nil, "a blocked agent on a herdr machine waits")
        namer.keep(herdrMachineIDs: [], machineID: machineID)
        check(namer.pending[onRemote.key] == nil && namer.pending[otherMachine.key] != nil, "a herdr machine removed lets go of its names")
        namer.add(rename("Terminal", row())!)
        namer.observe([pane(row(terminal: "term-2"))], machineID: machineID, herdrMachineID: nil, connect: never)
        check(namer.pending[first.key] == nil, "a replaced terminal lets go of its name")
        await namer.settle()
    }

    // MARK: Sending, through a fake herdr

    static func transport() async throws {
        // The editor empty: agent.prompt exactly once, to the pane, with the command.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row()); await herdr.setScreen(emptyClaude)
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            namer.add(rename("Release notes", row())!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            let prompts = await herdr.prompts
            check(prompts.count == 1 && prompts[0].paneID == "w1:p1" && prompts[0].text == "/rename Release notes" && namer.pending.isEmpty,
                  "an empty editor gets agent.prompt exactly once")
            let connects = await herdr.connects, disconnects = await herdr.disconnects
            check(connects == 1 && disconnects == 1, "one connection of its own, closed after")
        }
        // A draft: nothing, until the editor is empty.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row(agent: "codex")); await herdr.setScreen("\u{1b}[0m\u{1b}[1m›\u{1b}[0m half a thought")
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            let codexRow = row(agent: "codex")
            namer.add(rename("Codex name", codexRow)!)
            namer.observe([pane(codexRow)], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.isEmpty && namer.pending.count == 1, "a draft gets nothing, and the name waits")
            await herdr.setScreen(emptyCodex)
            namer.observe([pane(codexRow)], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            let prompts = await herdr.prompts
            check(prompts.count == 1 && prompts[0].text == "/rename Codex name" && namer.pending.isEmpty, "once the editor is empty, agent.prompt once")
        }
        // Retried no sooner than the interval, whatever snapshots come.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .seconds(3600))
            await herdr.setAgent(row()); await herdr.setScreen("❯ draft")
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            namer.add(rename("Paced", row())!)
            for _ in 0..<3 {
                namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
                await namer.settle()
            }
            check(await herdr.connects == 1, "attempts are paced")
            namer.add(rename("Paced again", row())!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.connects == 2, "a new rename is tried at once")
        }
        // Blocked: herdr's own state, and its refusal of the prompt.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row(state: "blocked")); await herdr.setScreen(emptyClaude)
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            namer.add(rename("Blocked", row())!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.isEmpty && namer.pending.count == 1, "agent.get blocked just before: nothing, the name waits")
            await herdr.setAgent(row()); await herdr.setPromptError("agent_blocked")
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.isEmpty && namer.pending.count == 1, "agent_blocked: the name waits")
            await herdr.setPromptError(nil)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.map(\.text) == ["/rename Blocked"] && namer.pending.isEmpty, "tried again at the next snapshot")
        }
        // A connection that fails is tried again.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row()); await herdr.setScreen(emptyClaude); await herdr.setConnectFailure(true)
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            namer.add(rename("Reconnect", row())!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.isEmpty && namer.pending.count == 1, "a failed connection: the name waits")
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil) { throw HostScriptError(status: 1, message: "settings changed") }
            await namer.settle()
            check(namer.pending.count == 1, "no connection to be had: the name waits")
            await herdr.setConnectFailure(false)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.count == 1 && namer.pending.isEmpty, "sent once connected")
        }
        // agent_not_found, or another session by the time it would go: let go of.
        let gone: [(String, (NamingHerdr) async -> Void)] = [
            ("agent.get agent_not_found", { await $0.setAgentError("agent_not_found") }),
            ("agent.prompt agent_not_found", { await $0.setPromptError("agent_not_found") }),
            ("another session just before", { await $0.setAgent(row(session: "session-2")) }),
            ("another terminal just before", { await $0.setAgent(row(terminal: "term-2")) }),
        ]
        for (name, setUp) in gone {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row()); await herdr.setScreen(emptyClaude)
            await setUp(herdr)
            namer.add(rename("Gone", row())!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil) { HerdrClient(transport: herdr) }
            await namer.settle()
            check(await herdr.prompts.isEmpty && namer.pending.isEmpty, "\(name): let go of, nothing sent")
        }
        // Two renames before it could go: the last name only, once.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row(state: "working")); await herdr.setScreen(emptyClaude)
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            namer.add(rename("Old", row())!)
            namer.observe([pane(row(state: "working"))], machineID: machineID, herdrMachineID: nil, connect: connect)
            namer.add(rename("New", row())!)
            await herdr.setAgent(row())
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.map(\.text) == ["/rename New"], "two renames: the last name only")
        }
        // Renamed again while an attempt is under way: that attempt sends nothing, and the newer
        // name goes once it ends, by the pane last seen, without waiting for another snapshot.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .seconds(3600))
            await herdr.setAgent(row()); await herdr.setScreen(emptyClaude); await herdr.setReadDelay(.milliseconds(200))
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            namer.add(rename("Under way", row())!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            try await Task.sleep(for: .milliseconds(50))
            namer.add(rename("Meanwhile", row())!)
            await namer.settle()
            let connects = await herdr.connects
            check(await herdr.prompts.map(\.text) == ["/rename Meanwhile"] && namer.pending.isEmpty && connects == 2,
                  "the attempt under way sends nothing for a replaced name; the newer one goes once it ends")
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.count == 1, "the newer name goes once")
        }
        // Renamed again under way, the agent busy by then: the newer name waits for a snapshot.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row()); await herdr.setScreen(emptyClaude); await herdr.setReadDelay(.milliseconds(200))
            let connect: AgentSessionNamer.Connect = { HerdrClient(transport: herdr) }
            namer.add(rename("Under way", row())!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            try await Task.sleep(for: .milliseconds(50))
            namer.observe([pane(row(state: "working"))], machineID: machineID, herdrMachineID: nil, connect: connect)
            namer.add(rename("Later", row())!)
            await namer.settle()
            check(await herdr.prompts.isEmpty && namer.pending.first?.value.name == "Later", "the newer name waits while the agent works")
            await herdr.setReadDelay(.zero)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil, connect: connect)
            await namer.settle()
            check(await herdr.prompts.map(\.text) == ["/rename Later"] && namer.pending.isEmpty, "then goes once")
        }
        // A herdr machine: the host's herdr CLI, with the name one argument whatever quotes it has.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            let name = "Say \"hi\" & 'bye' $HOME"
            await herdr.setAgent(row()); await herdr.setScreen(emptyClaude)
            namer.add(rename(name, row(), on: remote)!)
            namer.observe([pane(row())], machineID: machineID, herdrMachineID: nil) { preconditionFailure("not the host's panes") }
            namer.observe([pane(row(), on: remote)], machineID: machineID, herdrMachineID: remote.id) { HerdrClient(transport: herdr) }
            await namer.settle()
            let commands = await herdr.commands
            check(commands == [["--machine", "owned-remote", "pane", "read", "w1:p1", "--source", "visible", "--format", "ansi"],
                               ["--machine", "owned-remote", "agent", "get", "w1:p1"],
                               ["--machine", "owned-remote", "agent", "prompt", "w1:p1", "/rename " + name]], "herdr machine: pane read, agent get, agent prompt by CLI")
            check(shellQuoted("/rename " + name) == "'/rename Say \"hi\" & '\\''bye'\\'' $HOME'", "over SSH the command stays one word")
            check(await herdr.prompts.map(\.text) == ["/rename " + name] && namer.pending.isEmpty, "herdr machine: sent once")
        }
        // A herdr machine's draft and a CLI error envelope.
        do {
            let herdr = NamingHerdr(), namer = AgentSessionNamer(retryInterval: .zero)
            await herdr.setAgent(row(agent: "codex")); await herdr.setScreen("› draft"); await herdr.setAgentError("agent_not_found")
            namer.add(rename("Remote", row(agent: "codex"), on: remote)!)
            namer.observe([pane(row(agent: "codex"), on: remote)], machineID: machineID, herdrMachineID: remote.id) { HerdrClient(transport: herdr) }
            await namer.settle()
            check(await herdr.commands.count == 1 && namer.pending.count == 1, "herdr machine draft: read, nothing more")
            await herdr.setScreen(emptyCodex)
            namer.observe([pane(row(agent: "codex"), on: remote)], machineID: machineID, herdrMachineID: remote.id) { HerdrClient(transport: herdr) }
            await namer.settle()
            check(await herdr.prompts.isEmpty && namer.pending.isEmpty, "herdr machine agent_not_found envelope: let go of")
        }
    }
}
