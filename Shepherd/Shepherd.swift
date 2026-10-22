import SwiftUI

@main struct ShepherdApp: App {
    @State private var machineStore: MachineStore
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var softwareUpdater = SoftwareUpdater()
    #endif

    init() {
        #if DEBUG && os(macOS)
        let machineStore = OwnedOperatorFixture.machineStore()
        #else
        let machineStore = MachineStore()
        #endif
        _machineStore = State(initialValue: machineStore)
        #if os(macOS)
        // The notifications watch every machine whether or not the window
        // is open, so they get the machines from here rather than from it.
        // They start once the app has finished launching (see `AppDelegate`).
        NotificationCoordinator.shared.machineStore = machineStore
        MachineMonitors.shared.makeListener = { NotificationFeed(machine: $0) }
        #endif
    }

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS 26 AppKit draws large `draw(_:)`-backed view layers (the
        // terminal) through QuartzCore's in-process Metal renderer by default.
        // That renderer's glyph path issues a draw call Metal API Validation
        // rejects, which aborts debug runs. Opting out keeps view drawing on
        // the CoreGraphics path. AppKit reads this once, on the first layer
        // display, and only honors a real Bool.
        UserDefaults.standard.register(defaults: ["NSViewCanUseGPUAcceleration": false])
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
            #if DEBUG
            let port = OwnedOperatorFixture.configuration == nil ? UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? CDPProxy.defaultPort : 0
            #else
            let port = UserDefaults.standard.object(forKey: "browserAgentPort") as? Int ?? CDPProxy.defaultPort
            #endif
            await CDPProxy.shared.start(port: port)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        OwnedOperatorFixture.didLaunch()
        #endif
        NotificationCoordinator.shared.start()
    }

    /// Closing the window is not quitting, which is what an app whose one
    /// scene is a `Window` does unless told otherwise. The app stays up
    /// without it — the browsers keep running in their holder window — and
    /// a click on the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
    @FocusedValue(\.closeCommand) private var closeCommand

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Close Window") {
                // What the Close it replaces sent, to the same responders.
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .disabled(closeCommand == nil)
            Button(closeCommand?.target.closesTab == true ? "Close Tab" : "Close Pane") {
                closeCommand?.requests.wrappedValue += 1
            }
            .keyboardShortcut("w")
            .disabled(closeCommand?.target.item == nil)
        }
    }
}

/// The File menu's New Tab… (⌘N), which brings up the window's new tab
/// launcher — what the plus over the sidebar does — and New Tab in Current
/// Workspace… (⌘T), which brings it up with the machine and the workspace
/// of the selected pane or tab already picked. They take the place of New
/// Window, and its ⌘N: the app has the one window.
///
/// After them, Add herdr Machine…, which brings up the panel that adds one
/// to the active machine's herdr — greyed out, with why, unless that is This
/// Mac's — and — while a pane or tab on a herdr machine is selected — Remove
/// herdr Machine “…”…, which asks about removing that one. No shortcuts:
/// they are rarely wanted.
private struct NewTabCommands: Commands {
    @FocusedValue(\.launcherStart) private var launcherStart
    @FocusedValue(\.herdrMachineCommand) private var herdrMachineCommand

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab…") {
                show(.blank)
            }
            .keyboardShortcut("n")
            .disabled(launcherStart == nil)
            Button("New Tab in Current Workspace…") {
                show(.currentWorkspace)
            }
            .keyboardShortcut("t")
            .disabled(launcherStart == nil)
            Divider()
            AddHerdrMachineMenuItem(unavailableReason: herdrMachineCommand?.addUnavailableReason,
                                    isEnabled: herdrMachineCommand?.canAdd == true) {
                herdrMachineCommand?.add()
            }
            if let machine = herdrMachineCommand?.selectedMachine {
                Button("Remove herdr Machine \u{201C}\(machine.label)\u{201D}…") {
                    herdrMachineCommand?.remove()
                }
                .disabled(herdrMachineCommand?.canRemove != true)
            }
        }
    }

    /// With the launcher already up there is nothing to do: what it has
    /// been told so far stays.
    private func show(_ start: LauncherStart) {
        guard let launcherStart, launcherStart.wrappedValue == nil else { return }
        launcherStart.wrappedValue = start
    }
}

private struct PaneSwitcherCommands: Commands {
    @FocusedValue(\.isShowingPaneSwitcher) private var isShowingPaneSwitcher
    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .newItem) {
            Button("Go to Agent or Pane…") { isShowingPaneSwitcher?.wrappedValue = true }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(isShowingPaneSwitcher == nil)
        }
    }
}

/// The app menu's Settings… item, in the place and with the ⌘, the menu
/// keeps for it. Settings is a sheet over the main window rather than a
/// window of its own (a `Settings` scene), so the item opens it over the
/// main window, and is unavailable while that is closed.
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
