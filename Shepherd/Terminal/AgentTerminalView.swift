import SwiftUI

/// The detail column for one selected pane: its terminal, under its title.
struct AgentTerminalView: View {
    let machine: Machine
    let agent: AgentSummary
    let machineStore: MachineStore
    var onOpenFile: ((FilePreviewRequest) -> Void)? = nil

    var body: some View {
        PaneTerminalView(machine: machine, pane: agent, machineStore: machineStore, onOpenFile: onOpenFile)
            .navigationTitle(agent.title)
    }
}

/// One pane's live terminal: attached while the view is on screen, with
/// the attach's progress and failures shown over it. Used on its own for a
/// selected pane, and once per pane for a selected tab.
struct PaneTerminalView: View {
    @State private var viewModel: AgentTerminalViewModel
    /// The id of the attach task below; the Retry button bumps it, which
    /// makes SwiftUI run that task again. A retry is deliberately not a
    /// `Task` of the button's own: the view model relies on whoever calls
    /// `start()` being cancelled when the view goes away — that is what
    /// stops a start that hasn't run yet, or is still connecting, from
    /// taking the pane over for a view that is no longer there. SwiftUI
    /// cancels a view's task; nothing would cancel the button's.
    @State private var attempt = 0
    private let focusesWhenShown: Bool
    private let onFocusChange: ((Bool) -> Void)?
    private let onOpenLink: (String) -> Void

    /// `focusesWhenShown` and `onFocusChange` are `TerminalHostView`'s.
    init(
        machine: Machine,
        pane: AgentSummary,
        machineStore: MachineStore,
        focusesWhenShown: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil,
        onOpenFile: ((FilePreviewRequest) -> Void)? = nil
    ) {
        self.focusesWhenShown = focusesWhenShown
        self.onFocusChange = onFocusChange
        self.onOpenLink = { link in
            guard machineStore.isCurrentConnection(machine) else { return }
            let raw = link.lowercased().hasPrefix("file:") ? link : link.trimmingCharacters(in: .whitespaces)
            do {
                _ = try FilePreviewLink.resolve(raw, directory: pane.workingDirectory, hostname: machine.hostname,
                    additionalHosts: machine.isLocal ? FilePreviewLink.localHostAliases : [])
            }
            catch FilePreviewError.unsupportedLink { return }
            catch { /* Show file-path errors in the preview, without reading. */ }
            onOpenFile?(FilePreviewRequest(machine: machine, pane: pane, link: raw))
        }

        let terminalID = pane.terminalID
        let herdrMachine = pane.herdrMachine

        _viewModel = State(wrappedValue: AgentTerminalViewModel(makeSession: {
            let current = try machineStore.currentMachine(matching: machine)
            #if os(macOS)
            if current.isLocal {
                return LocalTerminalSession(terminalID: terminalID, on: herdrMachine)
            }
            #endif
            #if canImport(Citadel)
            // Looked up here, not in `init`: a view's `init` runs every time
            // its parent's body does, and all but the first of those runs
            // build a view model that `@State` throws away. Here the
            // Keychain is only read when a session is about to be started.
            if let secret = try machineStore.secret(for: current) {
                return TerminalSession(
                    host: current.hostname,
                    port: current.port,
                    username: current.username,
                    credential: HostCredential(authMethod: current.authMethod, secretData: secret),
                    sessionName: current.sessionName,
                    pinnedFingerprint: current.pinnedHostKeyFingerprint,
                    terminalID: terminalID,
                    on: herdrMachine
                )
            }
            throw MachineStore.EditError.missingCredential
            #else
            // The stub is only for builds without the SSH implementation.
            return StubTerminalSession()
            #endif
        }))
    }

    var body: some View {
        TerminalHostView(
            onCreate: { view in viewModel.attach(terminalView: view) },
            onInput: { data in viewModel.send(data) },
            onResize: { columns, rows in viewModel.resize(columns: columns, rows: rows) },
            onFocusChange: onFocusChange,
            focusesWhenShown: focusesWhenShown,
            onOpenLink: onOpenLink
        )
        .overlay {
            Group {
                switch viewModel.connectionState {
                case .connecting:
                    ProgressView("Connecting…")
                case .connected:
                    EmptyView()
                case .failed(let message):
                    // Selecting the same pane again doesn't make a new view
                    // (see `ContentView.TerminalIdentity`), so without a
                    // button here the only way to try again would be to go
                    // to another pane or machine and come back.
                    ContentUnavailableView {
                        Label("Connection Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { attempt += 1 }
                    }
                }
            }
            // What these sit on is the terminal, and the terminal is black
            // whatever the system appearance: in the ambient scheme a light
            // appearance would put black and dark grey labels on it.
            .environment(\.colorScheme, .dark)
        }
        .task(id: attempt) { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}

#Preview {
    NavigationStack {
        AgentTerminalView(
            machine: Machine(displayName: "Preview Machine", hostname: "localhost", username: "snark"),
            agent: AgentSummary.preview,
            machineStore: MachineStore()
        )
    }
}
