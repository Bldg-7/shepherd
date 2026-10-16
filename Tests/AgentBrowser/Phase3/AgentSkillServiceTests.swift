import Foundation
import Observation

nonisolated private func expect(_ value: Bool) { precondition(value) }

private actor SkillTransport: HerdrTransport {
    private(set) var installs = 0
    private(set) var scripts = 0
    private(set) var statusScripts = 0
    private(set) var disconnects = 0
    private(set) var agentLists = 0
    /// Pane IDs, in order, of every pane.process_info request.
    private(set) var processReads: [String] = []
    private var agentRows: [JSONValue] = []
    private var processes: [String: JSONValue] = [:]
    private var hold = true
    private var scopeFailure = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    /// Each registerPane: the pane, the servers to block and the toggle.
    private(set) var registrations: [String] = []
    private var registrationHold: String?
    private var heldRegistration: CheckedContinuation<Void, Never>?
    private var registrationHeld: CheckedContinuation<Void, Never>?
    func holdRegistration(of pane: String) { registrationHold = pane }
    func waitForHeldRegistration() async { if heldRegistration == nil { await withCheckedContinuation { registrationHeld = $0 } } }
    func releaseRegistration() { registrationHold = nil; heldRegistration?.resume(); heldRegistration = nil }
    func connect() {}
    func disconnect() { disconnects += 1 }
    func configure(agents: [JSONValue], processes: [String: JSONValue]) { agentRows = agents; self.processes = processes }
    /// Only the browser check's requests; nothing that changes herdr.
    func send(method: String, params: JSONValue) throws -> JSONValue {
        switch method {
        case "agent.list":
            agentLists += 1
            return .object(["type": .string("agent_list"), "agents": .array(agentRows)])
        case "pane.process_info":
            let pane = params["pane_id"]?.stringValue ?? ""
            processReads.append(pane)
            guard let info = processes[pane] else { throw HostScriptError(status: 1, message: "unknown synthetic pane") }
            return .object(["type": .string("pane_process_info"), "process_info": info])
        default: throw HostScriptError(status: 1, message: "native seam unavailable")
        }
    }
    func runHerdr(_ arguments: [String]) throws -> Data { throw HostScriptError(status: 1, message: "no real CLI") }
    func configure(hold: Bool, scopeFailure: Bool = false) { self.hold = hold; self.scopeFailure = scopeFailure }
    func waitForInstall() async { if pending == nil { await withCheckedContinuation { started = $0 } } }
    func finish() { pending?.resume(); pending = nil }
    func runScript(_ script: String) async throws -> Data {
        scripts += 1
        precondition(script.contains(" | PATH='/synthetic/bin:/usr/bin:/bin' '/synthetic/node' "), "host-context PATH must reach the Node child")
        precondition(!script.contains("\"action\":\"setupCodex\"") && !script.contains("\"action\":\"setMode\""))
        let installation: [String: Any] = ["version":"synthetic", "resourceDirectory":"/synthetic/resources", "mode":"plugin", "codexPluginReady":false]
        let value: [String: Any]
        if script.contains("\"action\":\"install\"") {
            installs += 1
            if hold { await withCheckedContinuation { pending = $0; started?.resume(); started = nil } }
            value = installation
        } else if script.contains("\"action\":\"registerPane\"") {
            func field(_ name: String, _ end: Character) -> String {
                guard let start = script.range(of: "\"\(name)\":") else { return "?" }
                let rest = script[start.upperBound...]
                return rest.firstIndex(of: end).map { String(rest[...$0]) } ?? String(rest)
            }
            let pane = field("paneID", ",")
            if registrationHold.map({ pane.contains("\"\($0)\"") }) == true {
                await withCheckedContinuation { heldRegistration = $0; registrationHeld?.resume(); registrationHeld = nil }
            }
            registrations.append(pane + " " + field("competingBrowserServers", "]") + " " + field("disableCompetingBrowsers", ","))
            value = ["registered": true]
        } else if script.contains("\"action\":\"stagePi\"") {
            return Data("{\"ok\":false,\"error\":\"pi-package-unsupported\"}".utf8)
        } else if script.contains("\"action\":\"status\"") { statusScripts += 1; value = ["installation": installation] }
        else if script.contains("\"action\":\"checkScope\"") {
            if scopeFailure { return Data("{\"ok\":false,\"error\":\"legacy-global-skill-present\"}".utf8) }
            value = ["sessionOnly": true]
        } else if script.contains("\"action\":\"detect\"") {
            let kind = script.contains("\"kind\":\"pi\"") ? "pi" : (script.contains("\"kind\":\"codex\"") ? "codex" : "claude")
            value = ["nodeVersion":"26.1.0", "nodeSupported":true, "kind":kind, "executable":kind,
                     "version":"synthetic", "readiness":"availableAuthenticationUnknown", "sessionPlugin":kind == "claude",
                     "sessionConfiguration":kind == "codex", "hookRewrite":kind == "claude"]
        } else { throw HostScriptError(status: 1, message: "unexpected script action") }
        return try JSONSerialization.data(withJSONObject: ["ok":true,"result":value])
    }
}
/// Set by an observation's change handler, which may run off the main actor.
nonisolated private final class Fired: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { value = false; lock.unlock() }; return value }
}
@main @MainActor struct AgentSkillServiceTests {
    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        preconditionFailure("service did not settle")
    }
    /// The two-second browser check: no Node for the installation, processes
    /// read again only for shell panes and changed agent panes, and one
    /// notification for a check that changed nothing.
    private static func browserCheck(fake: SkillTransport, machine: Machine, defaults: UserDefaults) async throws {
        func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        await fake.configure(hold: false)
        let checker = AgentLaunchService(context: { .init(root: "/synthetic/runtime", resources: "/synthetic/resources", node: "/synthetic/node", claudeSettings: "/synthetic/claude/settings.json", claudeSkills: "/synthetic/claude/skills", codexHome: "/synthetic/codex", executionSearchPath: "/synthetic/bin:/usr/bin:/bin") }, defaults: defaults,
                                         makeLocalClient: { _ in HerdrClient(transport: fake) })
        ShepherdBrowserFeature.shared.isEnabled = true
        checker.update(machines: [machine]); checker.start()
        await wait { checker.skillPreparation.state == .ready }
        let panes = [AgentSummary(json: try json(#"{"pane_id":"w1:p1","terminal_id":"term_agent","agent":"claude","agent_status":"idle","revision":3}"#))!,
                     AgentSummary(json: try json(#"{"pane_id":"w1:p2","terminal_id":"term_shell","revision":1}"#))!]
        let row = #"{"pane_id":"w1:p1","terminal_id":"term_agent","agent":"claude","agent_status":"idle","interactive_ready":true,"state_change_seq":7,"revision":3}"#
        await fake.configure(agents: [try json(row)], processes: [
            "w1:p1": try json(#"{"pane_id":"w1:p1","shell_pid":10,"foreground_processes":[{"pid":11,"name":"claude","argv":["claude"]}]}"#),
            "w1:p2": try json(#"{"pane_id":"w1:p2","shell_pid":20,"foreground_processes":[{"pid":20,"name":"zsh"}]}"#)])
        let fired = Fired()
        func arm() {
            withObservationTracking {
                for pane in panes { _ = checker.status(for: pane, on: machine); _ = checker.failure(for: pane, on: machine); _ = checker.canResume(pane, on: machine) }
                _ = checker.reconciliationError; _ = checker.installation
            } onChange: { fired.set() }
        }
        /// One accepted snapshot and the check it starts; the pane IDs read.
        func round() async -> (reads: [String], notifications: Int) {
            let before = await fake.disconnects, read = await fake.processReads.count
            var notifications = 0
            _ = fired.take(); arm()
            MachineBrowserService.shared.accept(panes, on: machine)
            var finished = false
            for _ in 0..<10000 {
                if fired.take() { notifications += 1; arm() }
                if await fake.disconnects > before { finished = true; break }
                await Task.yield()
            }
            precondition(finished, "browser check did not finish")
            // The round's end (its error) comes after the disconnect.
            for _ in 0..<200 { if fired.take() { notifications += 1; arm() }; await Task.yield() }
            return (Array(await fake.processReads.dropFirst(read)), notifications)
        }
        let lists = await fake.agentLists
        let first = await round()
        expect(first.reads == ["w1:p1", "w1:p2"])
        let second = await round()
        expect(second.reads == ["w1:p2"])
        precondition(checker.status(for: panes[1], on: machine) == .shell, "shell pane still read every check")
        let unchanged = await round()
        expect(unchanged.reads == ["w1:p2"])
        precondition(unchanged.notifications == 1, "a check that changed nothing notifies once, not \(unchanged.notifications) times")
        await fake.configure(agents: [try json(row.replacingOccurrences(of: "\"state_change_seq\":7", with: "\"state_change_seq\":8"))], processes: [
            "w1:p1": try json(#"{"pane_id":"w1:p1","shell_pid":10,"foreground_processes":[{"pid":11,"name":"claude","argv":["claude"]}]}"#),
            "w1:p2": try json(#"{"pane_id":"w1:p2","shell_pid":20,"foreground_processes":[{"pid":20,"name":"zsh"}]}"#)])
        let changed = await round()
        expect(changed.reads == ["w1:p1", "w1:p2"])
        expect(await fake.agentLists == lists + 4)
        expect(await fake.statusScripts == 0)
        precondition(checker.reconciliationError == nil && checker.installation == nil)
        ShepherdBrowserFeature.shared.isEnabled = false
        await checker.stop()
    }

    /// Settings saved as they are typed register each pane again once, with
    /// the value they settle on; a save during a registration is not lost.
    private static func registrationFollowsSettings(fake: SkillTransport, machine: Machine, defaults: UserDefaults) async throws {
        func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("registration-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        try Data(#"{"version":"synthetic","resourceDirectory":"/synthetic/resources","mode":"plugin","globalRegistrationVersion":null,"codexPluginKey":null,"codexPluginReady":false}"#.utf8)
            .write(to: root.appendingPathComponent("installation.json"))
        await fake.configure(hold: false)
        let service = AgentLaunchService(context: { .init(root: root.path, resources: "/synthetic/resources", node: "/synthetic/node", claudeSettings: "/synthetic/claude/settings.json", claudeSkills: "/synthetic/claude/skills", codexHome: "/synthetic/codex", executionSearchPath: "/synthetic/bin:/usr/bin:/bin") }, defaults: defaults,
                                         makeLocalClient: { _ in HerdrClient(transport: fake) })
        ShepherdBrowserFeature.shared.isEnabled = true
        service.update(machines: [machine]); service.start()
        await wait { service.skillPreparation.state == .ready }
        let panes = [AgentSummary(json: try json(#"{"pane_id":"w1:p1","terminal_id":"term_one","revision":1}"#))!,
                     AgentSummary(json: try json(#"{"pane_id":"w1:p2","terminal_id":"term_two","revision":1}"#))!]
        await fake.configure(agents: [], processes: [
            "w1:p1": try json(#"{"pane_id":"w1:p1","shell_pid":10,"foreground_processes":[{"pid":10,"name":"zsh"}]}"#),
            "w1:p2": try json(#"{"pane_id":"w1:p2","shell_pid":20,"foreground_processes":[{"pid":20,"name":"zsh"}]}"#)])
        CDPProxy.shared.port = 9334; CDPProxy.shared.tokenFile = URL(fileURLWithPath: "/synthetic/agent-token-9334")
        for pane in panes { MachineBrowserService.shared.resolvable[BrowserKey(machine: machine, pane: pane)] = pane.terminalID }
        /// One check; the registrations it made.
        func round() async -> [String] {
            let before = await fake.disconnects, count = await fake.registrations.count
            MachineBrowserService.shared.accept(panes, on: machine)
            var finished = false
            for _ in 0..<10000 { if await fake.disconnects > before { finished = true; break }; await Task.yield() }
            precondition(finished, "browser check did not finish")
            return Array(await fake.registrations.dropFirst(count))
        }
        /// What the Browser MCP servers field's binding does, which SwiftUI
        /// calls about three times for each key typed.
        func type(_ text: String) throws {
            for _ in 0..<3 {
                service.preferences.competingBrowserServers = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                try service.savePreferences()
            }
        }
        let first = await round()
        precondition(first.count == 2 && first.allSatisfy { $0.hasSuffix(" [] false,") }, "every pane is registered once: \(first)")
        let unchanged = await round(); precondition(unchanged.isEmpty, "an unchanged check registers nothing: \(unchanged)")
        service.preferences.disableCompetingBrowsers = true
        let text = "playwright, chrome-devtools"
        for length in 1...text.count {
            try type(String(text.prefix(length)))
            if length % 5 == 0 { let typing = await round(); precondition(typing.isEmpty, "no registration while typing: \(typing)") }
        }
        try await Task.sleep(for: .milliseconds(1100))
        let settled = await round()
        precondition(settled.count == 2 && settled.allSatisfy { $0.hasSuffix(#" ["playwright","chrome-devtools"] true,"#) },
                     "each pane registered once with the settled value: \(settled)")
        try type(text + ", ")
        try await Task.sleep(for: .milliseconds(1100))
        let same = await round(); precondition(same.isEmpty, "saving the same list registers nothing: \(same)")
        // A save while a pane's registration runs: that pane is registered again.
        // Held from before the first save, so a check that save starts at once
        // is held too, and the steps below fail instead of waiting forever.
        await fake.holdRegistration(of: "w1:p1")
        service.preferences.disableCompetingBrowsers = false; try service.savePreferences()
        try await Task.sleep(for: .milliseconds(1100))
        let held = Task { await round() }
        await fake.waitForHeldRegistration()
        service.preferences.disableCompetingBrowsers = true; try service.savePreferences()
        await fake.releaseRegistration()
        _ = await held.value
        try await Task.sleep(for: .milliseconds(1100))
        let again = await round()
        precondition(again.count == 1 && again[0].contains("\"w1:p1\"") && again[0].hasSuffix(" true,"),
                     "the pane registered during the save is registered again with the saved value: \(again)")
        let after = await round(); precondition(after.isEmpty, "and then left alone: \(after)")
        CDPProxy.shared.port = nil; CDPProxy.shared.tokenFile = nil; MachineBrowserService.shared.resolvable = [:]
        ShepherdBrowserFeature.shared.isEnabled = false
        await service.stop()
    }

    static func main() async throws {
        let suite = "shepherd-skills-synthetic-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = SkillTransport()
        let service = AgentLaunchService(context: { .init(root: "/synthetic/runtime", resources: "/synthetic/resources", node: "/synthetic/node", claudeSettings: "/synthetic/claude/settings.json", claudeSkills: "/synthetic/claude/skills", codexHome: "/synthetic/codex", executionSearchPath: "/synthetic/bin:/usr/bin:/bin") }, defaults: defaults,
                                         makeLocalClient: { _ in HerdrClient(transport: fake) })
        let machine = Machine(displayName: "Owned", hostname: "localhost", username: "fixture", isLocal: true)
        ShepherdBrowserFeature.shared.isEnabled = false
        service.update(machines: [machine]); service.start()
        expect(await fake.scripts == 0)
        precondition(service.skillPreparation.state == .off)
        ShepherdBrowserFeature.shared.isEnabled = true
        BrowserEngine.isAvailable = false
        service.start()
        await wait { if case .failed = service.skillPreparation.state { return true }; return false }
        expect(await fake.scripts == 0)
        BrowserEngine.isAvailable = true
        service.prepareSkillsAutomatically(retry: true)
        await fake.waitForInstall()
        service.start(); service.update(machines: [machine]); service.prepareSkillsAutomatically(retry: true)
        expect(await fake.installs == 1)
        precondition(service.browserDisableBlocked)
        await fake.finish()
        await wait { service.skillPreparation.state == .ready }
        precondition(service.diagnostics[.claude]?.sessionPlugin == true)
        precondition(service.diagnostics[.codex]?.sessionPlugin == false)
        precondition(service.diagnostics[.pi]?.kind == .pi && service.diagnostics[.pi]?.readiness == .availableAuthenticationUnknown)
        await fake.configure(hold: false)
        let beforePiLaunch = await fake.scripts
        do {
            _ = try await service.launch(kind: .pi, on: machine, client: HerdrClient(transport: fake),
                create: { _ in preconditionFailure("unsupported Pi package must not create a pane") },
                select: { _ in preconditionFailure("unsupported Pi package must not select a pane") })
            preconditionFailure("unsupported Pi package launched")
        } catch AgentRuntimeError.rejected(let code) { precondition(code == "pi-package-unsupported") }
        expect(await fake.scripts == beforePiLaunch + 2)
        expect(await fake.installs == 2)
        await fake.configure(hold: true)
        ShepherdBrowserFeature.shared.isEnabled = false
        await service.stop()
        precondition(service.skillPreparation.state == .off)

        // Shutdown during a held install drains it and never publishes late Ready.
        ShepherdBrowserFeature.shared.isEnabled = true
        service.start(); await fake.waitForInstall()
        ShepherdBrowserFeature.shared.isEnabled = false
        let stopping = Task { await service.stop() }
        await wait { service.skillPreparation.state == .stopping }
        await fake.finish(); await stopping.value
        precondition(service.skillPreparation.state == .off)

        // Legacy globals are reported, untouched; only explicit retry repeats work.
        await fake.configure(hold: false, scopeFailure: true)
        ShepherdBrowserFeature.shared.isEnabled = true
        service.start()
        await wait { if case .failed = service.skillPreparation.state { return true }; return false }
        let failedCount = await fake.installs
        service.update(machines: [machine]); service.start()
        expect(await fake.installs == failedCount)
        await fake.configure(hold: false)
        service.prepareSkillsAutomatically(retry: true)
        await wait { service.skillPreparation.state == .ready }
        expect(await fake.installs == failedCount + 1)
        ShepherdBrowserFeature.shared.isEnabled = false
        await service.stop()
        try await browserCheck(fake: fake, machine: machine, defaults: defaults)
        try await registrationFollowsSettings(fake: fake, machine: machine, defaults: defaults)
        print("PASS real AgentLaunchService with synthetic native/transport seams: OFF no setup, ON automatic setup, shared/coalesced preparation, safe drain, legacy-global failure, explicit retry, Codex delivery distinction, panes registered again once when settings settle; no real CLI/herdr/GUI")
    }
}
