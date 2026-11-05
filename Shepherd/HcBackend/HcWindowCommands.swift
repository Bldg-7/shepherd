import SwiftUI
import AppKit

/// Command snapshots are passed from the observing Commands host. Actions
/// dispatch through the CURRENT owner, not a captured stale menu snapshot.
struct HcNewTabMenuItems: View {
    let actions: HcWindowActions?
    let legacy: Binding<LauncherStart?>?
    let machine: HerdrMachineCommand?
    var body: some View {
        Button("New Tab…") { show(.blank) }.keyboardShortcut("n")
            .disabled(actions.map { !$0.canLaunch } ?? (legacy == nil))
        Button("New Tab in Current Workspace…") { show(.currentWorkspace) }.keyboardShortcut("t")
            .disabled(actions.map { !$0.canLaunch } ?? (legacy == nil))
        if actions == nil {
            Divider()
            AddHerdrMachineMenuItem(unavailableReason: machine?.addUnavailableReason, isEnabled: machine?.canAdd == true) { machine?.add() }
            if let selected = machine?.selectedMachine {
                Button("Remove herdr Machine “\(selected.label)”…") { machine?.remove() }.disabled(machine?.canRemove != true)
            }
        }
    }
    private func show(_ start: LauncherStart) {
        if HcWindowCommandState.shared.actions != nil { HcWindowCommandState.shared.perform(.launch) }
        else if let legacy, legacy.wrappedValue == nil { legacy.wrappedValue = start }
    }
}
struct HcCloseMenuItems: View {
    let actions: HcWindowActions?
    let legacy: CloseCommand?
    var body: some View {
        Button("Close Window") { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
            .disabled(actions == nil && legacy == nil)
        Button(actions?.closeTitle ?? (legacy?.target.closesTab == true ? "Close Tab" : "Close Pane")) {
            if HcWindowCommandState.shared.actions != nil { HcWindowCommandState.shared.perform(.close) }
            else { legacy?.requests.wrappedValue += 1 }
        }.keyboardShortcut("w").disabled(actions.map { !$0.canClose } ?? (legacy?.target.item == nil))
    }
}
struct HcSettingsMenuItem: View {
    let actions: HcWindowActions?
    let legacy: Binding<Bool>?
    var body: some View {
        Button("Settings…") {
            if HcWindowCommandState.shared.actions != nil { HcWindowCommandState.shared.perform(.settings) }
            else { legacy?.wrappedValue = true }
        }.keyboardShortcut(",").disabled(actions.map { !$0.canSettings } ?? (legacy == nil))
    }
}
struct HcPaneSwitcherMenuItem: View {
    let actions: HcWindowActions?
    let legacy: Binding<Bool>?
    var body: some View {
        Button("Go to Agent or Pane…") {
            if HcWindowCommandState.shared.actions != nil { HcWindowCommandState.shared.perform(.switcher) }
            else { legacy?.wrappedValue = true }
        }.keyboardShortcut("p", modifiers: .command).disabled(actions.map { !$0.canSwitch } ?? (legacy == nil))
    }
}
