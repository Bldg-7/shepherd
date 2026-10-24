import UIKit
import SwiftUI

@MainActor final class Measurements {
    var views: [String: WeakView] = [:]
    var textSizes: [String: DynamicTypeSize] = [:]
    func rect(_ key: String) -> CGRect? {
        guard let view = views[key]?.view, let window = view.window else { return nil }
        return view.convert(view.bounds, to: window)
    }
    func visibleRect(_ key: String) -> CGRect? {
        guard let view = views[key]?.view, let window = view.window else { return nil }
        var rect = view.convert(view.bounds, to: window)
        var ancestor = view.superview
        while let parent = ancestor {
            if parent.clipsToBounds { rect = rect.intersection(parent.convert(parent.bounds, to: window)) }
            ancestor = parent.superview
        }
        return rect
    }
    final class WeakView { weak var view: UIView?; init(_ view: UIView) { self.view = view } }
}
private struct Measure: UIViewRepresentable {
    let name: String
    let values: Measurements
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        values.views[name] = .init(view)
        values.textSizes[name] = context.environment.dynamicTypeSize
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        values.views[name] = .init(view)
        values.textSizes[name] = context.environment.dynamicTypeSize
    }
}
private struct Fixture: View {
    let title: String
    let labels: [String]
    let state: Int
    let extraActions: Bool
    let values: Measurements
    @State private var path = ["pane"]
    private func resource(_ text: String) -> LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }
    var body: some View {
        NavigationStack(path: $path) {
            Color.clear.navigationTitle("Paired Mac")
                .navigationDestination(for: String.self) { _ in
                    Color.clear
                        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                PaneStatusBadge(title: resource(labels[state]), reservedTitles: labels.map(resource), color: .orange)
                                    .background { Measure(name: "badge", values: values) }
                            }.sharedBackgroundVisibility(.hidden)
                            // Stress the same icon controls beside the pane
                            // badge, even when navigation would hide root menus.
                            if extraActions {
                            ToolbarItem(placement: .topBarLeading) {
                                Menu { Button("Owned fixture") {} } label: {
                                    MobileToolbarIcon(title: "About", systemImage: "info.circle")
                                        .background { Measure(name: "about", values: values) }
                                }.fixedSize(horizontal: true, vertical: false)
                                .accessibilityIdentifier("machines-about")
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Menu { Button("Owned fixture") {} } label: {
                                    MobileToolbarIcon(title: "Add Machine", systemImage: "plus")
                                        .background { Measure(name: "add", values: values) }
                                }.fixedSize(horizontal: true, vertical: false)
                                .accessibilityIdentifier("machines-add")
                            }
                            }
                        }
                }
        }
    }
}

@main final class LayoutAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Layout", sessionRole: session.role)
        config.delegateClass = LayoutSceneDelegate.self
        return config
    }
}
final class LayoutSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var started = false
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard !started else { return }; started = true
        Task { await runChecks() }
    }
    private func runChecks() async {
        UIView.setAnimationsEnabled(false)
        guard let window, let container = window.rootViewController else { fatalError("owned test scene missing") }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let widths: [CGFloat] = pad ? [320, 375, 600, 820, 1024] : [320, 375, 393]
        let labelsURL = Bundle.main.url(forResource: "labels", withExtension: "json")!
        let translated = try! JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: labelsURL))
        let languages = ["en", "ko", "ja"].map { ($0, translated[$0]!) }
        var results: [[String: Any]] = [], failures: [String] = []
        for (language, labels) in languages {
            for size in [DynamicTypeSize.large, .xxxLarge] {
                for width in widths {
                  for extraActions in [false, true] {
                    var baseline: [String: CGFloat] = [:]
                    for (index, title) in ["Pane", String(repeating: "Long pane title · ", count: 8), "Short"].enumerated() {
                        let values = Measurements()
                        let fixture = Fixture(title: title, labels: labels, state: index == 0 ? 0 : 2, extraActions: extraActions, values: values)
                            .environment(\.dynamicTypeSize, size)
                            .environment(\.locale, Locale(identifier: language))
                        let host = UIHostingController(rootView: fixture)
                        container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent: container)
                        host.view.frame = CGRect(x: 0, y: 0, width: width, height: container.view.bounds.height)
                        host.view.autoresizingMask = []
                        host.traitOverrides.horizontalSizeClass = width < 500 ? .compact : .regular
                        let end = ContinuousClock.now.advanced(by: .seconds(3))
                        while (values.rect("badge")?.width ?? 0) <= 0 && ContinuousClock.now < end {
                            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        // Drain navigation and hosted-toolbar sizing transactions.
                        for _ in 0..<5 { host.view.layoutIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) }
                        let key = "\(language)/\(size)/\(width)/actions=\(extraActions)/\(index)"
                        var entry: [String: Any] = ["case": key]
                        if index == 0 {
                            func controls(_ view: UIView) -> [[String: Any]] {
                                var found: [[String: Any]] = []
                                if view is UIControl || view.accessibilityIdentifier != nil {
                                    let rect = view.convert(view.bounds, to: window)
                                    found.append(["type": String(describing: type(of: view)), "id": view.accessibilityIdentifier ?? "", "label": view.accessibilityLabel ?? "", "frame": [rect.minX, rect.minY, rect.width, rect.height]])
                                }
                                return found + view.subviews.flatMap { controls($0) }
                            }
                            entry["controls"] = controls(host.view)
                            entry["badgeTextSize"] = String(describing: values.textSizes["badge"])
                        }
                        func require(_ ok: Bool, _ message: String) { if !ok { failures.append(key + ": " + message) } }
                        // SwiftUI converts Menu labels into native bar buttons;
                        // their label backgrounds are not retained views. Measure
                        // the outer native controls instead of a fake label probe.
                        func navigation(_ controller: UIViewController) -> UINavigationController? {
                            if let found = controller as? UINavigationController { return found }
                            return controller.children.lazy.compactMap { navigation($0) }.first
                        }
                        func topControls(_ view: UIView) -> [UIControl] {
                            if let control = view as? UIControl {
                                return control.isHidden || control.bounds.width < 1 ? [] : [control]
                            }
                            return view.subviews.flatMap { topControls($0) }
                        }
                        // UIKit can put an already-ellipsized string in its
                        // title UILabel, so matching the original title text is
                        // not a valid lookup. In this controlled fixture the
                        // native title is the short, label-bearing control;
                        // back/menu controls retain their >=32-point frames.
                        func hasLabel(_ view: UIView) -> Bool { view is UILabel || view.subviews.contains { hasLabel($0) } }
                        let nativeControls = topControls(navigation(host)?.navigationBar ?? host.view)
                        let titleControls = nativeControls.filter { $0.bounds.height < 30 && hasLabel($0) }
                        require(titleControls.count <= 1, "ambiguous native title geometry")
                        if let control = titleControls.first { values.views["title"] = .init(control) }
                        let buttonRects = nativeControls.filter { control in !titleControls.contains { $0 === control } }.map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }
                        let buttonNames = extraActions ? ["back", "about", "add"] : ["back"]
                        require(buttonRects.count == buttonNames.count, "native toolbar controls must exist")
                        for (name, rect) in zip(buttonNames, buttonRects) {
                            entry[name] = [rect.minX, rect.minY, rect.width, rect.height]
                            require(rect.width >= 32 && rect.height >= 32, name + " native control collapsed")
                            if let first = baseline[name] { require(abs(first - rect.width) < 1, name + " width changed with title/state") }
                            else { baseline[name] = rect.width }
                        }
                        for name in ["badge", "title"] {
                            guard let rect = values.rect(name) else {
                                // UIKit can collapse its centered title when
                                // stress-only actions leave a tiny center span.
                                // Its threshold differs across OS versions. The
                                // actual pane bar (Back + badge) must retain it.
                                let sideWidth = max(buttonRects.dropLast().map(\.maxX).max() ?? 0,
                                    width - (values.rect("badge")?.minX ?? width))
                                let crowdedStress = extraActions && width - 2 * sideWidth < 100
                                if name == "title" && crowdedStress { entry["nativeTitleCollapsed"] = true }
                                else { failures.append(key + ": missing " + name) }
                                continue
                            }
                            entry[name] = [rect.minX, rect.minY, rect.width, rect.height]
                            if name == "badge" {
                                require(rect.width > 10 && rect.height > 10, "badge has usable intrinsic size")
                                if let first = baseline[name] { require(abs(first - rect.width) < 1, "badge width changed with title/state") }
                                else { baseline[name] = rect.width }
                                if let visible = values.visibleRect(name) { require(visible.width + 1 >= rect.width, "badge clipped by an ancestor") }
                            }
                        }
                        if let badge = values.rect("badge") {
                            let intrinsic = UIHostingController(rootView: PaneStatusBadge(title: LocalizedStringResource(stringLiteral: labels[2]), reservedTitles: labels.map { LocalizedStringResource(stringLiteral: $0) }, color: .orange).environment(\.dynamicTypeSize, values.textSizes["badge"] ?? size))
                            let ideal = intrinsic.sizeThatFits(in: CGSize(width: 2000, height: 200))
                            require(badge.width + 1 >= ideal.width, "badge is narrower than its full localized status labels")
                        }
                        if let titleRect = values.rect("title"), let badge = values.rect("badge") {
                            require(titleRect.intersection(badge).width <= 1 || !titleRect.intersects(badge), "title overlaps status")
                        }
                        results.append(entry)
                        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                    }
                  }
                }
            }
        }
        let result: [String: Any] = ["device": pad ? "iPad" : "iPhone", "cases": results, "failures": failures, "passed": failures.isEmpty, "realNavigationStack": true, "networkOrCredentials": false]
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("layout-results.json")
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        print("\(failures.isEmpty ? "PASS" : "FAIL") \(pad ? "iPad" : "iPhone") pane header layout: \(results.count) cases, \(failures.count) failures")
        for failure in failures.prefix(12) { print(failure) }
        fflush(stdout)
        exit(failures.isEmpty ? 0 : 1)
    }
}
