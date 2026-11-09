import SwiftUI

/// What the Mac app adds only while the machine its window shows is This
/// Mac (SHPHRD-110): a herdr machine, to the herdr whose panes the window
/// shows, and an iPhone or iPad, which logs in to this Mac. While another
/// machine is shown they are greyed out, with why. A herdr machine's group on This Mac's board goes
/// through This Mac's herdr, so it counts as This Mac.
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
