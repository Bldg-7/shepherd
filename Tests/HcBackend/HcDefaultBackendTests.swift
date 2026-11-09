import Foundation
import ShepherdKit

// These stand-ins exercise only the exact extracted fixture-routing predicate.
// They do not qualify the real fixture's path/marker/ownership validation.
@MainActor enum HcMigrationConfiguration { static var requested = false }
@MainActor enum OwnedOperatorFixture { static var configuration: Int? }
@MainActor enum ShepherdBrowserFeature { static var isAvailable = false }

private actor EntryFailureState {
    private var starts = 0
    private var closes = 0
    func started() { starts += 1 }
    func closed() { if closes == 0 { closes = 1 } }
    func snapshot() -> (Int, Int) { (starts, closes) }
}
private nonisolated enum EntryFailure: Error { case unavailable }
private nonisolated final class EntryFailureTransport: CoreByteTransport {
    let missing: Bool
    let state = EntryFailureState()
    init(missing: Bool) { self.missing = missing }
    func start() async throws {
        await state.started()
        if missing { throw HcConnectionPolicy.Failure.noExecutable }
        throw EntryFailure.unavailable
    }
    func read() async throws -> Data? { throw EntryFailure.unavailable }
    func write(_ bytes: Data) async throws { throw EntryFailure.unavailable }
    func close() async throws { await state.closed() }
}
@MainActor private final class EntrySecrets: MachineSecretStore {
    var accesses = 0
    func saveSecret(_ data: Data, tag: String) throws { accesses += 1 }
    func loadSecret(tag: String) throws -> Data? { accesses += 1; return nil }
    func deleteSecret(tag: String) throws { accesses += 1 }
}

@main @MainActor private struct HcDefaultBackendTests {
    static var checks = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw NSError(domain: name, code: 1) }; checks += 1
    }
    static func main() async throws {
        for hcFixture in [false, true] {
            for owned in [false, true] {
                for browser in [false, true] {
                    HcMigrationConfiguration.requested = hcFixture
                    OwnedOperatorFixture.configuration = owned ? 1 : nil
                    ShepherdBrowserFeature.isAvailable = browser
                    #if DEBUG && SHEPHERD_LEGACY_FIXTURES
                    let expected = !hcFixture && (owned || browser)
                    #else
                    let expected = false
                    #endif
                    try check(ShepherdLegacyFixtureRouting.enabled == expected, "exact fixture routing predicate")
                }
            }
        }
        HcMigrationConfiguration.requested = false
        OwnedOperatorFixture.configuration = nil
        ShepherdBrowserFeature.isAvailable = false
        try check(!ShepherdLegacyFixtureRouting.enabled, "ordinary entry never enables legacy")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let domain = "com.bldg-7.shepherd.default-entry-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let machine = Machine(displayName: "Owned entry", hostname: "localhost", username: "owned", isLocal: true)
        let secrets = EntrySecrets()
        let store = MachineStore(defaults: defaults, localMachine: machine, keychain: secrets)
        let owner = HcMachineConnection(directory: root.appending(path: "workspace"))
        for missing in [true, false] {
            let transport = EntryFailureTransport(missing: missing)
            await owner.open(machine: machine, store: store, localTransport: transport)
            // CoreRPC intentionally normalizes arbitrary transport-start
            // errors. Discovery's pre-transport missingExecutable branch is
            // separately source-guarded; do not pretend this fake is discovery.
            try check(owner.phase == .failed, "transport failure remains an hc failure")
            try check(owner.model == nil && owner.identity == nil && owner.message != nil, "failure has no live or substitute model")
            let state = await transport.state.snapshot()
            try check(state.0 == 1 && state.1 == 1, "one hc attempt, closed, no transport replay")
            try check(!ShepherdLegacyFixtureRouting.enabled, "hc failure cannot select legacy")
            try check(secrets.accesses == 0, "local failure does not read credentials")
        }
        await owner.close()
        try check(owner.phase == .idle && owner.model == nil, "failed owner can retire without starting anything")
        print("PASS \(checks) default hc fixture-routing/failure checks; no real core, network, CLI, Keychain or GUI")
    }
}
