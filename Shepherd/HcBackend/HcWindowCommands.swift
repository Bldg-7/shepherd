import SwiftUI
import AppKit

/// Command snapshots are passed from the observing Commands host. Actions
/// dispatch through the CURRENT owner, not a captured stale menu snapshot.
struct HcNewTabMenuItems: View {
    let actions: HcWindowActions?
    var body: some View {
        Button("New Tab…") { HcWindowCommandState.shared.perform(.launch) }.keyboardShortcut("n")
            .disabled(actions.map { !$0.canLaunch } ?? true)
        Button("New Tab in Current Workspace…") { HcWindowCommandState.shared.perform(.launchCurrentWorkspace) }.keyboardShortcut("t")
            .disabled(actions.map { !$0.canLaunch } ?? true)
    }
}
struct HcCloseMenuItems: View {
    let actions: HcWindowActions?
    var body: some View {
        Button("Close Window") { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
            .disabled(actions == nil)
        Button(actions?.closeTitle ?? "Close Pane") { HcWindowCommandState.shared.perform(.close) }
            .keyboardShortcut("w").disabled(actions.map { !$0.canClose } ?? true)
    }
}
struct HcSettingsMenuItem: View {
    let actions: HcWindowActions?
    var body: some View {
        Button("Settings…") { HcWindowCommandState.shared.perform(.settings) }
            .keyboardShortcut(",").disabled(actions.map { !$0.canSettings } ?? true)
    }
}
struct HcPaneSwitcherMenuItem: View {
    let actions: HcWindowActions?
    var body: some View {
        Button("Go to Agent or Pane…") { HcWindowCommandState.shared.perform(.switcher) }
            .keyboardShortcut("p", modifiers: .command).disabled(actions.map { !$0.canSwitch } ?? true)
    }
}
