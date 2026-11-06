import Foundation

/// A real app-owned workspace node ID, never a fabricated legacy ID or a hc
/// terminal selector. Pasting a reference is text only, not native authority.
nonisolated struct HcWorkspaceRowReference: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case pane, tab }
    let kind: Kind
    let id: UUID
    let coreID: String
    let version: UInt64
    let terminal: CoreWorkspaceDocument.TerminalReference?
    var text: String { id.uuidString }

    func pasteText(_ text: String, coreID: String, version: UInt64,
                   document: CoreWorkspaceDocument) -> String? {
        guard text == self.text, !coreID.isEmpty, coreID == self.coreID, version == self.version else { return nil }
        switch kind {
        case .pane:
            guard let pane = document.pane(id), pane.terminal == terminal,
                  terminal.map({ $0.coreID == coreID }) ?? true else { return nil }
        case .tab:
            guard terminal == nil, let tab = document.workspaces.flatMap(\.tabs).first(where: { $0.id == id }),
                  tab.layout?.panes.allSatisfy({ $0.terminal.map { $0.coreID == coreID } ?? true }) ?? true else { return nil }
        }
        return text + " " // One normal/bracketed paste; never a Return.
    }
}
