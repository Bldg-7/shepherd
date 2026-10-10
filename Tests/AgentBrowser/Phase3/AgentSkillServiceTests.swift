import Foundation

nonisolated private func expect(_ value: Bool) { precondition(value) }

private actor SkillTransport: HerdrTransport {
    private(set) var installs = 0
    private(set) var scripts = 0
    private var hold = true
    private var scopeFailure = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func connect() {}
    func disconnect() {}
    func events() -> AsyncStream<JSONValue> { AsyncStream { $0.finish() } }
    func send(method: String, params: JSONValue) throws -> JSONValue { throw HostScriptError(status: 1, message: "native seam unavailable") }
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
        } else if script.contains("\"action\":\"stagePi\"") {
            return Data("{\"ok\":false,\"error\":\"pi-package-unsupported\"}".utf8)
        } else if script.contains("\"action\":\"status\"") { value = ["installation": installation] }
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
@main @MainActor struct AgentSkillServiceTests {
    static func wait(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        preconditionFailure("service did not settle")
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
        print("PASS real AgentLaunchService with synthetic native/transport seams: OFF no setup, ON automatic setup, shared/coalesced preparation, safe drain, legacy-global failure, explicit retry, Codex delivery distinction; no real CLI/herdr/GUI")
    }
}
