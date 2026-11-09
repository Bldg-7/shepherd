import SwiftUI
import SwiftTerm
import AppKit

/// Renderer owns consumption: the DATA receipt is returned only AFTER SwiftTerm
/// consumes the bytes on the main actor. No legacy Ctrl+B escaping or CLI PTY.
@MainActor @Observable final class HcTerminalPaneModel {
    private(set) var message: String?
    private(set) var connected = false
    private(set) var hasKeyboardFocus = false
    @ObservationIgnored private weak var terminal: TerminalView?
    @ObservationIgnored private var session: HcTerminalSession?
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var queuedBytes = 0
    @ObservationIgnored private var queuedActions = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var size = (80, 24)
    @ObservationIgnored private var handledKeyboardToken: UUID?

    func bind(_ view: TerminalView) { terminal = view }
    @discardableResult func takeKeyboard(token: UUID) -> Bool {
        if handledKeyboardToken == token { return true }
        guard let terminal, let window = terminal.window, NSApp.isActive, window.isKeyWindow else { return false }
        guard window.makeFirstResponder(terminal) else { return false }
        handledKeyboardToken = token
        return true
    }
    func start(makeSession: () throws -> HcTerminalSession) async {
        guard !Task.isCancelled else { return }
        stop(); let token = generation
        await teardown?.value
        guard token == generation, !Task.isCancelled else { return }
        message = nil
        do {
            let session = try makeSession(); self.session = session
            let initialSize = size
            try await withTaskCancellationHandler {
                try await session.start(columns: initialSize.0, rows: initialSize.1)
                guard token == generation, !Task.isCancelled else { throw CancellationError() }
                if size != initialSize { try await session.resize(columns: size.0, rows: size.1) }
                connected = true
                while let packet = try await session.nextOutput() {
                    try Task.checkCancellation()
                    guard token == generation, let terminal else { throw CancellationError() }
                    let bytes = Array(packet.frame.payload)
                    if let keeping = terminal as? SelectionKeepingTerminal { keeping.feedKeepingSelection(bytes[...]) }
                    else { terminal.feed(byteArray: bytes[...]) }
                    #if DEBUG && os(macOS)
                    let screen = terminal.getTerminal()
                    let rendered = (0..<screen.rows).compactMap { row in
                        screen.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: screen.getCharacter)
                    }.joined(separator: "\n")
                    HcMigrationRenderProbe.shared.consumed(packet.frame.payload, rendered: rendered)
                    #endif
                    try await session.acknowledgeOutput(packet)
                }
                guard token == generation else { return }
                connected = false; message = "Terminal stream closed. Reconnect to refresh."
                try await session.stop()
            } onCancel: { Task { try? await session.stop() } }
        } catch {
            guard token == generation else { return }
            connected = false
            message = error is CancellationError ? nil : "Terminal connection failed. Reconnect to refresh."
            if let session { try? await session.stop() }
        }
    }
    /// Preserve order of user input, resize, focus and renderer replies. Fail
    /// closed on a stalled writer instead of making unbounded fire-and-forget tasks.
    private func enqueue(bytes: Int = 0, _ operation: @escaping @Sendable (HcTerminalSession) async throws -> Void) {
        guard let session else { return }
        guard queuedActions < 128, bytes <= (1 << 20) - queuedBytes else {
            stop(); message = "Terminal input queue is full. Reconnect to refresh."; return
        }
        let previous = writer, token = generation
        queuedActions += 1; queuedBytes += bytes
        writer = Task { [weak self] in
            await previous?.value
            guard let self, token == self.generation, !Task.isCancelled else { return }
            defer { if token == self.generation { self.queuedActions -= 1; self.queuedBytes -= bytes } }
            do { try await operation(session) }
            catch {
                guard token == self.generation else { return }
                self.stop(); self.message = "Terminal input failed. Reconnect to refresh."
            }
        }
    }
    func send(_ slice: ArraySlice<UInt8>) {
        let data = Data(slice)
        enqueue(bytes: data.count) { try await $0.write(data) } // No legacy prefix translation.
    }
    func paste(_ text: String) {
        guard connected else { return }
        (terminal as? FocusReportingTerminalView)?.sendPaste(text)
    }
    func resize(_ cols: Int, _ rows: Int) {
        guard (1...2048).contains(cols), (1...2048).contains(rows), cols * rows <= 262_144 else { return }
        size = (cols, rows)
        #if DEBUG && os(macOS)
        if HcMigrationConfiguration.requested { HcMigrationRenderProbe.shared.resized(columns: cols, rows: rows) }
        #endif
        if connected { enqueue { try await $0.resize(columns: cols, rows: rows) } }
    }
    @discardableResult func focus(_ focused: Bool) -> Bool {
        let actual: Bool
        if let terminal, let window = terminal.window {
            actual = NSApp.isActive && window.isKeyWindow && window.firstResponder === terminal
        } else { actual = false }
        guard focused == actual else { return false } // A queued old callback is not current keyboard ownership.
        hasKeyboardFocus = focused
        if connected { enqueue { try await $0.focus(focused) } }
        return true
    }
    func stop() {
        generation = UUID(); connected = false; hasKeyboardFocus = false
        writer?.cancel(); writer = nil; queuedBytes = 0; queuedActions = 0
        let old = session, previous = teardown; session = nil
        teardown = Task { await previous?.value; try? await old?.stop() }
    }
    isolated deinit {
        writer?.cancel()
        let session = session, teardown = teardown
        Task { await teardown?.value; try? await session?.stop() }
    }
}

extension EnvironmentValues {
    @Entry var hcPaneKeyboardRequest: HcPaneKeyboardRequest?
}

struct HcTerminalPane: View {
    let model: HcWorkspaceModel
    let pane: CoreWorkspaceDocument.Pane
    var machine: Machine? = nil
    var machineStore: MachineStore? = nil
    let keyboardIntent: HcWorkspacePresentation?
    let isCurrentScope: @MainActor () -> Bool
    @AppStorage(BoardDisplayPreferences.showsTabsKey) private var showsTabs = false
    @Environment(\.hcPaneKeyboardRequest) private var keyboardRequest
    private let suppliedPresentation: HcPanePresentation?
    @State private var standalonePresentation = HcPanePresentation()
    private var presentation: HcPanePresentation { suppliedPresentation ?? standalonePresentation }
    private var expandedPreview: Bool {
        get { presentation.expanded }
        nonmutating set { presentation.expanded = newValue }
    }
    init(model: HcWorkspaceModel, pane: CoreWorkspaceDocument.Pane, machine: Machine? = nil,
         machineStore: MachineStore? = nil, presentations: HcPanePresentationStore? = nil, previewTabID: UUID? = nil, keyboardIntent: HcWorkspacePresentation? = nil,
         isCurrentScope: @escaping @MainActor () -> Bool = { true }) {
        self.model = model; self.pane = pane; self.machine = machine; self.machineStore = machineStore; self.keyboardIntent = keyboardIntent
        self.isCurrentScope = isCurrentScope
        suppliedPresentation = presentations?.entry(epoch:model.workspace?.epoch,pane:pane,tabID:previewTabID)
    }
    @State private var drops: TerminalDropController?
    @State private var terminal = HcTerminalPaneModel()
    @State private var itemDropTargeted = false
    private var rowDrop: TerminalTextDrop? {
        guard currentScope, terminal.connected, model.state == .connected,
              let machine, let machineStore else { return nil }
        return HcWorkspaceItemDrag.terminalDrop(model:model,machine:machine,store:machineStore,targetIsCurrent:{
            currentScope && terminal.connected && model.document?.pane(pane.id)?.terminal == pane.terminal
        },onTargetChange:{ itemDropTargeted = $0 })
    }
    private var currentScope: Bool {
        guard isCurrentScope(), model.state == .connected else { return false }
        guard let machine else { return true }
        guard let machineStore else { return false }
        return machineStore.activeMachineID == machine.id && machineStore.isCurrentConnection(machine)
    }
    var body: some View {
        TerminalPaneFrame(isFocused: showsTabs && terminal.hasKeyboardFocus) {
            VStack(spacing: 0) {
                if pane.terminal == nil {
                    ContentUnavailableView("Program not bound", systemImage: "terminal", description: Text("Check operation recovery before starting another program."))
                } else if pane.terminal?.coreID != model.coreID {
                    ContentUnavailableView("Remote terminal", systemImage: "network", description: Text("Connect directly to its origin before attaching."))
                } else {
                    TerminalHostView(onCreate: { view in
                        terminal.bind(view)
                        #if DEBUG && os(macOS)
                        if currentScope { HcMigrationRenderProbe.shared.bind(view,paneModel:terminal,pane:pane.id,epoch:model.workspace?.epoch,reference:pane.terminal) }
                        #endif
                    }, onInput: { if currentScope { terminal.send($0) } },
                        onResize: { if currentScope { terminal.resize($0, $1) } }, onFocusChange: { focused in
                            guard (!focused || currentScope), terminal.focus(focused) else { return }
                            if focused { try? model.select(pane: pane.id) }
                        }, focusesWhenShown: model.focus.paneByTab[model.selectedTab?.id ?? UUID()] == pane.id,
                        keyboardFocusAllowed: { keyboardIntent?.keyboardSuppressed != true && keyboardIntent?.textFieldOwnsKeyboard != true },
                        onOpenLink: { link, _ in open(link) },
                        onDropFiles: currentScope && terminal.connected && TerminalFileDropFeature.isEnabled && drops?.isUploading == false ? { drops?.drop($0) } : nil,
                        textDrop: rowDrop)
                    .itemDropHighlight(itemDropTargeted)
                    .task(id: pane.terminal) {
                        drops?.cancel(); drops = makeDrops()
                        await terminal.start {
                            guard currentScope else { throw HcWorkspaceModel.Failure.stale }
                            return try model.session(for: pane)
                        }
                    }
                    .onDisappear { drops?.cancel(); terminal.stop() }
                    if let drops { TerminalDropBanner(controller: drops) }
                    if let message = terminal.message { Text(message).font(.caption).foregroundStyle(.secondary).padding(6) }
                }
            }
        }
        .onChange(of: pane.terminal) { drops?.cancel() }
        .task(id: keyboardRequest) {
            guard let request = keyboardRequest, request.pane == pane.id else { return }
            // UI presentation readiness only, never a terminal-output timeout.
            // Do not focus another window while a sheet is dismissing.
            let end = ContinuousClock.now.advanced(by: .seconds(1))
            while !Task.isCancelled, ContinuousClock.now < end {
                guard currentScope, request.epoch == model.workspace?.epoch, !expandedPreview,
                      keyboardIntent?.keyboardRequest?.token == request.token,
                      keyboardIntent?.inputGeneration == request.inputGeneration,
                      keyboardIntent?.keyboardSuppressed != true,
                      model.document?.pane(pane.id)?.terminal == pane.terminal else { return }
                if terminal.takeKeyboard(token: request.token) {
                    keyboardIntent?.acknowledgeKeyboard(request.token)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    private func makeDrops() -> TerminalDropController {
                    let controller = TerminalDropController(isEnabled: { currentScope && TerminalFileDropFeature.isEnabled }, destination: {
                        guard currentScope, let machine, let machineStore else { throw TerminalDropError.unusableTarget }
                        let current = try machineStore.currentMachine(matching: machine)
                        guard model.state == .connected, pane.terminal?.coreID == model.coreID else { throw TerminalDropError.unusableTarget }
                        if current.isLocal { return .thisMac }
                        #if canImport(Citadel)
                        return .elsewhere {
                            guard currentScope, machineStore.isCurrentConnection(current) else { throw TerminalDropError.unusableTarget }
                            guard let pin = current.pinnedHostKeyFingerprint else { throw TerminalDropError.needsHostKey }
                            guard let secret = try machineStore.secret(for: current) else { throw MachineStore.EditError.missingCredential }
                            return RemoteExecDropUploader(host: current.hostname, port: current.port, username: current.username,
                                credential: HostCredential(authMethod: current.authMethod, secretData: secret), pinnedFingerprint: pin, addressKind: current.addressKind)
                        }
                        #else
                        throw TerminalDropError.unusableTarget
                        #endif
                    })
                    controller.paste = { text in
                        guard currentScope, let machine, machineStore?.isCurrentConnection(machine) == true, terminal.connected else { return }
                        terminal.paste(text)
                    }
        return controller
    }
    private func open(_ link: String) {
        guard currentScope, let machine, let machineStore, machineStore.isCurrentConnection(machine),
              pane.terminal?.coreID == model.coreID, model.document?.pane(pane.id)?.terminal == pane.terminal,
              let record = model.terminals.first(where: { $0.address == pane.terminal?.terminalID }),
              let route = TerminalLinkRoute(link: link, directory: record.cwd, hostname: machine.hostname,
                additionalHosts: machine.isLocal ? FilePreviewLink.localHostAliases : [], opensPages: machine.isLocal) else { return }
        switch route {
        case .file(let raw):
            presentation.open(FilePreviewRequest(machine: machine, hcPaneID: pane.id, terminalID: record.address, directory: record.cwd, link: raw),from:pane)
        case .web(let raw), .page(let raw):
            // Browser feature is retired: human links use the default browser,
            // never a saved agent lease, in-app engine, or injected MCP server.
            guard let url = URL(string: raw) else { return }
            if case .page = route, let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.invalid")!) {
                NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(url) }
        }
    }
}
