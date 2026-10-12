import Foundation

/// Human navigation is tied to the clicked connection/pane/terminal, not an
/// agent's browser grant and not whichever pane is focused at mouse-up.
nonisolated struct TerminalWebLinkRequest {
    let machine: Machine
    let paneID: String
    let terminalID: String
    let herdrMachineID: String?
    let rawURL: String

    init(machine: Machine, pane: AgentSummary, url: String) {
        self.machine = machine
        paneID = pane.paneID
        terminalID = pane.terminalID
        herdrMachineID = pane.herdrMachine?.id
        rawURL = url
    }

    @MainActor func pane(in panes: [AgentSummary], on current: Machine) -> AgentSummary? {
        guard current.connectionIdentity == machine.connectionIdentity else { return nil }
        return panes.first { $0.paneID == paneID && $0.terminalID == terminalID && $0.herdrMachine?.id == herdrMachineID }
    }
}
