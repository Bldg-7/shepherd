import SwiftUI
import AppKit

/// The app has ONE main Window, with an explicit command owner. Native NSView
/// first responders must not leave hc menu actions stuck at an initial nil
/// FocusedValue. The small menu Views observe this owner (Commands bodies alone
/// do not observe arbitrary Observable changes; see CheckForUpdatesButton).
@MainActor @Observable final class HcWindowCommandState {
    static let shared = HcWindowCommandState()
    private(set) var actions: HcWindowActions?
    private var owner: UUID?
    func claim(_ id: UUID, actions: HcWindowActions) { owner = id; self.actions = actions }
    func update(_ id: UUID, actions: HcWindowActions) { if owner == id { self.actions = actions } }
    func release(_ id: UUID) { if owner == id { owner = nil; actions = nil } }
}

struct HcNewTabMenuItems: View {
    let legacy: Binding<LauncherStart?>?
    let machine: HerdrMachineCommand?
    var body: some View {
        let actions = HcWindowCommandState.shared.actions
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
        if let actions = HcWindowCommandState.shared.actions { actions.launch() }
        else if let legacy, legacy.wrappedValue == nil { legacy.wrappedValue = start }
    }
}
struct HcCloseMenuItems: View {
    let legacy: CloseCommand?
    var body: some View {
        let actions = HcWindowCommandState.shared.actions
        Button("Close Window") { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
            .disabled(actions == nil && legacy == nil)
        Button(actions?.closeTitle ?? (legacy?.target.closesTab == true ? "Close Tab" : "Close Pane")) {
            if let actions { actions.close() } else { legacy?.requests.wrappedValue += 1 }
        }.keyboardShortcut("w").disabled(actions.map { !$0.canClose } ?? (legacy?.target.item == nil))
    }
}
struct HcSettingsMenuItem: View {
    let legacy: Binding<Bool>?
    var body: some View {
        let actions = HcWindowCommandState.shared.actions
        Button("Settings…") {
            if let actions { actions.settings() } else { legacy?.wrappedValue = true }
        }.keyboardShortcut(",").disabled(actions.map { !$0.canSettings } ?? (legacy == nil))
    }
}
struct HcPaneSwitcherMenuItem: View {
    let legacy: Binding<Bool>?
    var body: some View {
        let actions = HcWindowCommandState.shared.actions
        Button("Go to Agent or Pane…") {
            if let actions { actions.switcher() } else { legacy?.wrappedValue = true }
        }.keyboardShortcut("p", modifiers: .command).disabled(actions.map { !$0.canSwitch } ?? (legacy == nil))
    }
}
