import Foundation

/// Shared renderer contract, independent of either terminal backend.
@MainActor protocol SelectionKeepingTerminal: AnyObject {
    func feedKeepingSelection(_ bytes: ArraySlice<UInt8>)
}
