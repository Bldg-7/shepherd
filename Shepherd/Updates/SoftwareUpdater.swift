#if os(macOS)
import Combine
import Sparkle
import SwiftUI

/// Shepherd updating itself on macOS, by Sparkle. Sparkle reads the feed the
/// app's Info.plist names (`SUFeedURL`, from the `SPARKLE_FEED_URL` build
/// setting) and installs an update from it only once the update's EdDSA
/// signature checks out against `SUPublicEDKey`. It keeps its own settings,
/// among them whether to check on its own, which it asks the person about on
/// the app's second launch.
///
/// A build with no feed — a debug build, whose `SPARKLE_FEED_URL` is empty —
/// has no updater at all, so a build run from Xcode never offers to replace
/// itself with a release.
///
/// An update relaunches the app, and that leaves the agents alone: the panes
/// they run in belong to herdr, and Shepherd only attaches to them.
@Observable
final class SoftwareUpdater {
    private let controller: SPUStandardUpdaterController?

    /// Whether a check can start now — not while one is already under way.
    private(set) var canCheckForUpdates = false

    /// Sparkle's own setting, mirrored here so that SwiftUI sees it change,
    /// as it does when Sparkle asks the person about it.
    var automaticallyChecksForUpdates = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @ObservationIgnored private var observations: Set<AnyCancellable> = []

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !feed.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
            .store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] checks in self?.automaticallyChecksForUpdates = checks }
            .store(in: &observations)
    }

    /// Whether this build updates itself at all.
    var isAvailable: Bool { controller != nil }

    /// Checks now, showing what it finds — an update, or that there is none.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// The version the person is running, as About Shepherd shows it.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(version) (\(build))")
    }
}

/// The app menu's Check for Updates…, under About Shepherd, where Mac apps
/// keep it. Not there at all in a build that doesn't update itself.
struct CheckForUpdatesCommands: Commands {
    let updater: SoftwareUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                CheckForUpdatesButton(updater: updater)
            }
        }
    }
}

/// A view of its own, so that the button follows `canCheckForUpdates`:
/// SwiftUI tracks what a view reads, and a Commands body alone doesn't get
/// redrawn for it.
private struct CheckForUpdatesButton: View {
    let updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
#endif
