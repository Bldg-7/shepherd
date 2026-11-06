import Foundation
import Observation

nonisolated enum HcBoardSearch {
    static func matches(_ query: String, fields: [String]) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            fields.contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

/// Caller baseline for a deferred layout confirmation, not a permission or a
/// lease on server state. The store still performs the exact-version CAS.
nonisolated struct HcWorkspaceMutationStamp: Equatable, Sendable {
    let epoch: UUID
    let coreID: String
    let version: UInt64
    func matches(epoch: UUID?, coreID: String?, version: UInt64?) -> Bool {
        !self.coreID.isEmpty && self.epoch == epoch && self.coreID == coreID && self.version == version
    }
}

/// Local presentation intent only. Never a core/native-session permission.
nonisolated struct HcSelectionStamp: Equatable, Sendable {
    let tab: UUID
    let pane: UUID?
}
nonisolated struct HcPaneKeyboardRequest: Equatable, Sendable {
    let epoch: UUID
    let pane: UUID
    let token = UUID()
}
@MainActor @Observable final class HcWorkspacePresentation {
    private(set) var epoch: UUID?
    private(set) var hasSelection = false
    private(set) var keyboardRequest: HcPaneKeyboardRequest?
    private(set) var selectionIntent = UUID()
    var previewCoversTerminal = false
    var keyboardSuppressed = false
    private var suppressedFocus: HcSelectionStamp?

    func scopeChanged(_ epoch: UUID?, focus: HcSelectionStamp?) {
        guard self.epoch != epoch else { return }
        selectionIntent = UUID()
        self.epoch = epoch; hasSelection = epoch != nil && focus != nil
        suppressedFocus = nil; keyboardRequest = nil; previewCoversTerminal = false
    }
    func clearSelection(focus: HcSelectionStamp?) {
        selectionIntent = UUID()
        hasSelection = false; suppressedFocus = focus; keyboardRequest = nil; previewCoversTerminal = false
    }
    func clearSelection(ifUnchanged intent: UUID, focus: HcSelectionStamp?) {
        guard selectionIntent == intent else { return }
        clearSelection(focus: focus)
    }
    func followFocus(_ focus: HcSelectionStamp?) {
        guard epoch != nil else { return }
        if focus == nil { hasSelection = false; keyboardRequest = nil }
        else if focus != suppressedFocus { hasSelection = true }
    }
    func acknowledgeKeyboard(_ token: UUID) {
        guard keyboardRequest?.token == token else { return }
        keyboardRequest = nil
    }
    func select(_ focus: HcSelectionStamp?, requestKeyboard: Bool) {
        guard let epoch, let focus else { return }
        selectionIntent = UUID()
        hasSelection = true; suppressedFocus = nil
        if requestKeyboard, let pane = focus.pane {
            previewCoversTerminal = false
            keyboardRequest = .init(epoch: epoch, pane: pane)
        }
    }
    /// Exactly the rendered panes, not every terminal stored in the tab.
    nonisolated static func viewedPanes(panes: [UUID], focused: UUID?, zoom: UUID?, grouped: Bool,
                                        selected: Bool, windowIsKey: Bool, covered: Bool) -> Set<UUID> {
        guard selected, windowIsKey, !covered else { return [] }
        if !grouped { return focused.flatMap { panes.contains($0) ? Set([$0]) : nil } ?? [] }
        if let zoom { return panes.contains(zoom) ? [zoom] : [] }
        return Set(panes)
    }
}
