import Foundation

/// The version and build the person is running, as Settings shows them:
/// `0.3.1 (25)`, and `0.3.1 (25) - debug` for a build of the Debug
/// configuration, so that a build run from Xcode can't pass for a release.
///
/// Both numbers come from Info.plist, where Xcode puts the target's
/// `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; the release script
/// sets them on its command line.
nonisolated struct AppVersion {
    let version: String
    let build: String
    let isDebug: Bool

    init(infoDictionary: [String: Any]?, isDebug: Bool) {
        version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        self.isDebug = isDebug
    }

    static let current: AppVersion = {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return AppVersion(infoDictionary: Bundle.main.infoDictionary, isDebug: isDebug)
    }()

    /// Not localized: "debug" names the build configuration, for whoever
    /// works on Shepherd, and reads the same in every language.
    var displayString: String {
        "\(version) (\(build))" + (isDebug ? " - debug" : "")
    }
}
