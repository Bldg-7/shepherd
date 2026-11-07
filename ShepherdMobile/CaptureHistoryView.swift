import SwiftUI
import ShepherdKit
import AgentProxyCore

/// Explicit archive navigation. A captured native session is selected by the
/// person from this account's read-only endpoint, never inferred from hc IDs.
struct CaptureHistoryView: View {
    let machine: Machine
    let store: MachineStore
    @State private var source: CaptureHistorySource
    @State private var headers: [ConversationHeader] = []
    @State private var epoch: String?
    @State private var message: String?
    @State private var loading = false
    @State private var generation = UUID()
    @Environment(\.scenePhase) private var scenePhase
    init(machine: Machine, store: MachineStore) {
        self.machine = machine; self.store = store
        _source = State(initialValue: CaptureHistorySource(machine: machine, store: store))
    }
    var body: some View {
        List {
            Section {
                Text("Read-only capture history. Selecting a record does not bind it to an hc terminal or send input.").font(.footnote)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if source.message != nil { Text("Capture connection cleanup could not be confirmed.").foregroundStyle(.secondary) }
                if !source.isCurrent { Text("Host settings changed. Reopen capture history.") }
                if loading { ProgressView() }
                Button("Retry") { Task { await reload() } }.disabled(loading || !source.isCurrent || source.cleanupFailed)
            }
            if source.isCurrent {
                ForEach(headers, id: \.id) { header in
                    NavigationLink {
                        if let epoch, let archive = ConversationArchiveSelection(header:header,epoch:epoch) {
                            CapturedHistoryDetail(machine:machine,store:store,header:header,archive:archive)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: header.agent)
                            Text(verbatim: header.nativeSession).font(.caption).lineLimit(1).truncationMode(.middle)
                            if let origin = header.origin {
                                Text(verbatim:"hc · " + origin.value).font(.caption).foregroundStyle(.secondary)
                            } else if let legacy = header.herdrSession {
                                Text(verbatim:legacy).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !loading && headers.isEmpty && message == nil { Text("No captured conversation yet.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Captured conversations")
        .refreshable { await reload() }
        .task(id: scenePhase) {
            if scenePhase == .active { await reload() }
            else { generation = UUID(); loading = false; await source.close() }
        }
        .onChange(of: source.isCurrent) { _, current in
            if !current { generation = UUID(); headers = []; epoch = nil; loading = false; Task { await source.close() } }
        }
        .onDisappear { generation = UUID(); loading = false; Task { await source.close() } }
    }
    private func reload() async {
        let token = UUID(); generation = token; loading = true; message = nil
        defer { if generation == token { loading = false } }
        guard source.isCurrent, scenePhase == .active, let transport = await source.prepare() else { return }
        do {
            let result = try await ConversationClient(transport: transport).list()
            guard token == generation, source.isCurrent, !Task.isCancelled else { await source.close(transport); return }
            epoch = result.epoch
            headers = result.conversations.sorted { $0.revision > $1.revision }
        } catch {
            if token == generation { headers = []; epoch = nil; message = String(localized: "Capture history unavailable. No service is started automatically.") }
        }
        await source.close(transport)
    }
}

private struct CapturedHistoryDetail: View {
    let header: ConversationHeader
    let archive: ConversationArchiveSelection
    @State private var source: CaptureHistorySource
    @State private var captured = CapturedConversationModel()
    @Environment(\.scenePhase) private var scenePhase
    init(machine: Machine, store: MachineStore, header: ConversationHeader, archive: ConversationArchiveSelection) {
        self.header = header; self.archive = archive
        _source = State(initialValue: CaptureHistorySource(machine: machine, store: store))
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("Read-only capture history. Selecting a record does not bind it to an hc terminal or send input.")
                .font(.footnote).foregroundStyle(.secondary).padding()
            if source.message != nil { Text("Capture connection cleanup could not be confirmed.").font(.footnote) }
            if !source.isCurrent { Text("Host settings changed. Reopen capture history.") }
            else if captured.hasConversation { CapturedConversationView(model: captured, blocked: false) }
            else {
                ContentUnavailableView {
                    Label("Captured conversations", systemImage: "text.bubble")
                } description: {
                    Text("Capture history unavailable. No service is started automatically.")
                } actions: {
                    Button("Retry") { captured.retry() }.disabled(source.cleanupFailed || source.transport == nil)
                }
            }
        }
        .navigationTitle(Text(verbatim: header.agent))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            captured.stop(); captured.pause()
            if scenePhase == .active, source.isCurrent, let transport = await source.prepare() {
                guard !Task.isCancelled, source.isCurrent else { await source.close(transport); return }
                captured.connect(transport:transport,archive:archive)
                captured.resume()
            } else { await source.close() }
        }
        .onChange(of: source.isCurrent) { _, current in
            if !current { captured.stop(); Task { await source.close() } }
        }
        .onDisappear { captured.stop(); Task { await source.close() } }
    }
}
