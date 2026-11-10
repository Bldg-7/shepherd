import SwiftUI

/// The original switcher surface supplied with typed hc pane/terminal references.
/// No legacy pane/session identity or transport is fabricated.
struct HcPaneSwitcher: View {
    let model: HcWorkspaceModel
    let onSelectTarget: (HcWorkspaceSwitcherTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        WorkspacePaneSwitcher(destinations: destinations, onSelect: { item in
            guard model.state == .connected else { return }
            switch item.id {
            case .pane(let id):
                guard model.document?.panes.contains(where: { $0.id == id && $0.terminal?.coreID == model.coreID }) == true else { return }
            case .terminal(let id):
                guard model.canEdit, unplaced.contains(where:{ $0.address == id }) else { return }
            }
            onSelectTarget(item.id)
        }, onClose: { dismiss() })
    }
    private var unplaced: [HcTerminalRecord] {
        HcWorkspaceSwitcherCandidates.unplaced(model.terminals,coreID:model.coreID ?? "",
            document:model.document,snapshotAvailable:model.workspace?.snapshot != nil)
    }
    private var destinations: [WorkspaceSwitcherItem<HcWorkspaceSwitcherTarget>] {
        let placed: [WorkspaceSwitcherItem<HcWorkspaceSwitcherTarget>] = (model.document?.workspaces ?? []).flatMap { workspace in
            workspace.tabs.flatMap { tab in
                (tab.layout?.panes ?? []).map { pane in
                    WorkspaceSwitcherItem(id: .pane(pane.id), title: pane.title ?? tab.name,
                        location: workspace.name + " · " + tab.name, searchTerms: [pane.terminal?.terminalID ?? ""],
                        hasAgent: false, isAvailable: model.state == .connected && pane.terminal?.coreID == model.coreID,
                        accessibilityID:"workspace.switcher.pane.\(pane.id)")
                }
            }
        }
        return placed + unplaced.map { terminal in
            WorkspaceSwitcherItem(id:.terminal(terminal.address),title:terminal.name ?? (terminal.title.isEmpty ? terminal.address : terminal.title),
                location:terminal.currentFolder ?? "",searchTerms:[terminal.address],hasAgent:false,isAvailable:model.canEdit,
                accessibilityID:"workspace.switcher.terminal.\(terminal.address)")
        }
    }
}
