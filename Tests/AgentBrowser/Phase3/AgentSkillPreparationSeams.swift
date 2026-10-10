// Native/app seams ONLY for compiling/testing the real launch service without
// launching CEF, connecting herdr, accessing credentials, or opening UI.
import Foundation

@MainActor final class ShepherdBrowserFeature {
    static let shared = ShepherdBrowserFeature()
    var isEnabled = false
}
@MainActor enum BrowserEngine { static var isAvailable = true }
nonisolated struct BrowserEndpoint: Sendable {
    enum Origin: Hashable, Sendable { case local }
    let origin: Origin
    let host: String
    let port: Int
    let path: String
    let tokenFile: URL
    var url: URL { URL(string: "ws://\(host):\(port)\(path)")! }
}
@MainActor final class CDPProxy {
    static let shared = CDPProxy()
    var activeConnections = 0
    var port: Int? = nil
    func endpoint(for key: BrowserKey) -> BrowserEndpoint? { nil }
    func restart(port: Int) async { self.port = port }
}
@MainActor final class BrowserStore {
    static let shared = BrowserStore()
    struct Record { var agentConnected = false; var agentSocketConnected = false }
    func browser(for key: BrowserKey) -> Record? { nil }
}
@MainActor final class MachineBrowserService {
    static let shared = MachineBrowserService()
    struct ResolvedPane: Sendable { let key: BrowserKey; let terminalID: String }
    var errors: [UUID: String] = [:]
    var acceptedSnapshot: (@MainActor ([AgentSummary], Machine) -> Void)?
    func accept(_ panes: [AgentSummary], on machine: Machine) { acceptedSnapshot?(panes, machine) }
    func resolve(_ route: CDPRoute) -> ResolvedPane? { nil }
}
actor LocalHerdrTransport: HerdrTransport {
    nonisolated static let defaultSocketPath = "/synthetic/herdr.sock"
    init(socketPath: String) {}
    func connect() {}
    func disconnect() {}
    func send(method: String, params: JSONValue) throws -> JSONValue { throw HostScriptError(status: 1, message: "synthetic only") }
    func events() -> AsyncStream<JSONValue> { AsyncStream { $0.finish() } }
    func runHerdr(_ arguments: [String]) throws -> Data { throw HostScriptError(status: 1, message: "synthetic only") }
    func runScript(_ script: String) throws -> Data { throw HostScriptError(status: 1, message: "synthetic only") }
}
// Compile-only seam: production Pi composition is exercised by the separate
// owned Herdr/app fixture. This must never authorize a launch in this suite.
@MainActor final class PiLaunchCoordinator {
    let hasWork = false
    let isReady = false
    let failure: String? = "native-fixture-required"
    init(stage: PiStagedLaunch, owner: AgentPaneIdentity, machine: Machine, client: HerdrClient, cwd: String, preferences: AgentRuntimePreferences) throws {
        throw PiBridgeFailure.unavailable
    }
    func prepare() async throws { throw PiBridgeFailure.unavailable }
    func waitUntilReady() async throws { throw PiBridgeFailure.unavailable }
    func stop() async {}
}
@MainActor final class MachineStore {
    func makeHerdrTransport(for machine: Machine) throws -> any HerdrTransport { LocalHerdrTransport(socketPath: "/synthetic/herdr.sock") }
}
nonisolated func connectionFailureDescription(_ error: Error) -> String { error.localizedDescription }
