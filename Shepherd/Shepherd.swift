import SwiftUI

@main struct ShepherdApp: App {
    @State private var machineStore: MachineStore
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var softwareUpdater = SoftwareUpdater()
    #endif

    init() {
        #if DEBUG && os(macOS)
        let machineStore = HcMigrationConfiguration.current?.machineStore(keychain:HcFixtureSecrets()) ?? OwnedOperatorFixture.machineStore()
        #else
        let machineStore = MachineStore()
        #endif
        _machineStore = State(initialValue: machineStore)
        #if os(macOS)
        // The notifications watch every machine whether or not the window
        // is open, so they get the machines from here rather than from it.
        // They start once the app has finished launching (see `AppDelegate`).
        #if DEBUG
        if ShepherdBrowserFeature.isAvailable {
            NotificationCoordinator.shared.machineStore = machineStore
            MachineMonitors.shared.makeListener = { NotificationFeed(machine: $0) }
        } else { HcNotificationCoordinator.shared.machineStore = machineStore }
        #else
        HcNotificationCoordinator.shared.machineStore = machineStore
        #endif
        #endif
    }

    @ViewBuilder private var mainContent: some View {
        #if DEBUG && os(macOS)
        if let configuration = HcMigrationConfiguration.current {
            HcMigrationHost(configuration: configuration)
        } else if ShepherdLegacyFixtureRouting.enabled {
            legacyFixtureContent
        } else {
            hcContent
        }
        #else
        hcContent
        #endif
    }

    /// Ordinary Debug and Release use hc, including unavailable/error states.
    /// Installation/service qualification does not select another backend.
    private var hcContent: some View {
        ShepherdHcContent(machineStore: machineStore)
            #if os(macOS)
            .environment(softwareUpdater)
            #endif
    }

    #if DEBUG && os(macOS)
    /// Retained only for explicitly isolated legacy fixtures, never fallback.
    private var legacyFixtureContent: some View {
        ContentView(machineStore: machineStore)
            .defaultAppStorage(OwnedOperatorFixture.configuration?.defaults ?? .standard)
            .environment(softwareUpdater)
    }
    #endif

    var body: some Scene {
        // The app has one window. A `Window` rather than a `WindowGroup`:
        // there is no New Window to make another with, and no window tabs.
        Window(Text(verbatim: "hrdrhrdrhrdr"), id: "main") {
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
        // No smaller than its content allows: see `WorkspaceWindowMetrics`.
        .windowResizability(.contentMinSize)
        .commands {
            CheckForUpdatesCommands(updater: softwareUpdater)
            SettingsCommands()
            NewTabCommands()
            PaneSwitcherCommands()
            CloseCommands()
        }
        #endif
    }
}

#if os(macOS)
/// Not a product backend switch: only validated, isolated DEBUG fixtures may
/// supply legacy content/menu bindings. A failed hc connection cannot enable it.
@MainActor enum ShepherdLegacyFixtureRouting {
    static var enabled: Bool {
        #if DEBUG
        guard !HcMigrationConfiguration.requested else { return false }
        return OwnedOperatorFixture.configuration != nil || ShepherdBrowserFeature.isAvailable
        #else
        return false
        #endif
    }
}

/// One hc product composition for ordinary entry and resource-isolated tests.
/// Fixtures may supply an owned store/connection, never a different backend.
struct ShepherdHcContent: View {
    let machineStore: MachineStore
    var connection: HcMachineConnection? = nil
    var localTransportFactory: (@MainActor () throws -> any CoreByteTransport)? = nil
    var inspectionOnly = false
    var body: some View {
        HcRootView(machineStore: machineStore, connection: connection,
                   localTransportFactory: localTransportFactory, inspectionOnly: inspectionOnly)
            .onAppear {
                #if DEBUG
                if let configuration = HcMigrationConfiguration.current {
                    let receipt: [String: Any] = ["root": "HcRootView", "composition": "ShepherdHcContent",
                        "sharedProductComposition": true, "legacyFixtureRouting": ShepherdLegacyFixtureRouting.enabled]
                    try? JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
                        .write(to: configuration.root.appending(path: "product-root.json"), options: .atomic)
                }
                #endif
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS 26 AppKit draws large `draw(_:)`-backed view layers (the
        // terminal) through QuartzCore's in-process Metal renderer by default.
        // That renderer's glyph path issues a draw call Metal API Validation
        // rejects, which aborts debug runs. Opting out keeps view drawing on
        // the CoreGraphics path. AppKit reads this once, on the first layer
        // display, and only honors a real Bool.
        UserDefaults.standard.register(defaults: ["NSViewCanUseGPUAcceleration": false])
        #if DEBUG
        if HcMigrationConfiguration.requested { return } // Private hc root never initializes legacy/browser/proxy services.
        #endif
        #if DEBUG
        if ShepherdBrowserFeature.isAvailable {
            prepareLegacyFixture()
            return
        }
        #endif
        // No legacy/capture/runtime startup, including when hc is missing.
        HcNotificationCoordinator.shared.prepare()
    }

    #if DEBUG
    private func prepareLegacyFixture() {
        if ShepherdBrowserFeature.shared.isEnabled { BrowserEngine.prepare() }
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
        // Before launching finishes, so that a click on a notification that
        // launched the app gets to it.
        NotificationCoordinator.shared.prepare()
        // The agent proxy as its setting left it, whether or not the browser
        // is on: agents may still be using it (SHPHRD-105).
        AgentLaunchService.shared.agentProxy = AgentProxyService.shared
        AgentProxyService.shared.start()
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        AgentLaunchService.shared.start()
        Task {
            let port = OwnedOperatorFixture.configuration == nil ? UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? CDPProxy.defaultPort : 0
            await CDPProxy.shared.start(port: port)
        }
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if HcMigrationConfiguration.requested { return }
        OwnedOperatorFixture.didLaunch()
        if ShepherdBrowserFeature.isAvailable { NotificationCoordinator.shared.start(); return }
        #endif
        HcNotificationCoordinator.shared.start()
    }

    /// Closing the window is not quitting, which is what an app whose one
    /// scene is a `Window` does unless told otherwise. The app stays up
    /// without it; hc owns the programs independently. A click on the Dock
    /// icon brings the window back. This does not stop or replace the core.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Ordinary hc quit does not stop the core or its programs. Browser
    /// shutdown is retained only for explicitly isolated DEBUG fixtures.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if HcMigrationConfiguration.requested { return .terminateNow }
        if ShepherdBrowserFeature.isAvailable { return terminateLegacyFixture(sender) }
        #endif
        HcNotificationCoordinator.shared.clearBadgeBeforeQuitting()
        return .terminateNow
    }

    #if DEBUG
    private func terminateLegacyFixture(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        NotificationCoordinator.shared.clearBadgeBeforeQuitting()
        ShepherdBrowserFeature.shared.removeFixtureDefaults()
        OwnedOperatorFixture.cleanUp()
        return .terminateNow
    }
    #endif
}

extension FocusedValues {
    /// Whether the window has its Settings sheet up — see
    /// `SettingsCommands`.
    @Entry var isShowingSettings: Binding<Bool>?
    /// How the window's new tab launcher came up, with nil in it while the
    /// launcher isn't up — see `NewTabCommands`, which set it. The binding
    /// itself is nil while there is no machine to open a tab on.
    @Entry var launcherStart: Binding<LauncherStart?>?
    @Entry var isShowingPaneSwitcher: Binding<Bool>?
    /// What the window's Close Tab or Close Pane would close — see
    /// `CloseCommands`. Nil only while there is no window.
    @Entry var closeCommand: CloseCommand?
    /// What the File menu's Add herdr Machine… and Remove herdr Machine…
    /// act on — see `NewTabCommands`. Nil while there is no machine.
    @Entry var herdrMachineCommand: HerdrMachineCommand?
}

/// The window's side of the File menu's herdr machine items (see
/// `NewTabCommands`).
struct HerdrMachineCommand {
    /// Whether a herdr machine can be added to the active machine's herdr
    /// now: it is This Mac's, it can have them, and nothing else is up over
    /// the window.
    let canAdd: Bool
    /// Why not, shown under the item, while the active machine isn't This
    /// Mac (see `LocalOnlyAddition`).
    let addUnavailableReason: String?
    /// The herdr machine the selection is on, which Remove herdr Machine…
    /// is for; nil, and the item not there, for a selection on the host's
    /// own herdr or none.
    let selectedMachine: HerdrMachine?
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void
}

/// The window's side of `CloseCommands`: what ⌘W would close, and the
/// count that has the board close it when it goes up.
struct CloseCommand {
    let target: CloseCommandTarget
    let requests: Binding<Int>
}

/// The File menu's Close Tab or Close Pane (⌘W), which closes the selected
/// tab or pane after the sidebar's confirmation. It takes the place of
/// Close, whose ⌘W closed the window — the app's one, and every terminal in
/// it with it. Close Window stays, without a shortcut.
private struct CloseCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared
    @FocusedValue(\.closeCommand) private var closeCommand
    var body: some Commands { CommandGroup(replacing: .saveItem) { HcCloseMenuItems(actions: hcCommands.actions, legacy: ShepherdLegacyFixtureRouting.enabled ? closeCommand : nil) } }
}
private struct NewTabCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared
    @FocusedValue(\.launcherStart) private var launcherStart
    @FocusedValue(\.herdrMachineCommand) private var herdrMachineCommand
    var body: some Commands { CommandGroup(replacing: .newItem) { HcNewTabMenuItems(actions: hcCommands.actions, legacy: ShepherdLegacyFixtureRouting.enabled ? launcherStart : nil, machine: ShepherdLegacyFixtureRouting.enabled ? herdrMachineCommand : nil) } }
}
private struct PaneSwitcherCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared
    @FocusedValue(\.isShowingPaneSwitcher) private var switcher
    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .newItem) { HcPaneSwitcherMenuItem(actions: hcCommands.actions, legacy: ShepherdLegacyFixtureRouting.enabled ? switcher : nil) }
    }
}

/// The app menu's Settings… item, in the place and with the ⌘, the menu
/// keeps for it. Settings is a sheet over the main window rather than a
/// window of its own (a `Settings` scene), so the item opens it over the
/// main window, and is unavailable while that is closed.
private struct SettingsCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared
    @FocusedValue(\.isShowingSettings) private var isShowingSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) { HcSettingsMenuItem(actions: hcCommands.actions, legacy: ShepherdLegacyFixtureRouting.enabled ? isShowingSettings : nil) }
    }
}
#endif
