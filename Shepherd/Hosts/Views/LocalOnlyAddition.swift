import SwiftUI

/// What the Mac app adds only while the machine its window shows is This
/// Mac (SHPHRD-110): a herdr machine, to the herdr whose panes the window
/// shows, and an iPhone or iPad, which logs in to this Mac; and "Show
/// Conversations on iPhone and iPad" (SHPHRD-105), the agent proxy for the
/// agents started on this Mac. While another machine is shown they are
/// greyed out, with why. A herdr machine's group on This Mac's board goes
/// through This Mac's herdr, so it counts as This Mac.
enum LocalOnlyAddition {
    case herdrMachine
    case device
    case agentProxy

    /// Why this can't be added while `machine` is the one the window shows
    /// (`MachineStore.activeMachine`), or nil when it can: on This Mac only.
    func unavailableReason(on machine: Machine?) -> String? {
        guard machine?.isLocal != true else { return nil }
        switch self {
        case .herdrMachine: return String(localized: "Connect to This Mac to add a herdr machine.")
        case .device: return String(localized: "Connect to This Mac to add a device.")
        case .agentProxy: return String(localized: "Connect to This Mac to change this setting.")
        }
    }
}

extension AddHerdrMachineOffer {
    /// The launcher's Add herdr Machine… row on `machine`: greyed out, with
    /// why, on a machine other than This Mac, and on This Mac while its herdr
    /// can't have one added (`herdrBlocker`).
    init(on machine: Machine?, herdrBlocker: String?) {
        self.init(unavailableReason: LocalOnlyAddition.herdrMachine.unavailableReason(on: machine) ?? herdrBlocker)
    }
}

/// Add herdr Machine… in a menu: the File menu's and the host group
/// header's. Greyed out while it can't be used; with an `unavailableReason`,
/// which is shown under it, always.
struct AddHerdrMachineMenuItem: View {
    let unavailableReason: String?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Add herdr Machine…")
            // A menu shows a second line of the label under the item.
            if let unavailableReason {
                Text(verbatim: unavailableReason)
            }
        }
        .disabled(!isEnabled || unavailableReason != nil)
    }
}
