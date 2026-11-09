import SwiftUI

/// What the Mac app adds only while the machine its window shows is This
/// Mac (SHPHRD-110): an iPhone or iPad, which logs in to this Mac. While
/// another machine is shown it is greyed out, with why.
enum LocalOnlyAddition {
    case device

    /// Why this can't be added while `machine` is the one the window shows
    /// (`MachineStore.activeMachine`), or nil when it can: on This Mac only.
    func unavailableReason(on machine: Machine?) -> String? {
        guard machine?.isLocal != true else { return nil }
        switch self {
        case .device: return String(localized: "Connect to This Mac to add a device.")
        }
    }
}
