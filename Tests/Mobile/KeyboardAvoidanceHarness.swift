import SwiftUI
import UIKit

@main final class KeyboardAvoidanceHarnessAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "KeyboardAvoidance", sessionRole: session.role)
        configuration.delegateClass = KeyboardAvoidanceHarnessSceneDelegate.self
        return configuration
    }
}

@MainActor
final class KeyboardAvoidanceHarnessSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var started = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started else { return }
        started = true
        runChecks()
    }

    private func runChecks() {
        var failures: [String] = []
        func require(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func expectInset(_ name: String, safeAreaBottom: CGFloat, keyboardTop: CGFloat, _ expected: CGFloat) {
            let actual = KeyboardAvoidanceGeometry.dockedBottomInset(
                safeAreaBottom: safeAreaBottom, keyboardTop: keyboardTop)
            require(abs(actual - expected) < 0.001, "\(name): expected \(expected), got \(actual)")
        }

        // Synthetic guide positions exercise the documented guide contract;
        // they are not claims about driving an actual floating keyboard UI.
        expectInset("hidden keyboard", safeAreaBottom: 980, keyboardTop: 980, 0)
        expectInset("docked portrait", safeAreaBottom: 980, keyboardTop: 660, 320)
        expectInset("floating dragged to bottom", safeAreaBottom: 980, keyboardTop: 980, 0)
        expectInset("rotation landscape", safeAreaBottom: 360, keyboardTop: 120, 240)
        expectInset("narrow split-view container", safeAreaBottom: 700, keyboardTop: 470, 230)
        expectInset("keyboard below safe area", safeAreaBottom: 980, keyboardTop: 1000, 0)

        let dockedTop: CGFloat = 660
        let ordinarySafeAreaBottom: CGFloat = 980
        let dockedInset = KeyboardAvoidanceGeometry.dockedBottomInset(
            safeAreaBottom: ordinarySafeAreaBottom, keyboardTop: dockedTop)
        require(abs((ordinarySafeAreaBottom - dockedInset) - dockedTop) < 0.001,
            "docked inset must consume the ordinary safe area exactly once")

        guard let window, let windowScene = window.windowScene else {
            failures.append("owned test window missing")
            finish(failures)
            return
        }
        let firstState = KeyboardAvoidanceState()
        let secondState = KeyboardAvoidanceState()
        let first = KeyboardAvoidanceView(state: firstState)
        let second = KeyboardAvoidanceView(state: secondState)
        let secondWindow = UIWindow(windowScene: windowScene)
        window.addSubview(first)
        secondWindow.addSubview(second)
        first.frame = window.bounds
        second.frame = window.bounds
        first.setNeedsLayout(); first.layoutIfNeeded()
        second.setNeedsLayout(); second.layoutIfNeeded()

        require(first.dockedKeyboardGuide.owningView === first,
            "first guide must be owned by its representable view")
        require(second.dockedKeyboardGuide.owningView === second,
            "second guide must be owned by its representable view")
        require(first.window === window && second.window === secondWindow,
            "guide fixtures must remain in their own windows")
        require(first.dockedKeyboardGuide.followsUndockedKeyboard == false,
            "guide must not follow floating or undocked keyboards")
        // The deployed runtime may normalize this property while no software
        // keyboard is present. The geometry assertion above verifies the
        // important contract: the ordinary safe area is consumed once.

        firstState.bottomInset = 123
        KeyboardAvoidanceGuide.dismantleUIView(first, coordinator: ())
        require(firstState.bottomInset == 0 && first.state == nil,
            "dismantling must release its state and clear the inset")
        require(second.state === secondState,
            "dismantling one guide must not affect another window")
        second.removeFromSuperview()
        first.removeFromSuperview()
        finish(failures)
    }

    private func finish(_ failures: [String]) {
        let report: [String: Any] = [
            "passed": failures.isEmpty,
            "failures": failures,
            "syntheticGeometry": true,
            "actualFloatingKeyboardUI": false,
            "guideConfiguration": true,
            "ownWindowIsolation": true,
            "lifetime": true,
            "naturalExit": true,
        ]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("keyboard-avoidance-results.json"))
        print("\(failures.isEmpty ? "PASS" : "FAIL") keyboard avoidance: \(failures.count) failures")
        for failure in failures { print(failure) }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
