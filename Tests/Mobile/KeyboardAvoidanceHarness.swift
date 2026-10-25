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
private final class HostedMeasurements {
    private var views: [String: WeakView] = [:]
    private var snapshots: [String: [CGRect]] = [:]

    final class WeakView {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    func record(_ name: String, view: UIView) {
        views[name] = WeakView(view)
        guard let window = view.window else { return }
        let rect = view.convert(view.bounds, to: window)
        guard rect.width > 0, rect.height > 0 else { return }
        snapshots[name, default: []].append(rect)
    }

    func rect(_ name: String) -> CGRect? {
        guard let view = views[name]?.view, let window = view.window else { return nil }
        return view.convert(view.bounds, to: window)
    }

    func firstRect(_ name: String) -> CGRect? { snapshots[name]?.first }
}

@MainActor
private final class PlacementProbeView: UIView {
    var name = ""
    weak var measurements: HostedMeasurements?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        measurements?.record(name, view: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        measurements?.record(name, view: self)
    }
}

private struct PlacementProbe: UIViewRepresentable {
    let name: String
    let measurements: HostedMeasurements

    func makeUIView(context: Context) -> PlacementProbeView {
        let view = PlacementProbeView()
        view.isUserInteractionEnabled = false
        view.name = name
        view.measurements = measurements
        return view
    }

    func updateUIView(_ view: PlacementProbeView, context: Context) {
        view.name = name
        view.measurements = measurements
        measurements.record(name, view: view)
    }
}

private struct FixtureComposer: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Prompt")
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(.blue.opacity(0.15), in: .capsule)
        .accessibilityIdentifier("fixture-composer")
    }
}

private struct FixtureResponseBar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The agent is waiting for an answer.")
                .font(.footnote)
            HStack {
                Text("Answer in words")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Type")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("fixture-response-bar")
    }
}

private struct HostedInputFixture: View {
    enum Mode: String, CaseIterable {
        case composer
        case responseBar
    }

    let mode: Mode
    let state: KeyboardAvoidanceState
    let source: KeyboardAvoidanceLayoutSource
    let measurements: HostedMeasurements
    let probeName: String

    var body: some View {
        KeyboardAvoidingBottomBarContainer(state: state, layoutSource: source) {
            Color.clear
        } bottomBar: {
            Group {
                switch mode {
                case .composer: FixtureComposer()
                case .responseBar: FixtureResponseBar()
                }
            }
            .background {
                PlacementProbe(name: probeName, measurements: measurements)
            }
        }
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
        Task { await runChecks() }
    }

    private func runChecks() async {
        UIView.setAnimationsEnabled(false)
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

        guard let window, let container = window.rootViewController else {
            failures.append("owned test window missing")
            finish(failures, hostedCases: [])
            return
        }
        let firstState = KeyboardAvoidanceState()
        let secondState = KeyboardAvoidanceState()
        let first = KeyboardAvoidanceView(state: firstState)
        let second = KeyboardAvoidanceView(state: secondState)
        let secondWindow = UIWindow(windowScene: window.windowScene!)
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

        firstState.bottomInset = 123
        KeyboardAvoidanceGuide.dismantleUIView(first, coordinator: ())
        require(firstState.bottomInset == 0 && first.state == nil,
            "dismantling must release its state and clear the inset")
        require(second.state === secondState,
            "dismantling one guide must not affect another window")
        second.removeFromSuperview()
        first.removeFromSuperview()

        var hostedCases: [[String: Any]] = []
        let screen = container.view.bounds.size
        let sizes: [(name: String, size: CGSize)] = [
            ("narrow", CGSize(width: min(320, screen.width), height: screen.height)),
            ("landscape-sized", CGSize(width: max(screen.width, screen.height), height: min(screen.width, screen.height))),
        ]
        for size in sizes {
            for mode in HostedInputFixture.Mode.allCases {
                let prefix = "\(size.name)/\(mode.rawValue)"
                let measurements = HostedMeasurements()
                let source = KeyboardAvoidanceLayoutSource(dockedBottomInset: 0)
                let state = KeyboardAvoidanceState()
                let host = addHost(
                    HostedInputFixture(mode: mode, state: state, source: source, measurements: measurements, probeName: prefix),
                    size: size.size, to: container)
                guard let baseline = await settle(host, measurements: measurements, name: prefix) else {
                    failures.append("\(prefix): missing baseline hosted input")
                    remove(host)
                    continue
                }
                require(abs(state.bottomInset) < 0.001, "\(prefix): baseline source must publish zero")

                source.dockedBottomInset = 120
                guard let docked = await settle(host, measurements: measurements, name: prefix) else {
                    failures.append("\(prefix): missing docked hosted input")
                    remove(host)
                    continue
                }
                require(abs(state.bottomInset - 120) < 0.001, "\(prefix): source update did not reach observable state")
                require(abs((baseline.minY - docked.minY) - 120) < 1,
                    "\(prefix): docked input must shift exactly by one guide inset")

                source.dockedBottomInset = 0
                guard let undocked = await settle(host, measurements: measurements, name: prefix) else {
                    failures.append("\(prefix): missing undocked hosted input")
                    remove(host)
                    continue
                }
                require(abs(undocked.minY - baseline.minY) < 1,
                    "\(prefix): undocked input must return to its normal safe-area position")
                hostedCases.append(["case": prefix, "baselineY": baseline.minY, "dockedY": docked.minY, "undockedY": undocked.minY])
                remove(host)

                // Start a fresh host with a valid docked source. Its first
                // probe layout must already be docked, not a transient zero
                // guide position that becomes visible after attachment.
                let initialMeasurements = HostedMeasurements()
                let initialSource = KeyboardAvoidanceLayoutSource(dockedBottomInset: 120)
                let initialState = KeyboardAvoidanceState()
                let initialName = prefix + "/initial-docked"
                let initialHost = addHost(
                    HostedInputFixture(mode: mode, state: initialState, source: initialSource, measurements: initialMeasurements, probeName: initialName),
                    size: size.size, to: container)
                guard let initial = await settle(initialHost, measurements: initialMeasurements, name: initialName) else {
                    failures.append("\(prefix): missing initial docked hosted input")
                    remove(initialHost)
                    continue
                }
                require(abs(initialState.bottomInset - 120) < 0.001,
                    "\(prefix): initial source did not publish before hosted layout")
                require(abs((baseline.minY - initial.minY) - 120) < 1,
                    "\(prefix): initial hosted layout used an erroneous zero-guide position")
                if let firstInitial = initialMeasurements.firstRect(initialName) {
                    require(abs((baseline.minY - firstInitial.minY) - 120) < 1,
                        "\(prefix): first hosted probe layout used an erroneous zero-guide position")
                } else {
                    failures.append("\(prefix): no first hosted probe layout")
                }
                remove(initialHost)
            }
        }
        finish(failures, hostedCases: hostedCases)
    }

    private func addHost(_ fixture: HostedInputFixture, size: CGSize, to container: UIViewController) -> UIHostingController<HostedInputFixture> {
        let host = UIHostingController(rootView: fixture)
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.autoresizingMask = []
        host.traitOverrides.horizontalSizeClass = size.width < 500 ? .compact : .regular
        host.didMove(toParent: container)
        return host
    }

    private func settle(_ host: UIViewController, measurements: HostedMeasurements, name: String) async -> CGRect? {
        for _ in 0..<8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return measurements.rect(name)
    }

    private func remove(_ host: UIViewController) {
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
    }

    private func finish(_ failures: [String], hostedCases: [[String: Any]]) {
        let report: [String: Any] = [
            "passed": failures.isEmpty,
            "failures": failures,
            "syntheticGeometry": true,
            "actualFloatingKeyboardUI": false,
            "guideConfiguration": true,
            "ownWindowIsolation": true,
            "lifetime": true,
            "hostedProductionWrapper": true,
            "hostedModes": ["Composer", "ResponseBar"],
            "hostedContainers": ["narrow", "landscape-sized"],
            "hostedCases": hostedCases,
            "deterministicLayoutSource": true,
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
