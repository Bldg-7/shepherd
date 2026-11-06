import SwiftUI

/// The existing pane-switcher surface supplied with typed hc pane IDs.
/// No legacy pane/session identity or transport is fabricated.
struct HcPaneSwitcher: View {
    let model: HcWorkspaceModel
    let onSelectPane: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        WorkspacePaneSwitcher(destinations: destinations, onSelect: { item in
            guard model.state == .connected, model.document?.panes.contains(where: { $0.id == item.id }) == true else { return }
            onSelectPane(item.id)
        }, onClose: { dismiss() })
        .padding(16)
    }
    private var destinations: [WorkspaceSwitcherItem<UUID>] {
        (model.document?.workspaces ?? []).flatMap { workspace in
            workspace.tabs.flatMap { tab in
                (tab.layout?.panes ?? []).map { pane in
                    WorkspaceSwitcherItem(id: pane.id, title: pane.title ?? tab.name,
                        location: workspace.name + " · " + tab.name, searchTerms: [pane.terminal?.terminalID ?? ""],
                        hasAgent: false, isAvailable: model.state == .connected && pane.terminal?.coreID == model.coreID)
                }
            }
        }
    }
}
