import Foundation
import Observation

nonisolated enum HcBoardSearch {
    static func matches(_ query: String, fields: [String]) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            fields.contains { $0.localizedStandardContains(String(term)) }
        }
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
    var previewCoversTerminal = false
    var keyboardSuppressed = false
    private var suppressedFocus: HcSelectionStamp?

    func scopeChanged(_ epoch: UUID?, focus: HcSelectionStamp?) {
        guard self.epoch != epoch else { return }
        self.epoch = epoch; hasSelection = epoch != nil && focus != nil
        suppressedFocus = nil; keyboardRequest = nil; previewCoversTerminal = false
    }
    func clearSelection(focus: HcSelectionStamp?) {
        hasSelection = false; suppressedFocus = focus; keyboardRequest = nil; previewCoversTerminal = false
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
