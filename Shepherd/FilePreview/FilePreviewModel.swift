import Foundation
import Observation

struct FilePreviewRequest: Identifiable {
    let id = UUID()
    let machine: Machine
    let paneID: String
    let terminalID: String
    let directory: String?
    /// `HerdrMachine.id` of the herdr machine the pane is on, or nil for the
    /// host's own herdr: `paneID` alone means nothing outside one herdr.
    let herdrMachineID: String?
    let nestedMachine: Bool
    let rawLink: String

    init(machine: Machine, pane: AgentSummary, link: String) {
        self.machine = machine; paneID = pane.paneID; terminalID = pane.terminalID
        directory = pane.workingDirectory; herdrMachineID = pane.herdrMachine?.id
        nestedMachine = pane.herdrMachine != nil; rawLink = link
    }

    func following(_ link: String, directory: String) -> Self {
        Self(machine: machine, paneID: paneID, terminalID: terminalID, directory: directory,
             herdrMachineID: herdrMachineID, nestedMachine: nestedMachine, rawLink: link)
    }

    private init(machine: Machine, paneID: String, terminalID: String, directory: String?, herdrMachineID: String?, nestedMachine: Bool, rawLink: String) {
        self.machine = machine; self.paneID = paneID; self.terminalID = terminalID
        self.directory = directory; self.herdrMachineID = herdrMachineID
        self.nestedMachine = nestedMachine; self.rawLink = rawLink
    }
}

/// A place a preview is asked to bring to the top of its scroll view. Each
/// request is a new one, so asking for the same place again scrolls again.
nonisolated struct PreviewScrollRequest: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A block of the Markdown rendering, by its `id`.
        case block(Int)
        /// A 1-based line of the source view.
        case line(Int)
    }
    let id = UUID()
    let target: Target
}

/// One preview's file, read, and how it is being looked at. It is kept with
/// the pane or tab it was opened from (see `FilePreviewPaneStates`), so all
/// of this comes back when that pane is selected again.
@MainActor @Observable final class FilePreviewModel: Identifiable {
    enum State { case loading, loaded(FilePreviewDocument), failed(String) }
    /// One for each time a preview is opened or shown again: the panel that
    /// shows it is made anew for each.
    let id = UUID()
    private(set) var state = State.loading
    private(set) var link: FilePreviewLink?
    /// Whether a Markdown file shows its source rather than its rendering.
    /// Each new read starts with the rendering, or with the source for a
    /// link to a line.
    var showsSource = false
    /// Where the preview was scrolled to, to put it back there when it is
    /// shown again. Not observed: it is written on every scroll, and nothing
    /// on screen follows it.
    @ObservationIgnored var scrollOffset: CGPoint?
    /// Whether a Markdown file shows its table of contents. Each new read
    /// starts with it shown; turned off, it stays off for this preview only.
    var showsOutline = true
    /// The last place the preview was asked to scroll to (see `reveal`).
    private(set) var scrollRequest: PreviewScrollRequest?
    /// The blocks the Markdown rendering shows now, by `id`, in order, as
    /// its scroll view reports them.
    var visibleBlocks: [Int] = []
    /// The 1-based lines the source view shows now, in order, as its scroll
    /// view reports them.
    var visibleLines: [Int] = []
    /// The request whose read has ended, loaded or failed. A read that was
    /// cancelled hasn't, and is made again (see `loadIfNeeded`).
    @ObservationIgnored private(set) var finishedRequestID: UUID?
    private var generation = UUID()

    /// Brings `target` to the top of the preview's scroll view: a block when
    /// the preview shows the Markdown rendering, a line when it shows the
    /// source. A target of the other view is left alone.
    func reveal(_ target: PreviewScrollRequest.Target) {
        scrollRequest = PreviewScrollRequest(target: target)
    }

    /// Reads the file unless this request's read has already ended: a
    /// preview that comes back with its pane shows what was read, without
    /// connecting to the machine again. Retry reads again with `load`.
    func loadIfNeeded(_ request: FilePreviewRequest, store: MachineStore) async {
        guard finishedRequestID != request.id else { return }
        await load(request, store: store)
    }

    func load(_ request: FilePreviewRequest, store: MachineStore) async {
        let epoch = UUID()
        generation = epoch
        state = .loading; link = nil
        finishedRequestID = nil; showsSource = false; scrollOffset = nil
        showsOutline = true; scrollRequest = nil; visibleBlocks = []; visibleLines = []
        let reader = FilePreviewReader()
        do {
            try Task.checkCancellation()
            let machine = try store.currentMachine(matching: request.machine)
            guard !request.nestedMachine else { throw FilePreviewError.nestedMachine }
            let resolved = try FilePreviewLink.resolve(request.rawLink, directory: request.directory, hostname: machine.hostname,
                additionalHosts: machine.isLocal ? FilePreviewLink.localHostAliases : [])
            link = resolved
            // Local previews must not even look up a remote credential.
            // An unpinned endpoint is not a reason to prompt for a credential.
            if !machine.isLocal && machine.pinnedHostKeyFingerprint == nil { throw FilePreviewError.needsHostKey }
            let secret = machine.isLocal ? nil : try store.secret(for: machine)
            let data = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await reader.read(path: resolved.path, machine: machine, secret: secret) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15))
                        throw FilePreviewError.timedOut
                    }
                    defer { group.cancelAll() }
                    do {
                        guard let result = try await group.next() else { throw CancellationError() }
                        return result
                    } catch {
                        // Close before the group drains an uncooperative SSH
                        // read; preserve the timeout error instead of racing
                        // it with the read's connection-closed error.
                        await reader.cancel()
                        throw error
                    }
                }
            } onCancel: { Task { await reader.cancel() } }
            try Task.checkCancellation()
            _ = try store.currentMachine(matching: request.machine)
            guard generation == epoch else { return }
            state = .loaded(try FilePreviewDocument(data: data, path: resolved.path))
            if resolved.line != nil { showsSource = true }
            finishedRequestID = request.id
        } catch {
            await reader.cancel()
            guard generation == epoch, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            finishedRequestID = request.id
        }
    }
}
