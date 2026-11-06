import Foundation
import Darwin

@main @MainActor private struct HcWorkspacePresentationTests {
    static func main() {
        var n = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); n += 1 }
        let state = HcWorkspacePresentation(), epoch = UUID(), other = UUID(), tab = UUID(), a = UUID(), b = UUID()
        let first = HcSelectionStamp(tab: tab, pane: a), second = HcSelectionStamp(tab: tab, pane: b)
        check(!state.hasSelection && state.keyboardRequest == nil, "no unscoped selection")
        state.scopeChanged(epoch, focus: first)
        check(state.hasSelection && state.epoch == epoch, "restore selection in actual UI scope")
        state.clearSelection(focus: first)
        state.followFocus(first)
        check(!state.hasSelection, "mode change stays unselected despite unchanged model focus")
        state.select(first, requestKeyboard: false)
        check(state.hasSelection && state.keyboardRequest == nil, "list keyboard navigation does not steal focus")
        state.select(first, requestKeyboard: true)
        let token = state.keyboardRequest?.token
        check(state.keyboardRequest?.pane == a && state.keyboardRequest?.epoch == epoch, "explicit row activation requests exact scoped pane")
        state.select(first, requestKeyboard: true)
        check(state.keyboardRequest?.token != token, "clicking the same row requests keyboard again")
        state.previewCoversTerminal = true
        state.select(second, requestKeyboard: true)
        check(!state.previewCoversTerminal && state.keyboardRequest?.pane == b, "activation reveals the terminal")
        state.clearSelection(focus: second)
        state.followFocus(second)
        check(!state.hasSelection, "close result cannot immediately resurrect reconciled fallback selection")
        state.followFocus(first)
        check(state.hasSelection, "a genuinely different launch/selection can become visible")
        state.scopeChanged(other, focus: nil)
        check(!state.hasSelection && state.keyboardRequest == nil && !state.previewCoversTerminal, "scope change drops old UI/focus intent")
        state.select(first, requestKeyboard: true)
        check(state.keyboardRequest?.epoch == other, "new intent is stamped with current scope, not an old epoch")
        state.scopeChanged(nil, focus: nil)
        state.select(first, requestKeyboard: true)
        check(!state.hasSelection && state.keyboardRequest == nil, "retired scope cannot activate")
        func viewed(_ grouped: Bool, selected: Bool = true, key: Bool = true, covered: Bool = false, zoom: UUID? = nil) -> Set<UUID> {
            HcWorkspacePresentation.viewedPanes(panes: [a,b], focused: a, zoom: zoom, grouped: grouped,
                selected: selected, windowIsKey: key, covered: covered)
        }
        check(viewed(false) == [a], "pane mode does not mark a hidden sibling viewed")
        check(viewed(true) == [a,b], "tab mode sees its displayed panes")
        check(viewed(true,zoom:b) == [b], "zoom sees only its displayed pane")
        check(viewed(true,selected:false).isEmpty, "no UI selection is not viewed")
        check(viewed(true,key:false).isEmpty, "background window is not viewed")
        check(viewed(true,covered:true).isEmpty, "covered surface is not viewed when caller applies cover policy")
        check(viewed(true,zoom:UUID()).isEmpty, "unknown zoom does not broaden viewed scope")
        print("PASS workspace presentation rules: \(n) checks; not physical fullscreen/UI approval")
    }
}
