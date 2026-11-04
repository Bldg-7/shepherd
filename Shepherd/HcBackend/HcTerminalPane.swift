import SwiftUI
import SwiftTerm
import AppKit

/// Renderer owns consumption: the DATA receipt is returned only AFTER SwiftTerm
/// consumes the bytes on the main actor. No legacy Ctrl+B escaping or CLI PTY.
@MainActor @Observable final class HcTerminalPaneModel {
    private(set) var message: String?
    private(set) var connected = false
    @ObservationIgnored private weak var terminal: TerminalView?
    @ObservationIgnored private var session: HcTerminalSession?
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var queuedBytes = 0
    @ObservationIgnored private var queuedActions = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var size = (80, 24)

    func bind(_ view: TerminalView) { terminal = view }
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
        if connected { enqueue { try await $0.resize(columns: cols, rows: rows) } }
    }
    func focus(_ focused: Bool) { if connected { enqueue { try await $0.focus(focused) } } }
    func stop() {
        generation = UUID(); connected = false
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

struct HcTerminalPane: View {
    let model: HcWorkspaceModel
    let pane: CoreWorkspaceDocument.Pane
    var machine: Machine? = nil
    var machineStore: MachineStore? = nil
    @State private var preview: FilePreviewRequest?
    @State private var previewModel = FilePreviewModel()
    @State private var expandedPreview = false
    @State private var operationError: String?
    @State private var drops: TerminalDropController?
    @State private var terminal = HcTerminalPaneModel()
    private var currentScope: Bool {
        guard let machine else { return true }
        guard let machineStore else { return false }
        return machineStore.activeMachineID == machine.id && machineStore.isCurrentConnection(machine)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pane.title ?? pane.terminal?.terminalID ?? "Unbound pane").font(.caption)
                Spacer()
                if pane.terminal != nil {
                    Menu {
                        Button("New shell to right") { split(.horizontal) }
                        Button("New shell below") { split(.vertical) }
                        Button("Close pane view (keep program running)") { perform { try await model.closePane(pane.id) } }
                    } label: { Image(systemName: "ellipsis") }
                    .disabled(!model.canEdit)
                    Button { try? model.zoom(pane: model.focus.zoomByTab[model.selectedTab?.id ?? UUID()] == pane.id ? nil : pane.id) }
                    label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                }
            }.padding(6)
            if pane.terminal == nil {
                ContentUnavailableView("Program not bound", systemImage: "terminal", description: Text("Check operation recovery before starting another program."))
            } else if pane.terminal?.coreID != model.coreID {
                ContentUnavailableView("Remote terminal", systemImage: "network", description: Text("Connect directly to its origin before attaching."))
            } else {
                HStack(spacing: 0) {
                if !expandedPreview {
                TerminalHostView(onCreate: { terminal.bind($0) }, onInput: { if currentScope { terminal.send($0) } },
                                 onResize: { if currentScope { terminal.resize($0, $1) } }, onFocusChange: { focused in
                    guard !focused || currentScope else { return }
                    terminal.focus(focused)
                    if focused { try? model.select(pane: pane.id) }
                }, focusesWhenShown: model.focus.paneByTab[model.selectedTab?.id ?? UUID()] == pane.id,
                    onOpenLink: { link, _ in open(link) },
                    onDropFiles: currentScope && terminal.connected && TerminalFileDropFeature.isEnabled && drops?.isUploading == false ? { drops?.drop($0) } : nil)
                .task(id: pane.terminal) {
                    drops?.cancel(); drops = makeDrops()
                    await terminal.start { try model.session(for: pane) }
                }
                .onDisappear { drops?.cancel(); terminal.stop() }
                }
                if let preview, let machineStore {
                    FilePreviewPanel(request: preview, model: previewModel, machineStore: machineStore,
                        onClose: { self.preview = nil; expandedPreview = false }, onFileLink: { self.preview = $0 })
                        .previewExpansion(isExpanded: expandedPreview, onToggle: { expandedPreview.toggle() })
                        .frame(minWidth: 300, idealWidth: 420, maxWidth: expandedPreview ? .infinity : 480)
                }
                }
                if let drops { TerminalDropBanner(controller: drops) }
                if let message = terminal.message { Text(message).font(.caption).foregroundStyle(.secondary).padding(6) }
            }
        }
        .onChange(of: pane.terminal) { preview = nil; expandedPreview = false; drops?.cancel() }
        .alert("Terminal operation", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) { Button("OK") { operationError = nil } } message: { Text(operationError ?? "") }
        .overlay { Rectangle().stroke(model.focus.paneByTab[model.selectedTab?.id ?? UUID()] == pane.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1) }
    }
    private func makeDrops() -> TerminalDropController {
                    let controller = TerminalDropController(isEnabled: { currentScope && TerminalFileDropFeature.isEnabled }, destination: {
                        guard let machine, let machineStore else { throw TerminalDropError.unusableTarget }
                        let current = try machineStore.currentMachine(matching: machine)
                        guard model.state == .connected, pane.terminal?.coreID == model.coreID else { throw TerminalDropError.unusableTarget }
                        if current.isLocal { return .thisMac }
                        #if canImport(Citadel)
                        return .elsewhere {
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
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { operationError = "Operation unconfirmed. Review the saved outcome before retrying; no program was automatically rerun or terminated." } }
    }
    private func split(_ axis: CoreWorkspaceDocument.Axis) {
        let cwd = model.terminals.first { $0.address == pane.terminal?.terminalID }?.cwd
        perform { try await model.launchSplit(paneID: pane.id, axis: axis, argv: [], cwd: cwd) }
    }
    private func open(_ link: String) {
        guard let machine, let machineStore, machineStore.isCurrentConnection(machine),
              pane.terminal?.coreID == model.coreID, model.document?.pane(pane.id)?.terminal == pane.terminal,
              let record = model.terminals.first(where: { $0.address == pane.terminal?.terminalID }),
              let route = TerminalLinkRoute(link: link, directory: record.cwd, hostname: machine.hostname,
                additionalHosts: machine.isLocal ? FilePreviewLink.localHostAliases : [], opensPages: machine.isLocal) else { return }
        switch route {
        case .file(let raw):
            preview = FilePreviewRequest(machine: machine, hcPaneID: pane.id, terminalID: record.address, directory: record.cwd, link: raw)
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
