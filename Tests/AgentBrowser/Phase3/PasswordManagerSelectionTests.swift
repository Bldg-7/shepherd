import Foundation

@main struct PasswordManagerSelectionTests {
    @MainActor static func main() async {
        let suite = "com.bldg-7.shepherd.password-selection-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic-only", forKey: "unrelated-fixture")
        let feature = ShepherdBrowserFeature(defaults: defaults)
        let preferences = feature.passwordManagers
        let a = UUID(), b = UUID()
        precondition(!feature.isEnabled && preferences.onboarding == .unseen)
        precondition(!preferences.claimPresentation(owner: a, browserEnabled: false))
        await feature.setEnabled(false, presentationOwner: a, canDisable: { true }, transition: { fatalError("no-op") })
        precondition(preferences.onboarding == .unseen)
        preferences.beginVisit(owner: a, browserEnabled: false)
        await feature.setEnabled(true, presentationOwner: a, canDisable: { true }, transition: {
            precondition(preferences.onboarding == .unseen, "only after transition completes")
            let rejected = await feature.setEnabled(true, presentationOwner: b, canDisable: { true }, transition: { fatalError("overlap") })
            precondition(!rejected && preferences.presentationOwner == nil)
        })
        precondition(preferences.onboarding == .pending && preferences.presentationOwner == a)
        precondition(!preferences.claimPresentation(owner: b, browserEnabled: true), "single lease")
        preferences.complete(owner: b, manager: .bitwarden)
        precondition(preferences.onboarding == .pending && preferences.selectedManager == .none)
        preferences.releasePresentation(owner: b)
        precondition(preferences.presentationOwner == a)
        preferences.releasePresentation(owner: a)
        precondition(preferences.onboarding == .pending && preferences.presentationOwner == nil, "cancel/closing retains pending")
        precondition(!preferences.resumeAtStartup(owner: b, browserEnabled: feature.isEnabled),
                     "cancel A then newly created B in the same process must not auto-popup")
        preferences.beginVisit(owner: b, browserEnabled: feature.isEnabled)
        precondition(preferences.presentationOwner == b, "explicit Settings visit resumes cancelled pending")
        preferences.endVisit(owner: b)
        precondition(!preferences.resumeAtStartup(owner: UUID(), browserEnabled: feature.isEnabled))
        await feature.setEnabled(true, presentationOwner: a, canDisable: { true }, transition: { fatalError("no-op") })
        precondition(preferences.presentationOwner == nil, "no automatic popup loop on repeated ON")
        let startupProcess = ShepherdBrowserFeature(defaults: defaults)
        precondition(startupProcess.passwordManagers.onboarding == .pending && startupProcess.passwordManagers.presentationOwner == nil)
        let startupA = Task { @MainActor in
            startupProcess.passwordManagers.resumeAtStartup(owner: a, browserEnabled: startupProcess.isEnabled)
        }
        let startupB = Task { @MainActor in
            startupProcess.passwordManagers.resumeAtStartup(owner: b, browserEnabled: startupProcess.isEnabled)
        }
        let aWon = await startupA.value
        let bWon = await startupB.value
        precondition(aWon != bWon, "two startup windows race for exactly one app-owned lease")
        let winner = aWon ? a : b
        precondition(startupProcess.passwordManagers.presentationOwner == winner)
        // The Settings detail page must reuse ContentView's startup owner.
        startupProcess.passwordManagers.beginVisit(owner: winner, browserEnabled: startupProcess.isEnabled)
        precondition(startupProcess.passwordManagers.presentationOwner == winner)
        startupProcess.passwordManagers.endVisit(owner: aWon ? b : a)
        precondition(startupProcess.passwordManagers.presentationOwner == winner, "unrelated window cannot release startup handoff")
        startupProcess.passwordManagers.releasePresentation(owner: winner)
        precondition(!startupProcess.passwordManagers.resumeAtStartup(owner: UUID(), browserEnabled: startupProcess.isEnabled),
                     "cancel startup A then create B: same process snapshot stays consumed")
        let nextProcess = ShepherdBrowserFeature(defaults: defaults)
        precondition(nextProcess.passwordManagers.resumeAtStartup(owner: b, browserEnabled: nextProcess.isEnabled),
                     "persisted pending resumes once in the next process")
        precondition(!nextProcess.passwordManagers.resumeAtStartup(owner: a, browserEnabled: nextProcess.isEnabled))
        nextProcess.passwordManagers.releasePresentation(owner: b)
        nextProcess.passwordManagers.beginVisit(owner: b, browserEnabled: nextProcess.isEnabled)
        precondition(nextProcess.passwordManagers.presentationOwner == b, "explicit visit still resumes after startup cancellation")
        nextProcess.passwordManagers.complete(owner: b, manager: .none)
        // Continue the existing completed-state checks on a fresh app-owned instance.
        let restart = ShepherdBrowserFeature(defaults: defaults)
        precondition(restart.isEnabled && restart.passwordManagers.onboarding == .completed, "Skip keeps ON")
        precondition(restart.passwordManagers.selectedManager == .none)
        restart.passwordManagers.select(.onePassword)
        restart.passwordManagers.select(.bitwarden)
        precondition(restart.passwordManagers.selectedManager == .bitwarden)
        let refused = await restart.setEnabled(false, canDisable: { false }, transition: { fatalError("rejected") })
        precondition(!refused && restart.isEnabled && restart.passwordManagers.onboarding == .completed)
        await restart.setEnabled(false, canDisable: { true }, transition: {})
        precondition(!restart.passwordManagers.claimPresentation(owner: a, browserEnabled: restart.isEnabled))
        precondition(restart.passwordManagers.selectedManager == .bitwarden)
        await restart.setEnabled(true, presentationOwner: a, canDisable: { true }, transition: {})
        precondition(restart.passwordManagers.presentationOwner == nil, "completed never repeats")
        let completedRestart = ShepherdBrowserFeature(defaults: defaults)
        precondition(completedRestart.passwordManagers.onboarding == .completed)
        precondition(!completedRestart.passwordManagers.claimPresentation(owner: a, browserEnabled: true))
        // Existing persisted ON + unseen must not force migration at startup.
        defaults.removeObject(forKey: PasswordManagerPreferences.onboardingKey)
        let existingOn = ShepherdBrowserFeature(defaults: defaults)
        precondition(existingOn.isEnabled && existingOn.passwordManagers.onboarding == .unseen)
        precondition(!existingOn.passwordManagers.resumeAtStartup(owner: a, browserEnabled: existingOn.isEnabled))
        precondition(!existingOn.passwordManagers.claimPresentation(owner: a, browserEnabled: true))
        await existingOn.setEnabled(false, canDisable: { true }, transition: {})
        await existingOn.setEnabled(true, presentationOwner: a, canDisable: { true }, transition: {})
        await existingOn.setEnabled(false, canDisable: { true }, transition: {})
        precondition(existingOn.passwordManagers.onboarding == .pending && existingOn.passwordManagers.presentationOwner == nil)
        let pendingOffRestart = ShepherdBrowserFeature(defaults: defaults)
        precondition(!pendingOffRestart.passwordManagers.resumeAtStartup(owner: b, browserEnabled: pendingOffRestart.isEnabled))
        precondition(!pendingOffRestart.passwordManagers.claimPresentation(owner: b, browserEnabled: pendingOffRestart.isEnabled))
        pendingOffRestart.passwordManagers.beginVisit(owner: b, browserEnabled: false)
        await pendingOffRestart.setEnabled(true, presentationOwner: b, canDisable: { true }, transition: {})
        precondition(pendingOffRestart.passwordManagers.presentationOwner == b)
        pendingOffRestart.passwordManagers.complete(owner: b, manager: .onePassword)
        precondition(pendingOffRestart.passwordManagers.selectedManager == .onePassword)
        precondition(defaults.string(forKey: "unrelated-fixture") == "synthetic-only")
        precondition(Set(defaults.persistentDomain(forName: suite)!.keys) == Set([
            "unrelated-fixture", ShepherdBrowserFeature.preferenceKey,
            PasswordManagerPreferences.managerKey, PasswordManagerPreferences.onboardingKey
        ]), "no owner/secret persisted; all state confined to injected suite")
        // A Settings/window close while runtime start awaits cannot leave a stale lease.
        defaults.set(false, forKey: ShepherdBrowserFeature.preferenceKey)
        defaults.removeObject(forKey: PasswordManagerPreferences.onboardingKey)
        let closing = ShepherdBrowserFeature(defaults: defaults)
        closing.passwordManagers.beginVisit(owner: a, browserEnabled: false)
        await closing.setEnabled(true, presentationOwner: a, canDisable: { true }, transition: {
            closing.passwordManagers.endVisit(owner: a)
        })
        precondition(closing.passwordManagers.onboarding == .pending && closing.passwordManagers.presentationOwner == nil)
        closing.passwordManagers.beginVisit(owner: b, browserEnabled: closing.isEnabled)
        precondition(closing.passwordManagers.presentationOwner == b, "later explicit visit resumes")
        closing.passwordManagers.endVisit(owner: b)
        closing.passwordManagers.connections.begin(owner: a, manager: .onePassword)
        let connectionGeneration = closing.passwordManagers.connections.generation
        await closing.setEnabled(false, canDisable: { true }, transition: {
            precondition(closing.passwordManagers.connections.owner == nil, "OFF revokes before teardown awaits")
            precondition(closing.passwordManagers.connections.generation > connectionGeneration)
        })
        // Machines is no longer an onboarding visit. Only entering the
        // Experimental Features page claims the presentation; Back is not Skip.
        defaults.set(false, forKey: ShepherdBrowserFeature.preferenceKey)
        defaults.removeObject(forKey: PasswordManagerPreferences.onboardingKey)
        let detail = ShepherdBrowserFeature(defaults: defaults)
        await detail.setEnabled(true, presentationOwner: a, canDisable: { true }, transition: {})
        precondition(detail.passwordManagers.onboarding == .pending)
        precondition(detail.passwordManagers.presentationOwner == nil, "Machines alone must not claim onboarding")
        detail.passwordManagers.beginVisit(owner: a, browserEnabled: detail.isEnabled)
        precondition(detail.passwordManagers.presentationOwner == a)
        detail.passwordManagers.endVisit(owner: a)
        precondition(detail.isEnabled && detail.passwordManagers.presentationOwner == nil)
        precondition(detail.passwordManagers.onboarding == .pending, "Back does not complete or skip onboarding")
        detail.passwordManagers.beginVisit(owner: b, browserEnabled: detail.isEnabled)
        precondition(detail.passwordManagers.presentationOwner == b, "explicit re-entry resumes pending selection")
        detail.passwordManagers.complete(owner: b, manager: .bitwarden)
        detail.passwordManagers.endVisit(owner: b)
        detail.passwordManagers.beginVisit(owner: a, browserEnabled: detail.isEnabled)
        precondition(detail.passwordManagers.presentationOwner == nil)
        precondition(detail.isEnabled && detail.passwordManagers.selectedManager == .bitwarden)
        precondition(detail.passwordManagers.connections.begin(owner: a, manager: .bitwarden))
        detail.passwordManagers.endVisit(owner: b)
        precondition(detail.passwordManagers.connections.owner == a, "another page/window cannot close this connection")
        detail.passwordManagers.endVisit(owner: a)
        await detail.passwordManagers.connections.awaitCredentialRevocation()
        precondition(detail.passwordManagers.connections.owner == nil)
        precondition(detail.isEnabled && detail.passwordManagers.selectedManager == .bitwarden)
        print("PASS: private defaults, accepted completion, overlap/no-op/rejected guards, one lease, cancel A/new B same process, once-only startup snapshot, concurrent window race, explicit visit/new process resume, pending ON/OFF restart, Skip keeps ON, switching, completed once, existing ON unseen, experimental page entry/back/re-entry and owner-scoped cleanup")
    }
}
