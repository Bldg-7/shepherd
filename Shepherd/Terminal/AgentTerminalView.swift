import SwiftUI

/// The detail column for one selected pane: its terminal, under its title.
struct AgentTerminalView: View {
    let machine: Machine
    let agent: AgentSummary
    let machineStore: MachineStore

    var body: some View {
        PaneTerminalView(machine: machine, pane: agent, machineStore: machineStore)
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

    /// `focusesWhenShown` and `onFocusChange` are `TerminalHostView`'s.
    init(
        machine: Machine,
        pane: AgentSummary,
        machineStore: MachineStore,
        focusesWhenShown: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self.focusesWhenShown = focusesWhenShown
        self.onFocusChange = onFocusChange

        let isLocal = machine.isLocal
        let authMethod = machine.authMethod
        let sessionName = machine.sessionName
        let pinnedFingerprint = machine.pinnedHostKeyFingerprint
        let hostname = machine.hostname
        let port = machine.port
        let username = machine.username
        let terminalID = pane.terminalID
        let herdrMachine = pane.herdrMachine

        _viewModel = State(wrappedValue: AgentTerminalViewModel(makeSession: {
            #if os(macOS)
            if isLocal {
                return LocalTerminalSession(terminalID: terminalID, on: herdrMachine)
            }
            #endif
            #if canImport(Citadel)
            // Looked up here, not in `init`: a view's `init` runs every time
            // its parent's body does, and all but the first of those runs
            // build a view model that `@State` throws away. Here the
            // Keychain is only read when a session is about to be started.
            if let secret = try? machineStore.secret(for: machine) {
                return TerminalSession(
                    host: hostname,
                    port: port,
                    username: username,
                    credential: HostCredential(authMethod: authMethod, secretData: secret),
                    sessionName: sessionName,
                    pinnedFingerprint: pinnedFingerprint,
                    terminalID: terminalID,
                    on: herdrMachine
                )
            }
            #endif
            // No Citadel yet, or no credential on file for this machine — fall
            // back to canned output so the UI flow stays testable either way.
            return StubTerminalSession()
        }))
    }

    var body: some View {
        TerminalHostView(
            onCreate: { view in viewModel.attach(terminalView: view) },
            onInput: { data in viewModel.send(data) },
            onResize: { columns, rows in viewModel.resize(columns: columns, rows: rows) },
            onFocusChange: onFocusChange,
            focusesWhenShown: focusesWhenShown
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
