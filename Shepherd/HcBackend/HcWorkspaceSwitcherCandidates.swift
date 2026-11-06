import Foundation

/// UI references, not native-session/browser permissions or synthetic legacy IDs.
nonisolated enum HcWorkspaceSwitcherTarget: Hashable, Sendable {
    case pane(UUID)
    case terminal(String)
}
nonisolated enum HcWorkspaceSwitcherCandidates {
    static func unplaced(_ records: [HcTerminalRecord], coreID: String,
                         document: CoreWorkspaceDocument?, snapshotAvailable: Bool) -> [HcTerminalRecord] {
        guard snapshotAvailable, !coreID.isEmpty, records.count <= 4096 else { return [] }
        let placed = Set((document?.panes ?? []).compactMap { pane -> String? in
            guard pane.terminal?.coreID == coreID else { return nil }
            return pane.terminal?.terminalID
        })
        let counts = records.reduce(into:[String:Int]()) { $0[$1.address,default:0] += 1 }
        return records.filter {
            CoreTerminalID.isCanonical($0.address) && $0.state == "live"
                && counts[$0.address] == 1 && !placed.contains($0.address)
        }
    }
}
