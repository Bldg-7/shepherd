import SwiftUI

/// The detail column for one selected pane: its terminal, under its title.
struct AgentTerminalView: View {
    let machine: Machine
    let agent: AgentSummary
    let machineStore: MachineStore
    var onOpenFile: ((FilePreviewRequest) -> Void)? = nil
    var onOpenWeb: ((TerminalWebLinkRequest) -> Void)? = nil
    /// The title to show in place of the pane's own: a new name typed into
    /// the window's title, until herdr reports it (see `TitleRenameCommit`).
    /// The window's title is the one set here: it is taken over the one
    /// `ContentView` sets around this column, and over a file preview's.
    var title: String? = nil

    var body: some View {
        TerminalPaneFrame(isFocused: false) {
            PaneTerminalView(machine: machine, pane: agent, machineStore: machineStore, onOpenFile: onOpenFile, onOpenWeb: onOpenWeb)
        }
        .navigationTitle(title ?? agent.title)
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
    @State private var dropController: TerminalDropController
    @AppStorage(TerminalFileDropFeature.preferenceKey) private var takesFileDrops = false
    /// Whether a row dragged from the sidebar over the terminal would be
    /// pasted into it (see `HerdrItemDrag`).
    @State private var takesItemDrag = false
    @Environment(\.terminalPaneFocus) private var paneFocus
    private let paneID: String
    /// The herdr server the pane is on: the connection, and its herdr
    /// machine or nil for the host's own herdr. A row dragged from the
    /// sidebar is pasted only from the same one.
    private let connection: Machine.ConnectionIdentity
    private let herdrMachineID: String?
    private let focusesWhenShown: Bool
    private let onFocusChange: ((Bool) -> Void)?
    private let onOpenLink: (String, TerminalLinkClick) -> Void

    /// `focusesWhenShown` and `onFocusChange` are `TerminalHostView`'s.
    init(
        machine: Machine,
        pane: AgentSummary,
        machineStore: MachineStore,
        focusesWhenShown: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil,
        onOpenFile: ((FilePreviewRequest) -> Void)? = nil,
        onOpenWeb: ((TerminalWebLinkRequest) -> Void)? = nil
    ) {
        self.paneID = pane.id
        self.connection = machine.connectionIdentity
        self.herdrMachineID = pane.herdrMachine?.id
        self.focusesWhenShown = focusesWhenShown
        self.onFocusChange = onFocusChange
        self.onOpenLink = { link, click in
            guard machineStore.isCurrentConnection(machine) else { return }
            // An HTML file on this Mac opens as a web link does, ⌘ and all;
            // other files in the preview (see `TerminalLinkRoute`).
            switch TerminalLinkRoute(link, in: pane, on: machine) {
            case .web(let url), .page(let url):
                onOpenWeb?(TerminalWebLinkRequest(machine: machine, pane: pane, url: url, click: click))
            case .file(let raw):
                onOpenFile?(FilePreviewRequest(machine: machine, pane: pane, link: raw))
            case nil:
                return
            }
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
                    on: herdrMachine,
                    // So that a drag selects text in a pane whose program
                    // doesn't take the mouse (see `HerdrExecutable.attachConfiguration`).
                    withoutMouseCapture: true
                )
            }
            throw MachineStore.EditError.missingCredential
            #else
            // The stub is only for builds without the SSH implementation.
            return StubTerminalSession()
            #endif
        }, takesEncodedPrefix: {
            // Only herdr 0.9.0 and later take a kitty or modifyOtherKeys
            // Ctrl+B as the prefix, so only they get one twice. The attach
            // to a pane of the host is the host's herdr. The attach to a
            // pane of a herdr machine runs on that machine, whose version
            // isn't known here, and only a host of 0.9.0 or later has herdr
            // machines. Until the host's herdr is known to be older, it is
            // taken to be 0.9.0 or later: that is the current herdr, and
            // herdr machines need it.
            !MachineMonitors.shared.monitor(for: machine, in: machineStore).herdrPredatesSavedMachines
        }))

        // Resolved at each drop, like the session at each attach: against
        // the machine as it is then, and only reading the Keychain once a
        // drop has an image to upload.
        _dropController = State(wrappedValue: TerminalDropController(isEnabled: { TerminalFileDropFeature.isEnabled }, destination: {
            let current = try machineStore.currentMachine(matching: machine)
            switch TerminalDropRoute(isLocal: current.isLocal, herdrMachine: herdrMachine) {
            case .thisMac:
                return .thisMac
            case .thisMacMachine(let target):
                #if os(macOS)
                return .elsewhere { LocalSSHDropUploader(machine: target) }
                #else
                throw TerminalDropError.unusableTarget
                #endif
            case .host, .hostMachine:
                #if canImport(Citadel)
                return .elsewhere {
                    // Nothing goes to a host whose key the terminal's own
                    // connect hasn't pinned (see `FilePreviewReader`).
                    guard let pin = current.pinnedHostKeyFingerprint else { throw TerminalDropError.needsHostKey }
                    guard let secret = try machineStore.secret(for: current) else { throw MachineStore.EditError.missingCredential }
                    return RemoteExecDropUploader(
                        host: current.hostname,
                        port: current.port,
                        username: current.username,
                        credential: HostCredential(authMethod: current.authMethod, secretData: secret),
                        pinnedFingerprint: pin,
                        on: herdrMachine
                    )
                }
                #else
                throw TerminalDropError.unusableTarget
                #endif
            }
        }))
    }

    var body: some View {
        TerminalHostView(
            onCreate: { view in
                viewModel.attach(terminalView: view)
                dropController.paste = { [weak view] text in
                    (view as? FocusReportingTerminalView)?.sendPaste(text)
                }
                if paneFocus?.paneID == paneID { viewModel.requestKeyboardFocus() }
            },
            onInput: { data in viewModel.send(data) },
            onResize: { columns, rows in viewModel.resize(columns: columns, rows: rows) },
            onFocusChange: onFocusChange,
            focusesWhenShown: focusesWhenShown,
            onOpenLink: onOpenLink,
            // Only into a live attach, and one drop at a time.
            onDropFiles: takesFileDrops && viewModel.connectionState == .connected && !dropController.isUploading
                ? { urls in dropController.drop(urls) } : nil,
            // A row from the sidebar, into any live attach, whatever the
            // File Drop setting: its ID is pasted here, nothing uploaded.
            textDrop: viewModel.connectionState == .connected
                ? HerdrItemDrag.terminalDrop(connection: connection, herdrMachineID: herdrMachineID) { takesItemDrag = $0 } : nil
        )
        .itemDropHighlight(takesItemDrag)
        .overlay(alignment: .bottom) {
            TerminalDropBanner(controller: dropController)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            Group {
                switch viewModel.connectionState {
                case .connecting:
                    ProgressView("Connecting…")
                case .connected:
                    EmptyView()
                case .failed(let message):
                    // Selecting the same pane again doesn't make a new view
                    // (see `TerminalIdentity`), so without a
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
        .onChange(of: paneFocus) { _, request in
            if request?.paneID == paneID { viewModel.requestKeyboardFocus() }
        }
        .task(id: attempt) { await viewModel.start() }
        .onDisappear {
            viewModel.stop()
            dropController.cancel()
        }
    }
}

/// The attach's output keeps the terminal's selection (see
/// `FocusReportingTerminalView.feedKeepingSelection`).
extension FocusReportingTerminalView: SelectionKeepingTerminal {}

#Preview {
    NavigationStack {
        AgentTerminalView(
            machine: Machine(displayName: "Preview Machine", hostname: "localhost", username: "example"),
            agent: AgentSummary.preview,
            machineStore: MachineStore()
        )
    }
}
