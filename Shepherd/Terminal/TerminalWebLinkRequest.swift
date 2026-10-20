import Foundation

/// Human navigation is tied to the clicked connection/pane/terminal, not an
/// agent's browser grant and not whichever pane is focused at mouse-up.
/// `rawURL` is an `http(s)` link, or the `file:` URL of an HTML file on
/// this Mac (`TerminalPageLink`).
nonisolated struct TerminalWebLinkRequest {
    let machine: Machine
    let paneID: String
    let terminalID: String
    let herdrMachineID: String?
    let rawURL: String
    /// How the link was clicked, which decides where it opens.
    let click: TerminalLinkClick

    init(machine: Machine, pane: AgentSummary, url: String, click: TerminalLinkClick = .unknown) {
        self.machine = machine
        paneID = pane.paneID
        terminalID = pane.terminalID
        herdrMachineID = pane.herdrMachine?.id
        rawURL = url
        self.click = click
    }

    @MainActor func pane(in panes: [AgentSummary], on current: Machine) -> AgentSummary? {
        guard current.connectionIdentity == machine.connectionIdentity else { return nil }
        return panes.first { $0.paneID == paneID && $0.terminalID == terminalID && $0.herdrMachine?.id == herdrMachineID }
    }
}

extension TerminalPageLink {
    /// Whether HTML file links in `pane`, on `machine`, open as pages: only
    /// in a pane of this Mac's own herdr, not one on an SSH machine or a
    /// herdr machine.
    static func opensPages(in pane: AgentSummary, on machine: Machine) -> Bool {
        opensPages(machineIsLocal: machine.isLocal, onHerdrMachine: pane.herdrMachine != nil)
    }
}

extension TerminalLinkRoute {
    /// Where a link clicked in `pane`'s terminal goes, resolved against the
    /// pane's working directory and `machine`.
    init?(_ link: String, in pane: AgentSummary, on machine: Machine) {
        self.init(link: link, directory: pane.workingDirectory, hostname: machine.hostname,
                  additionalHosts: machine.isLocal ? FilePreviewLink.localHostAliases : [],
                  opensPages: TerminalPageLink.opensPages(in: pane, on: machine))
    }
}
