import Foundation
import Observation

/// Window-only preview state. Closing retains the request, not its old read.
@MainActor @Observable final class HcPanePresentation {
    private(set) var preview: FilePreviewRequest?
    private(set) var source: CoreWorkspaceDocument.Pane?
    private(set) var previewModel = FilePreviewModel()
    private(set) var isShown = false
    let historyIsRetained: Bool
    var expanded = false
    init(historyIsRetained: Bool = true) { self.historyIsRetained = historyIsRetained }
    func open(_ request: FilePreviewRequest, from pane: CoreWorkspaceDocument.Pane) {
        guard request.paneID == pane.id.uuidString, request.terminalID == pane.terminal?.terminalID else { return }
        preview = request; source = pane; previewModel = FilePreviewModel(); isShown = true; expanded = false
    }
    func follow(_ request: FilePreviewRequest) {
        guard let source else { return }
        let wasExpanded = expanded
        open(request,from:source)
        expanded = wasExpanded
    }
    func hide() {
        guard preview != nil else { return }
        isShown = false; expanded = false; previewModel = FilePreviewModel()
    }
    func show() { guard preview != nil else { return }; isShown = true; expanded = false }
    func invalidate() { preview = nil; source = nil; isShown = false; expanded = false; previewModel = FilePreviewModel() }
    func validate(members: [CoreWorkspaceDocument.Pane]) {
        guard let source else { return }
        if !members.contains(where:{ $0.id == source.id && $0.terminal == source.terminal }) { invalidate() }
    }
}

/// Typed pane/tab identities, not fabricated legacy IDs or native authority.
nonisolated enum HcPreviewSelection: Hashable { case pane(UUID), tab(UUID) }
@MainActor final class HcPanePresentationStore {
    private struct Key: Hashable { let epoch: UUID; let item: HcPreviewSelection }
    private var entries: [Key:HcPanePresentation] = [:]
    private var transient: (key: Key, value: HcPanePresentation)?
    private let limit: Int
    private var scopeEpoch: UUID?
    init(limit: Int = 128) { self.limit = max(0,limit) }
    func entry(epoch: UUID?, pane: CoreWorkspaceDocument.Pane, tabID: UUID? = nil) -> HcPanePresentation {
        guard let epoch else { return HcPanePresentation(historyIsRetained:false) }
        if scopeEpoch != epoch { entries = [:]; transient = nil; scopeEpoch = epoch }
        let key = Key(epoch:epoch,item:tabID.map(HcPreviewSelection.tab) ?? .pane(pane.id))
        if let value = entries[key] { transient = nil; return value }
        if transient?.key == key, let value = transient?.value { return value }
        let value = HcPanePresentation(historyIsRetained:entries.count < limit)
        if entries.count < limit { entries[key] = value; transient = nil }
        else { transient = (key,value) } // Keep current render stable; never evict visited history silently.
        return value
    }
    func collapsePreviews(epoch: UUID?) {
        for (key,value) in entries where key.epoch == epoch { value.expanded = false }
        if transient?.key.epoch == epoch { transient?.value.expanded = false }
    }
    func revealTerminal(epoch: UUID?, pane: UUID, tabID: UUID? = nil) {
        let item = tabID.map(HcPreviewSelection.tab) ?? .pane(pane)
        for (key,value) in entries where key.epoch == epoch && key.item == item { value.expanded = false }
        if transient?.key.epoch == epoch && transient?.key.item == item { transient?.value.expanded = false }
    }
    func retain(epoch: UUID?, document: CoreWorkspaceDocument?, missingDocumentConfirmed: Bool = false) {
        guard let epoch else { entries = [:]; transient = nil; scopeEpoch = nil; return }
        scopeEpoch = epoch
        if missingDocumentConfirmed { entries = [:]; transient = nil; return }
        // A failed/unavailable read is not evidence that a node disappeared.
        guard let document else {
            entries = entries.filter { $0.key.epoch == epoch }
            if transient?.key.epoch != epoch { transient = nil }
            return
        }
        let panes = document.panes
        let tabs = document.workspaces.flatMap(\.tabs)
        func retain(_ key: Key, _ value: HcPanePresentation) -> Bool {
            guard key.epoch == epoch else { return false }
            let members: [CoreWorkspaceDocument.Pane]
            switch key.item {
            case .pane(let id): guard let pane = panes.first(where:{ $0.id == id }) else { return false }; members = [pane]
            case .tab(let id): guard let tab = tabs.first(where:{ $0.id == id }) else { return false }; members = tab.layout?.panes ?? []
            }
            value.validate(members:members)
            return true
        }
        entries = entries.filter { retain($0.key,$0.value) }
        if let slot = transient, !retain(slot.key,slot.value) { transient = nil }
    }
}
