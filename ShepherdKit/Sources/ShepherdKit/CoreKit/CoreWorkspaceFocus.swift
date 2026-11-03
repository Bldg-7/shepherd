import Foundation

extension CoreWorkspaceDocument.Layout {
    public nonisolated var panes: [CoreWorkspaceDocument.Pane] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }
}
extension CoreWorkspaceDocument {
    public nonisolated var panes: [Pane] { workspaces.flatMap { $0.tabs.flatMap { $0.layout?.panes ?? [] } } }
    public nonisolated func pane(_ id: UUID) -> Pane? { panes.first { $0.id == id } }
}

/// Owned by ONE device/window presentation, never by the shared document or
/// shared RPC store. Selection is not a core focus command, seen mark or lease.
public nonisolated struct CoreWorkspaceFocus: Equatable, Sendable {
    public private(set) var workspaceID: UUID?
    public private(set) var tabByWorkspace: [UUID: UUID] = [:]
    public private(set) var paneByTab: [UUID: UUID] = [:]
    public private(set) var zoomByTab: [UUID: UUID] = [:]
    public init() {}

    /// Nil snapshot means unavailable: retain local selections. A successful
    /// null document is different and clears obsolete selections.
    public mutating func reconcile(_ snapshot: CoreWorkspaceCAS.Snapshot?) {
        guard let snapshot else { return }
        reconcile(document: snapshot.document)
    }
    public mutating func reconcile(document: CoreWorkspaceDocument?) {
        guard let document else { self = Self(); return }
        let workspaceIDs = Set(document.workspaces.map(\.id))
        if workspaceID.map({ !workspaceIDs.contains($0) }) ?? true { workspaceID = document.workspaces.first?.id }
        tabByWorkspace = tabByWorkspace.filter { workspaceIDs.contains($0.key) }
        var validTabs = Set<UUID>()
        for workspace in document.workspaces {
            let tabs = Set(workspace.tabs.map(\.id))
            if tabByWorkspace[workspace.id].map({ !tabs.contains($0) }) ?? true { tabByWorkspace[workspace.id] = workspace.tabs.first?.id }
            for tab in workspace.tabs {
                validTabs.insert(tab.id)
                let panes = tab.layout?.panes ?? [], ids = Set(panes.map(\.id))
                if paneByTab[tab.id].map({ !ids.contains($0) }) ?? true { paneByTab[tab.id] = panes.first?.id }
                if let zoom = zoomByTab[tab.id], !ids.contains(zoom) || zoom != paneByTab[tab.id] { zoomByTab[tab.id] = nil }
            }
        }
        paneByTab = paneByTab.filter { validTabs.contains($0.key) }
        zoomByTab = zoomByTab.filter { validTabs.contains($0.key) }
    }
    public mutating func select(workspace id: UUID, in document: CoreWorkspaceDocument) throws {
        guard document.workspaces.contains(where: { $0.id == id }) else { throw CoreWorkspaceEditFailure.targetMissing }
        reconcile(document: document); workspaceID = id
    }
    public mutating func select(tab id: UUID, in document: CoreWorkspaceDocument) throws {
        guard let workspace = document.workspaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }) else { throw CoreWorkspaceEditFailure.targetMissing }
        reconcile(document: document); workspaceID = workspace.id; tabByWorkspace[workspace.id] = id
    }
    public mutating func select(pane id: UUID, in document: CoreWorkspaceDocument) throws {
        guard let tab = document.workspaces.flatMap(\.tabs).first(where: { $0.layout?.panes.contains(where: { $0.id == id }) == true }) else { throw CoreWorkspaceEditFailure.targetMissing }
        try select(tab: tab.id, in: document)
        paneByTab[tab.id] = id
        if zoomByTab[tab.id] != id { zoomByTab[tab.id] = nil }
    }
    public mutating func zoom(pane id: UUID?, in document: CoreWorkspaceDocument) throws {
        if let id {
            try select(pane: id, in: document)
            if let workspaceID, let tab = tabByWorkspace[workspaceID] { zoomByTab[tab] = id }
        } else if let workspaceID, let tab = tabByWorkspace[workspaceID] { zoomByTab[tab] = nil }
    }
    private struct Saved: Codable {
        let schema: Int
        let coreID: String
        let workspaceID: UUID?
        let tabs: [UUID: UUID]
        let panes: [UUID: UUID]
        let zoom: [UUID: UUID]
    }
    /// Caller selects its own device/window-local storage. No UserDefaults or
    /// shared doc writes here. Restore must be reconciled with a fresh document.
    public func encoded(coreID: String) throws -> Data {
        let data = try JSONEncoder().encode(Saved(schema: 1, coreID: coreID, workspaceID: workspaceID, tabs: tabByWorkspace, panes: paneByTab, zoom: zoomByTab))
        guard data.count <= 1 << 20 else { throw CoreWorkspaceFailure.limitExceeded }
        return data
    }
    public static func restore(_ data: Data, coreID: String) throws -> Self {
        guard data.count <= 1 << 20 else { throw CoreWorkspaceFailure.limitExceeded }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        guard saved.schema == 1, saved.coreID == coreID else { throw CoreWorkspaceFailure.invalidReference }
        guard [saved.tabs.count, saved.panes.count, saved.zoom.count].allSatisfy({ $0 <= CoreWorkspaceDocument.maximumItems }) else { throw CoreWorkspaceFailure.limitExceeded }
        var result = Self(); result.workspaceID = saved.workspaceID
        result.tabByWorkspace = saved.tabs; result.paneByTab = saved.panes; result.zoomByTab = saved.zoom
        return result
    }
}
