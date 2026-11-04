import Foundation
import Observation

/// One app-owned opt-in, observed by every window. Only successful, safe
/// transitions are persisted; disabling never removes browser/runtime data.
@MainActor @Observable
final class ShepherdBrowserFeature {
    static let shared: ShepherdBrowserFeature = {
        #if DEBUG && os(macOS)
        if let configuration = OwnedOperatorFixture.configuration {
            return ShepherdBrowserFeature(defaults: configuration.defaults)
        }
        let environment = ProcessInfo.processInfo.environment
        let legacyFixture = ["SHEPHERD_AGENT_LAUNCH_FIXTURE", "SHEPHERD_NATIVE_B_PROBE", "SHEPHERD_BROWSER_PHASE2_FIXTURE", "SHEPHERD_BROWSER_SELFTEST"].contains { environment[$0] != nil }
        if legacyFixture || environment["SHEPHERD_BROWSER_FEATURE_FIXTURE"] != nil {
            precondition(environment["SHEPHERD_BROWSER_TEST_ROOT"] != nil, "Private fixture root required")
            let domain = "com.bldg-7.shepherd.browser-feature-fixture." + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            // Registration is private and nonpersistent; real user defaults are untouched.
            if legacyFixture { defaults.register(defaults: [preferenceKey: true]) }
            let feature = ShepherdBrowserFeature(defaults: defaults)
            feature.fixtureDefaultsDomain = domain
            return feature
        }
        #endif
        return ShepherdBrowserFeature()
    }()
    /// Browser/session injection is deferred for the hc release. A persisted
    /// opt-in is not permission to revive old endpoints, credential brokers or
    /// leases. Only explicitly isolated DEBUG legacy fixtures may opt in.
    static var isAvailable: Bool {
        #if DEBUG && os(macOS)
        let env = ProcessInfo.processInfo.environment
        return env["SHEPHERD_BROWSER_TEST_ROOT"] != nil &&
            ["SHEPHERD_BROWSER_FEATURE_FIXTURE", "SHEPHERD_AGENT_LAUNCH_FIXTURE", "SHEPHERD_NATIVE_B_PROBE", "SHEPHERD_BROWSER_PHASE2_FIXTURE", "SHEPHERD_BROWSER_SELFTEST"].contains { env[$0] != nil }
        #else
        return false
        #endif
    }
    static let preferenceKey = "experimentalShepherdBrowserEnabled"
    #if DEBUG && os(macOS)
    @ObservationIgnored private var fixtureDefaultsDomain: String?
    func removeFixtureDefaults() {
        if let fixtureDefaultsDomain { defaults.removePersistentDomain(forName: fixtureDefaultsDomain) }
    }
    #endif
    private let defaults: UserDefaults
    #if os(macOS)
    let passwordManagers: PasswordManagerPreferences
    #endif
    private(set) var isEnabled: Bool
    private(set) var isTransitioning = false
    private(set) var refusal: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if os(macOS)
        passwordManagers = PasswordManagerPreferences(
            defaults: defaults, browserEnabledAtStartup: Self.isAvailable && defaults.bool(forKey: Self.preferenceKey))
        #endif
        isEnabled = Self.isAvailable && defaults.bool(forKey: Self.preferenceKey)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, presentationOwner: UUID? = nil, canDisable: () -> Bool, transition: () async -> Void) async -> Bool {
        guard !enabled || Self.isAvailable else {
            refusal = "In-app Browser and agent injection are unavailable in this hc release. Existing browser data is preserved; terminal programs are not terminated."
            return false
        }
        guard !isTransitioning else { return false }
        guard enabled != isEnabled else { return true }
        guard enabled || canDisable() else {
            refusal = String(localized: "In-app Browser cannot be disabled while an agent, browser connection, or launch is active, or activity cannot be confirmed. Wait until all local sessions are inactive and try again.")
            return false
        }
        isTransitioning = true
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        refusal = nil
        #if os(macOS)
        // Accepted OFF revokes pending account authorization before async teardown.
        if !enabled {
            passwordManagers.didDisable()
            await passwordManagers.connections.awaitCredentialRevocation()
        }
        #endif
        await transition()
        #if os(macOS)
        if enabled { passwordManagers.didEnable(owner: presentationOwner) }
        #endif
        isTransitioning = false
        return true
    }

}
