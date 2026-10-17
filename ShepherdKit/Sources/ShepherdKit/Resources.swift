import Foundation

/// Where the package's string catalog is, for every way the package gets
/// built.
///
/// SwiftPM synthesises `Bundle.module` for a target with resources, but
/// that accessor stops the process when the resource bundle isn't where it
/// expects it, and it doesn't exist at all when these sources are compiled
/// on their own, as the test runners under Tests/ compile them. This looks
/// in the same places SwiftPM's accessor does — the app's resources, for a
/// package Xcode built into an app; next to the executable, for a `swift
/// build`; the package's own bundle, when it is a framework — and falls
/// back to the main bundle, where the strings were before they moved here,
/// rather than stopping.
nonisolated enum ShepherdKitResources {
    /// `<package>_<target>`, the name SwiftPM gives a target's resource bundle.
    static let bundleName = "ShepherdKit_ShepherdKit"

    static let bundle: Bundle = {
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL
        ]
        for candidate in candidates {
            guard let url = candidate?.appendingPathComponent(bundleName + ".bundle"),
                  let bundle = Bundle(url: url) else { continue }
            return bundle
        }
        // A built app always carries the bundle; its absence there is a
        // packaging mistake, not a case to run quietly past.
        assert(Bundle.main.bundleURL.pathExtension != "app", "ShepherdKit's resource bundle is missing from the app")
        return .main
    }()

    private final class BundleFinder {}
}

extension LocalizedStringResource.BundleDescription {
    /// The package's string catalog, for `LocalizedStringResource`.
    nonisolated static var shepherdKit: Self { .atURL(ShepherdKitResources.bundle.bundleURL) }
}

extension Bundle {
    /// The package's string catalog, for `String(localized:bundle:)`.
    nonisolated static var shepherdKit: Bundle { ShepherdKitResources.bundle }
}
