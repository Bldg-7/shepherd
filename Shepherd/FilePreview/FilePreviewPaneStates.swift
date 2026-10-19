import Foundation
import Observation

/// What makes one terminal view a different one from another: a pane or
/// tab (`BoardItem.id`, qualified by its herdr machine) on one machine
/// connection. `AgentTerminalView` builds its session once, when the view is
/// created, so a view that outlived a change of pane or machine would stay
/// attached to the old pane while showing the new one's title. `ContentView`
/// ties the terminal view's identity to this value, which gives every
/// (machine, pane or tab) its own view and tears the previous one down along
/// with its sessions. What the window keeps for a pane or tab — the pane in a
/// tab the browser column follows, a file preview — is kept by it too.
nonisolated struct TerminalIdentity: Hashable, Sendable {
    let connection: Machine.ConnectionIdentity
    /// `BoardItem.id`: the pane or tab, qualified by its herdr machine.
    let itemID: String
}

extension FilePreviewRequest {
    /// Whether the request is for one of `panes`: the same pane, still
    /// running the same terminal, on the same herdr. A pane ID that now
    /// names another terminal is another pane.
    func belongs(to panes: [AgentSummary]) -> Bool {
        panes.contains { $0.paneID == paneID && $0.terminalID == terminalID && $0.herdrMachine?.id == herdrMachineID }
    }
}

/// The file previews of the panes and tabs selected in this window, one for
/// each (by `TerminalIdentity`): selecting another pane leaves a pane's
/// preview as it is, and selecting the pane again shows it as it was left —
/// open or closed, the file and what was read of it, source or rendering,
/// and where it was scrolled to. Whether it was expanded is not kept.
///
/// Window memory only, like the preview always was: nothing of it is saved
/// or shared with other windows, and it is gone when the app quits.
@MainActor @Observable final class FilePreviewPaneStates {
    struct Entry {
        let request: FilePreviewRequest
        /// What was read and how it is being looked at. A new one when the
        /// preview is closed, so that showing it again reads the file again,
        /// as it always did.
        fileprivate(set) var model: FilePreviewModel
        /// Whether the preview is shown, or closed and only kept so that the
        /// toolbar can show it again.
        fileprivate(set) var isShown: Bool
    }

    private var entries: [TerminalIdentity: Entry] = [:]

    /// How many previews are kept.
    var count: Int { entries.count }

    /// The preview kept for `item`, if it still belongs to one of `panes`,
    /// the panes the item has now.
    func entry(for item: TerminalIdentity, panes: [AgentSummary]) -> Entry? {
        guard let entry = entries[item], entry.request.belongs(to: panes) else { return nil }
        return entry
    }

    /// Whether a preview is kept for `item` that belongs to none of
    /// `panes`: its pane has left the tab, or its pane ID now names another
    /// terminal. It has nothing left to show and is to be forgotten.
    func isStale(_ item: TerminalIdentity, panes: [AgentSummary]) -> Bool {
        entries[item].map { !$0.request.belongs(to: panes) } ?? false
    }

    /// Shows `request`'s file for `item`, in place of whatever it had.
    func open(_ request: FilePreviewRequest, for item: TerminalIdentity) {
        entries[item] = Entry(request: request, model: FilePreviewModel(), isShown: true)
    }

    /// Shows the preview kept for `item` again.
    func show(_ item: TerminalIdentity) {
        guard entries[item]?.isShown == false else { return }
        entries[item]?.isShown = true
    }

    /// Closes the preview of `item`, keeping its file for the toolbar.
    func hide(_ item: TerminalIdentity) {
        guard let entry = entries[item], entry.isShown else { return }
        entries[item] = Entry(request: entry.request, model: FilePreviewModel(), isShown: false)
    }

    func forget(_ item: TerminalIdentity) {
        guard entries[item] != nil else { return }
        entries[item] = nil
    }

    /// Forgets the previews of the panes a machine's herdrs no longer list.
    /// `listed` is every pane of those of its herdrs that were read: one
    /// that couldn't be read says nothing about whether its panes are gone,
    /// and its previews are kept.
    func forgetPanes(on connection: Machine.ConnectionIdentity, notIn listed: [AgentSummary]) {
        let read = Set(listed.map { $0.herdrMachine?.id })
        let gone = entries.filter { item, entry in
            item.connection == connection && read.contains(entry.request.herdrMachineID) && !entry.request.belongs(to: listed)
        }
        for item in gone.keys { entries[item] = nil }
    }

    /// Forgets the previews on connections there are no longer: a Machine
    /// removed, or edited into another endpoint, credential or session.
    func forgetConnections(notIn connections: Set<Machine.ConnectionIdentity>) {
        let gone = entries.keys.filter { !connections.contains($0.connection) }
        for item in gone { entries[item] = nil }
    }
}
