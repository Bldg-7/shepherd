import Foundation
import Observation

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct ShepherdBrowserFeatureTests {
    @MainActor static func main() async {
        let suite = "com.bldg-7.shepherd.feature-policy-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let feature = ShepherdBrowserFeature(defaults: defaults)
        precondition(!feature.isEnabled, "default OFF")
        let windowA = ObservationCounter(), windowB = ObservationCounter()
        withObservationTracking { _ = feature.isEnabled } onChange: { windowA.increment() }
        withObservationTracking { _ = feature.isEnabled } onChange: { windowB.increment() }
        let enabled = await feature.setEnabled(true, canDisable: { false }, transition: {})
        precondition(enabled && windowA.value == 1 && windowB.value == 1, "shared multiwindow observation")
        precondition(ShepherdBrowserFeature(defaults: defaults).isEnabled, "persisted ON")
        let refused = await feature.setEnabled(false, canDisable: { false }, transition: { fatalError("unsafe transition") })
        precondition(!refused && feature.isEnabled && defaults.bool(forKey: ShepherdBrowserFeature.preferenceKey) && feature.refusal != nil, "live/unknown activity refuses without preference change")
        let disabled = await feature.setEnabled(false, canDisable: { true }, transition: {})
        precondition(disabled && !ShepherdBrowserFeature(defaults: defaults).isEnabled && feature.refusal == nil, "safe inactive OFF persisted")
        await feature.setEnabled(true, canDisable: { true }, transition: {
            let pending = await feature.setEnabled(false, canDisable: { true }, transition: { fatalError("overlapping transition") })
            precondition(!pending && feature.isEnabled, "pending transition refusal")
        })
        print("PASS: default OFF, persistence, two window observers, live/unknown refusal, safe OFF, pending refusal")
    }
}
