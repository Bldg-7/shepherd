import SwiftUI

@main struct ShepherdApp: App {
    #if DEBUG && os(macOS)
    @State private var machineStore = OwnedOperatorFixture.machineStore()
    #else
    @State private var machineStore = MachineStore()
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var softwareUpdater = SoftwareUpdater()
    #endif

    private var mainContent: some View {
        ContentView(machineStore: machineStore)
            #if DEBUG && os(macOS)
            .defaultAppStorage(OwnedOperatorFixture.configuration?.defaults ?? .standard)
            #endif
            #if os(macOS)
            .environment(softwareUpdater)
            #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && os(macOS)
            if ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_FEATURE_FIXTURE"] != nil ||
                ProcessInfo.processInfo.environment["SHEPHERD_AGENT_LAUNCH_FIXTURE"] != nil ||
                ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_B_PROBE"] != nil ||
                ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_SELFTEST"] != nil ||
                ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_PHASE2_FIXTURE"] != nil {
                Color.clear.frame(width: 1, height: 1)
            } else {
                mainContent
            }
            #else
            mainContent
            #endif

        }
        #if os(macOS)
        .commands {
            CheckForUpdatesCommands(updater: softwareUpdater)
            SettingsCommands()
            NewTabCommands()
        }
        #endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if ShepherdBrowserFeature.shared.isEnabled { BrowserEngine.prepare() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_FEATURE_FIXTURE"] != nil {
            ShepherdBrowserFeatureFixture.run()
            return
        }
        if ProcessInfo.processInfo.environment["SHEPHERD_AGENT_LAUNCH_FIXTURE"] != nil {
            AgentLaunchFixture.run()
            return
        }
        if ProcessInfo.processInfo.environment["SHEPHERD_NATIVE_B_PROBE"] != nil {
            NativeBProbe.run()
            return
        }
        if ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_PHASE2_FIXTURE"] != nil {
            BrowserPhase2Fixture.run()
            return
        }
        if ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_SELFTEST"] != nil {
            precondition(ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_TEST_ROOT"] != nil,
                         "Self tests require a disposable profile root")
            BrowserSelfTest.runIfRequested()
            return
        }
        #endif
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        AgentLaunchService.shared.start()
        Task {
            #if DEBUG
            let port = OwnedOperatorFixture.configuration == nil ? UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? 9333 : 0
            #else
            let port = UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? 9333
            #endif
            await CDPProxy.shared.start(port: port)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        OwnedOperatorFixture.didLaunch()
        #endif
    }

    /// The browser's pages are closed and its engine shut down before the
    /// app goes, so that cookies and the rest reach the disk (plan item F8
    /// in docs/agent-browser-plan.md). It has to happen in here, before
    /// returning: nothing asynchronous gets to run once the app is quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if CDPProxy.shared.activeConnections > 0 {
            let alert = NSAlert()
            alert.messageText = String(localized: "Disconnect browser agents and quit?")
            alert.informativeText = String(localized: "Connected agents will lose browser access. Their terminal processes will keep running.")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        guard BrowserStore.shared.shutDownNow() else {
            // Quit remains available with no windows or selected browser. Its
            // failure must therefore be presented at application level.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Could not quit safely")
            alert.informativeText = BrowserStore.shared.engineError ?? String(localized: "Browser cleanup could not be confirmed. Quit was canceled to preserve browser data.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return .terminateCancel
        }
        MachineBrowserService.shared.stop()
        #if DEBUG
        ShepherdBrowserFeature.shared.removeFixtureDefaults()
        OwnedOperatorFixture.cleanUp()
        #endif
        return .terminateNow
    }
}

extension FocusedValues {
    /// Whether the front window has its Settings sheet up — see
    /// `SettingsCommands`.
    @Entry var isShowingSettings: Binding<Bool>?
    /// Whether the front window has its new tab launcher up — see
    /// `NewTabCommands`. Nil while there is no machine to open a tab on.
    @Entry var isShowingLauncher: Binding<Bool>?
}

/// The File menu's New Tab… (⌘T), which brings up the front window's new
/// tab launcher — what the plus over the sidebar does.
private struct NewTabCommands: Commands {
    @FocusedValue(\.isShowingLauncher) private var isShowingLauncher

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab…") {
                isShowingLauncher?.wrappedValue = true
            }
            .keyboardShortcut("t")
            .disabled(isShowingLauncher == nil)
        }
    }
}

/// The app menu's Settings… item, in the place and with the ⌘, the menu
/// keeps for it. Settings is a sheet over the main window rather than a
/// window of its own (a `Settings` scene), so the item opens it over
/// whichever main window is in front, and is unavailable with none.
private struct SettingsCommands: Commands {
    @FocusedValue(\.isShowingSettings) private var isShowingSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                isShowingSettings?.wrappedValue = true
            }
            .keyboardShortcut(",")
            .disabled(isShowingSettings == nil)
        }
    }
}
#endif
