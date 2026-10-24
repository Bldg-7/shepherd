import SwiftUI

extension View {
    /// Native List selection alone does not fire again for the selected row.
    /// Recognize a completed primary click without replacing List selection,
    /// context menus or row dragging. The terminal applies the focus request
    /// on the next main-loop turn, after AppKit finishes handling the click.
    func onBoardRowActivation(perform: @escaping () -> Void) -> some View {
        #if os(macOS)
        contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { perform() })
        #else
        self
        #endif
    }
}
