import SwiftUI
import SwiftTerm

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
    @State private var terminal = HcTerminalPaneModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pane.title ?? pane.terminal?.terminalID ?? "Unbound pane").font(.caption)
                Spacer()
                if pane.terminal != nil {
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
                TerminalHostView(onCreate: { terminal.bind($0) }, onInput: { terminal.send($0) },
                                 onResize: { terminal.resize($0, $1) }, onFocusChange: { focused in
                    terminal.focus(focused)
                    if focused { try? model.select(pane: pane.id) }
                }, focusesWhenShown: model.focus.paneByTab[model.selectedTab?.id ?? UUID()] == pane.id)
                .task {
                    await terminal.start { try model.session(for: pane) }
                }
                .onDisappear { terminal.stop() }
                if let message = terminal.message { Text(message).font(.caption).foregroundStyle(.secondary).padding(6) }
            }
        }
        .overlay { Rectangle().stroke(model.focus.paneByTab[model.selectedTab?.id ?? UUID()] == pane.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1) }
    }
}
