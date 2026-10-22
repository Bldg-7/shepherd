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
        /// A block of the Markdown rendering, by its `id`. `at` is the
        /// place in the block, from 0 at its top to 1 at its bottom, that
        /// is brought into view at the same place in the view: 0, the
        /// block's top at the view's top, for a block that fits.
        case block(Int, at: Double = 0)
        /// A 1-based line of the source view, and the place in it, as for
        /// a block.
        case line(Int, at: Double = 0)
    }
    let id = UUID()
    let target: Target
}

/// What a preview's find bar looks for, and which of what it finds it is
/// at. Kept with the preview (see `FilePreviewModel.find`), so it comes
/// back with its pane; each new read starts it over, and reading the file
/// again keeps it.
nonisolated struct PreviewFindState: Equatable, Sendable {
    /// Whether the find bar is shown. Its matches are marked only while it is.
    var isShown = false
    /// What is typed into it: looked for in the text shown, case ignored.
    var query = ""
    /// The match the bar is at, by its place among the matches of `query`
    /// in the view shown; nil while it is at none.
    var current: Int?
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
    /// link to a line; reading the file again keeps it.
    var showsSource = false
    /// Where the preview was scrolled to, to put it back there when it is
    /// shown again. Not observed: it is written on every scroll, and nothing
    /// on screen follows it.
    @ObservationIgnored var scrollOffset: CGPoint?
    /// First visible text row and the distance into it, not lazy-stack estimates.
    @ObservationIgnored var scrollAnchor: PreviewScrollAnchor?
    /// Whether a Markdown file shows its table of contents. Each new read
    /// starts with it shown; turned off, it stays off for this preview only,
    /// read again or not.
    var showsOutline = true
    /// The last place the preview was asked to scroll to (see `reveal`).
    private(set) var scrollRequest: PreviewScrollRequest?
    /// The blocks the Markdown rendering shows now, by `id`, in order, as
    /// its scroll view reports them.
    var visibleBlocks: [Int] = []
    /// The 1-based lines the source view shows now, in order, as its scroll
    /// view reports them.
    var visibleLines: [Int] = []
    /// The find bar: whether it is shown, what it looks for, and the match
    /// it is at.
    var find = PreviewFindState()
    /// The request whose read has ended, loaded or failed. A read that was
    /// cancelled hasn't, and is made again (see `loadIfNeeded`).
    @ObservationIgnored private(set) var finishedRequestID: UUID?
    /// Whether the file is being read again (see `reload`) while what was
    /// read before stays shown.
    private(set) var isReloading = false
    /// The request whose reload was cancelled when its pane was left, to be
    /// made again when the pane comes back (see `loadIfNeeded`).
    @ObservationIgnored private var cancelledReload: UUID?
    /// Whether a read since the last `load` has shown the file: a link to a
    /// line turns the source on only as the file is first shown.
    @ObservationIgnored private var hasShownFile = false
    private var generation = UUID()

    /// Whether the file is being read, first or again.
    var isReading: Bool {
        if case .loading = state { return true }
        return isReloading
    }

    /// Brings `target` to the top of the preview's scroll view: a block when
    /// the preview shows the Markdown rendering, a line when it shows the
    /// source. A target of the other view is left alone.
    func reveal(_ target: PreviewScrollRequest.Target) {
        scrollRequest = PreviewScrollRequest(target: target)
    }

    /// Reads the file unless this request's read has already ended: a
    /// preview that comes back with its pane shows what was read, without
    /// connecting to the machine again. A reload that was cancelled when the
    /// pane was left is made again. Reload and Retry read again with `reload`.
    func loadIfNeeded(_ request: FilePreviewRequest, store: MachineStore) async {
        if cancelledReload == request.id {
            await reload(request, store: store)
            return
        }
        guard finishedRequestID != request.id else { return }
        await load(request, store: store)
    }

    /// Reads the file anew: how it is looked at starts over.
    func load(_ request: FilePreviewRequest, store: MachineStore) async {
        let epoch = UUID()
        generation = epoch
        state = .loading; link = nil; isReloading = false
        finishedRequestID = nil; showsSource = false; scrollOffset = nil; scrollAnchor = nil
        showsOutline = true; scrollRequest = nil; visibleBlocks = []; visibleLines = []
        // What the find bar looks for starts over with each read.
        find = PreviewFindState()
        cancelledReload = nil; hasShownFile = false
        await read(request, store: store, epoch: epoch, again: false)
    }

    /// Reads the file again, as the header's Reload button, ⌘R and Retry
    /// do, keeping how it is looked at: source or rendering, where it is
    /// scrolled to, the line linked to, the table of contents and the find
    /// bar. What was read stays shown while it is read again; a preview that
    /// failed shows that it is reading. A read that fails shows why, and
    /// how the file was looked at comes back with the next that doesn't.
    func reload(_ request: FilePreviewRequest, store: MachineStore) async {
        let epoch = UUID()
        generation = epoch
        cancelledReload = nil
        if case .loaded = state { isReloading = true } else { state = .loading }
        await read(request, store: store, epoch: epoch, again: true)
    }

    /// Reads `request`'s file for the read `epoch`, a new one or one `again`.
    private func read(_ request: FilePreviewRequest, store: MachineStore, epoch: UUID, again: Bool) async {
        defer { if generation == epoch, isReloading { isReloading = false } }
        let reader = FilePreviewReader()
        do {
            try Task.checkCancellation()
            let machine = try store.currentMachine(matching: request.machine)
            guard !request.nestedMachine else { throw FilePreviewError.nestedMachine }
            let resolved = try FilePreviewLink.resolve(request.rawLink, directory: request.directory, hostname: machine.hostname,
                additionalHosts: machine.isLocal ? FilePreviewLink.localHostAliases : [])
            if link != resolved { link = resolved }
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
            show(try FilePreviewDocument(data: data, path: resolved.path))
            if !hasShownFile, resolved.line != nil { showsSource = true }
            hasShownFile = true
            finishedRequestID = request.id
        } catch {
            await reader.cancel()
            guard generation == epoch else { return }
            if Task.isCancelled {
                // Left with its pane: what was shown stays, and a reload is
                // made again when the pane comes back, as a new read is.
                if again { cancelledReload = request.id }
                return
            }
            state = .failed(error.localizedDescription)
            finishedRequestID = request.id
        }
    }

    /// Shows `document` in place of what was shown. The same file as shown
    /// is left as it is; another one keeps how the preview is looked at,
    /// and the find bar, counting its matches in it, is at none of them yet.
    private func show(_ document: FilePreviewDocument) {
        if case .loaded(let shown) = state, shown.content == document.content { return }
        state = .loaded(document)
        if find.current != nil { find.current = nil }
    }
}
