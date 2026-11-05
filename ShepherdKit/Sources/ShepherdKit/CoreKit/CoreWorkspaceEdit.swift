import Foundation

public nonisolated enum CoreWorkspaceEditFailure: Error, Equatable, Sendable { case targetMissing, referenceChanged }

/// Explicit layout edits. Never launches/kills terminals or changes device focus.
/// A failed edit leaves the original immutable document untouched. The store
/// separately requires the caller's exact baseline version; no automatic rebase.
public nonisolated enum CoreWorkspaceEdit: Sendable {
    case appendWorkspace(CoreWorkspaceDocument.Workspace)
    case renameWorkspace(UUID, String)
    case appendTab(workspace: UUID, tab: CoreWorkspaceDocument.Tab)
    case renameTab(UUID, String)
    case renamePane(UUID, String)
    case removeTab(UUID)
    case splitPane(UUID, axis: CoreWorkspaceDocument.Axis, ratio: Double, newPane: CoreWorkspaceDocument.Pane)
    case removePane(UUID)
    case bindPane(UUID, expected: CoreWorkspaceDocument.TerminalReference?, replacement: CoreWorkspaceDocument.TerminalReference?)

    public func applying(to document: CoreWorkspaceDocument) throws -> CoreWorkspaceDocument {
        typealias Doc = CoreWorkspaceDocument
        var found = false
        func pane(_ node: Doc.Layout) throws -> Doc.Layout? {
            switch node {
            case .leaf(let leaf):
                switch self {
                case .renamePane(let id, let title) where id == leaf.id:
                    found = true; return .leaf(.init(id: leaf.id, title: title.isEmpty ? nil : title, terminal: leaf.terminal))
                case .splitPane(let id, let axis, let ratio, let newPane) where id == leaf.id:
                    found = true; return .split(axis: axis, ratio: ratio, first: node, second: .leaf(newPane))
                case .removePane(let id) where id == leaf.id: found = true; return nil
                case .bindPane(let id, let expected, let replacement) where id == leaf.id:
                    guard leaf.terminal == expected else { throw CoreWorkspaceEditFailure.referenceChanged }
                    found = true; return .leaf(.init(id: leaf.id, title: leaf.title, terminal: replacement))
                default: return node
                }
            case .split(let axis, let ratio, let first, let second):
                let a = try pane(first), b = try pane(second)
                if let a, let b { return .split(axis: axis, ratio: ratio, first: a, second: b) }
                return a ?? b // Removing one child collapses its split, not its sibling.
            }
        }
        var workspaces: [Doc.Workspace] = []
        for workspace in document.workspaces {
            var name = workspace.name, tabs: [Doc.Tab] = []
            if case .renameWorkspace(let id, let renamed) = self, id == workspace.id { found = true; name = renamed }
            for tab in workspace.tabs {
                if case .removeTab(let id) = self, id == tab.id { found = true; continue }
                var tabName = tab.name
                if case .renameTab(let id, let renamed) = self, id == tab.id { found = true; tabName = renamed }
                let layout = try tab.layout.flatMap { try pane($0) }
                tabs.append(.init(id: tab.id, name: tabName, layout: layout))
            }
            if case .appendTab(let id, let tab) = self, id == workspace.id { found = true; tabs.append(tab) }
            workspaces.append(.init(id: workspace.id, name: name, cwd: workspace.cwd, tabs: tabs))
        }
        if case .appendWorkspace(let workspace) = self { found = true; workspaces.append(workspace) }
        guard found else { throw CoreWorkspaceEditFailure.targetMissing }
        return try Doc(workspaces: workspaces) // Reapply all size/ID/reference/layout bounds.
    }
}
