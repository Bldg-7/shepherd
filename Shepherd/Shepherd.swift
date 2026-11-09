import SwiftUI

@main struct ShepherdApp: App {
    @State private var machineStore: MachineStore
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var softwareUpdater = SoftwareUpdater()
    #endif

    init() {
        #if DEBUG && os(macOS)
        let machineStore = HcMigrationConfiguration.current?.machineStore(keychain:HcFixtureSecrets()) ?? MachineStore()
        #else
        let machineStore = MachineStore()
        #endif
        _machineStore = State(initialValue: machineStore)
        #if os(macOS)
        // The notifications watch every machine whether or not the window
        // is open, so they get the machines from here rather than from it.
        // They start once the app has finished launching (see `AppDelegate`).
        HcNotificationCoordinator.shared.machineStore = machineStore
        #endif
    }

    @ViewBuilder private var mainContent: some View {
        #if DEBUG && os(macOS)
        if let configuration = HcMigrationConfiguration.current {
            HcMigrationHost(configuration: configuration)
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

    var body: some Scene {
        // The app has one window. A `Window` rather than a `WindowGroup`:
        // there is no New Window to make another with, and no window tabs.
        Window(Text(verbatim: "hrdrhrdrhrdr"), id: "main") {
            mainContent
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
                        "sharedProductComposition": true]
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
        if HcMigrationConfiguration.requested { return }
        #endif
        HcNotificationCoordinator.shared.prepare()
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if HcMigrationConfiguration.requested { return }
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

    /// Quitting does not stop the core or its programs.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if HcMigrationConfiguration.requested { return .terminateNow }
        #endif
        HcNotificationCoordinator.shared.clearBadgeBeforeQuitting()
        return .terminateNow
    }
}

/// The File menu's Close Tab or Close Pane (⌘W), which closes the selected
/// tab or pane after the sidebar's confirmation. It takes the place of
/// Close, whose ⌘W closed the window — the app's one, and every terminal in
/// it with it. Close Window stays, without a shortcut.
private struct CloseCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared
    var body: some Commands { CommandGroup(replacing: .saveItem) { HcCloseMenuItems(actions: hcCommands.actions) } }
}
private struct NewTabCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared
    var body: some Commands { CommandGroup(replacing: .newItem) { HcNewTabMenuItems(actions: hcCommands.actions) } }
}
private struct PaneSwitcherCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared
    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .newItem) { HcPaneSwitcherMenuItem(actions: hcCommands.actions) }
    }
}

/// The app menu's Settings… item, in the place and with the ⌘, the menu
/// keeps for it. Settings is a sheet over the main window rather than a
/// window of its own (a `Settings` scene), so the item opens it over the
/// main window, and is unavailable while that is closed.
private struct SettingsCommands: Commands {
    @ObservedObject private var hcCommands = HcWindowCommandState.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) { HcSettingsMenuItem(actions: hcCommands.actions) }
    }
}
#endif
