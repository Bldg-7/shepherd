#if os(macOS)
import Foundation
import Observation

/// Preferences and a memory-only presentation lease; never stores credentials.
@MainActor @Observable
final class PasswordManagerPreferences {
    enum Onboarding: String { case unseen, pending, completed }
    static let managerKey = "shepherdPasswordManager"
    static let onboardingKey = "shepherdPasswordManagerOnboarding"

    let connections: PasswordManagerConnectionCoordinator
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var visitingOwners: Set<UUID> = []
    // One app-owned startup snapshot, not eligibility recreated by each window.
    @ObservationIgnored private var startupResumeEligible = false
    private(set) var selectedManager: PasswordManagerProviderID
    private(set) var onboarding: Onboarding
    private(set) var presentationOwner: UUID?

    init(defaults: UserDefaults, browserEnabledAtStartup: Bool = false) {
        self.defaults = defaults
        connections = PasswordManagerConnectionCoordinator(defaults: defaults)
        selectedManager = defaults.string(forKey: Self.managerKey).flatMap(PasswordManagerProviderID.init(rawValue:)) ?? .none
        onboarding = defaults.string(forKey: Self.onboardingKey).flatMap(Onboarding.init(rawValue:)) ?? .unseen
        startupResumeEligible = browserEnabledAtStartup && onboarding == .pending
    }

    /// Only persisted ON + pending at app startup may auto-present, once across
    /// all windows. Cancellation requires an explicit visit or another process.
    @discardableResult
    func resumeAtStartup(owner: UUID, browserEnabled: Bool) -> Bool {
        guard startupResumeEligible else { return false }
        startupResumeEligible = false
        return claimPresentation(owner: owner, browserEnabled: browserEnabled)
    }

    /// Called only after an accepted false → true transition completes.
    func didEnable(owner: UUID?) {
        if onboarding == .unseen {
            onboarding = .pending
            defaults.set(onboarding.rawValue, forKey: Self.onboardingKey)
        }
        if let owner, visitingOwners.contains(owner) {
            _ = claimPresentation(owner: owner, browserEnabled: true)
        }
    }

    func beginVisit(owner: UUID, browserEnabled: Bool) {
        visitingOwners.insert(owner)
        _ = claimPresentation(owner: owner, browserEnabled: browserEnabled)
    }

    func endVisit(owner: UUID) {
        visitingOwners.remove(owner)
        connections.close(owner: owner)
        releasePresentation(owner: owner)
    }

    @discardableResult
    func claimPresentation(owner: UUID, browserEnabled: Bool) -> Bool {
        guard browserEnabled, onboarding == .pending,
              presentationOwner == nil || presentationOwner == owner else { return false }
        presentationOwner = owner
        startupResumeEligible = false
        return true
    }

    /// Closing is not Skip. Reclaim only on a later explicit visit or restart.
    func releasePresentation(owner: UUID) {
        if presentationOwner == owner { presentationOwner = nil }
    }

    func didDisable() { presentationOwner = nil; connections.cancel() }

    func select(_ manager: PasswordManagerProviderID) {
        if selectedManager != manager { connections.cancel() }
        selectedManager = manager
        defaults.set(manager.rawValue, forKey: Self.managerKey)
    }

    func complete(owner: UUID, manager: PasswordManagerProviderID) {
        guard presentationOwner == owner, onboarding == .pending else { return }
        select(manager)
        onboarding = .completed
        defaults.set(onboarding.rawValue, forKey: Self.onboardingKey)
        presentationOwner = nil
    }
}
#endif
