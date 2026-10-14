import Foundation
import Observation
import Synchronization

/// Where a pane is, as far as a dropped file's path goes: whether a path on
/// this Mac is any use to its program, and if not, how an upload gets there.
nonisolated enum TerminalDropRoute: Equatable {
    /// A pane of this Mac's own herdr: this Mac's paths are its paths.
    case thisMac
    /// A pane on one of this Mac's herdr machines, reached with this Mac's
    /// `ssh` (see `LocalSSHDropUploader`).
    case thisMacMachine(HerdrMachine)
    /// A pane of the host's own herdr (see `RemoteExecDropUploader`).
    case host
    /// A pane on one of the host's herdr machines, reached with the host's
    /// `ssh` (see `RemoteExecDropUploader`).
    case hostMachine(HerdrMachine)

    /// `isLocal` is the pane's `Machine`'s, `herdrMachine` the pane's own.
    init(isLocal: Bool, herdrMachine: HerdrMachine?) {
        switch (isLocal, herdrMachine) {
        case (true, nil): self = .thisMac
        case (true, let machine?): self = .thisMacMachine(machine)
        case (false, nil): self = .host
        case (false, let machine?): self = .hostMachine(machine)
        }
    }
}

/// What `TerminalDropController` does with a drop, from its pane's route.
enum TerminalDropDestination {
    case thisMac
    /// Somewhere uploads have to go. `connect` makes the uploader, and is
    /// only called for a drop with an image in it: it is where the Keychain
    /// is read and a pinned host key required.
    case elsewhere(connect: () throws -> any TerminalDropUploading)
}

/// One pane's file drops: pastes the paths of what is dropped on its
/// terminal, uploading images first to a pane on another machine, and
/// says in a banner what is going on and what couldn't be done.
///
/// An upload belongs to the pane's view: `cancel()` is called when it goes
/// away, and nothing is pasted for an upload it stopped. One drop is taken
/// at a time; the terminal doesn't take another while one is uploading.
@MainActor
@Observable
final class TerminalDropController {
    enum Activity: Equatable {
        case idle
        /// Uploading the `current`th of `total` images; `fraction` is of all
        /// their bytes.
        case uploading(current: Int, total: Int, fraction: Double)
        /// What the last drop couldn't do, a line each, until dismissed or
        /// the next drop.
        case finished([String])
    }

    private(set) var activity = Activity.idle
    var isUploading: Bool {
        if case .uploading = activity { return true }
        return false
    }

    /// Sends text to the pane's program as a paste; given once the pane's
    /// terminal view exists.
    @ObservationIgnored var paste: ((String) -> Void)?
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let destination: () throws -> TerminalDropDestination
    /// How long an upload may go without a byte moving before it is given
    /// up on: long enough for a slow link, short of forever.
    @ObservationIgnored private let stallLimit: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Counts every drop and `cancel()`; an upload that finds it changed
    /// while it was waiting has been superseded, and leaves everything be.
    @ObservationIgnored private var generation = 0

    /// `isEnabled` is read at each drop: turning the feature off stops new
    /// drops, not one already uploading. `destination` is resolved at each
    /// drop too, against the pane's machine as it is then.
    init(isEnabled: @escaping () -> Bool, destination: @escaping () throws -> TerminalDropDestination,
         stallLimit: Duration = .seconds(120)) {
        self.isEnabled = isEnabled
        self.destination = destination
        self.stallLimit = stallLimit
    }

    /// Takes what was dropped on the pane's terminal.
    func drop(_ urls: [URL]) {
        guard isEnabled(), !isUploading, !urls.isEmpty else { return }
        generation += 1
        activity = .idle
        do {
            switch try destination() {
            case .thisMac: pasteHere(urls)
            case .elsewhere(let connect): upload(urls, connect: connect)
            }
        } catch {
            activity = .finished([connectionFailureDescription(error)])
        }
    }

    /// Stops an upload, if there is one; nothing is pasted for it.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if isUploading { activity = .idle }
    }

    func dismiss() {
        if case .finished = activity { activity = .idle }
    }

    /// A pane on this Mac: every path as it is, whatever it is, as other
    /// terminals paste them — files of every kind and folders alike.
    private func pasteHere(_ urls: [URL]) {
        var paths: [String] = []
        var refused: [String] = []
        for url in urls where url.isFileURL {
            var path = url.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if let escaped = TerminalDropPaste.escaped(path) {
                paths.append(escaped)
            } else {
                refused.append(url.lastPathComponent)
            }
        }
        if !paths.isEmpty { paste?(TerminalDropPaste.pasteText(escaped: paths)) }
        if !refused.isEmpty {
            activity = .finished([String(localized: "Couldn't paste \(Self.list(refused)): the path has control characters in it.")])
        }
    }

    private func upload(_ urls: [URL], connect: () throws -> any TerminalDropUploading) {
        let plan = TerminalDropPaste.plan(urls)
        guard !plan.uploads.isEmpty else {
            activity = .finished([String(localized: "Only PNG, JPEG, GIF, and WebP images can be attached to panes on another machine.")])
            return
        }
        var notes: [String] = []
        if !plan.notImages.isEmpty {
            notes.append(String(localized: "Non-image items skipped (\(plan.notImages.count)): \(Self.list(plan.notImages))"))
        }
        if !plan.overLimit.isEmpty {
            notes.append(String(localized: "Over the limit of \(TerminalDropPaste.maximumFiles) images per drop, skipped (\(plan.overLimit.count)): \(Self.list(plan.overLimit))"))
        }
        let uploader: any TerminalDropUploading
        do {
            uploader = try connect()
        } catch {
            activity = .finished(notes + [Self.failure(plan.uploads.map(\.name), connectionFailureDescription(error))])
            return
        }
        let generation = generation
        activity = .uploading(current: 1, total: plan.uploads.count, fraction: 0)
        task = Task { await run(plan, with: uploader, notes: notes, generation: generation) }
    }

    private func run(_ plan: TerminalDropPaste.Plan, with uploader: any TerminalDropUploading, notes: [String], generation: Int) async {
        let batch = UUID().uuidString.lowercased()
        // Off the main actor: a file on a slow volume mustn't hold the
        // window up while it is opened.
        let opened = await Task.detached {
            plan.uploads.map { upload in Result { try TerminalDropFile.open(upload.url, remoteName: upload.remoteName) } }
        }.value
        let totalBytes = opened.reduce(Int64(0)) { $0 + ((try? $1.get())?.size ?? 0) }
        var paths: [String] = []
        var failures: [(name: String, reason: String)] = []
        var sentBefore: Int64 = 0
        /// Set by a failure that the rest of the drop's files would meet too.
        var failedForAll: String?
        for (index, (upload, result)) in zip(plan.uploads, opened).enumerated() {
            guard isCurrent(generation) else { break }
            let file: TerminalDropFile
            switch result {
            case .success(let opened): file = opened
            case .failure(let error):
                failures.append((upload.name, connectionFailureDescription(error)))
                continue
            }
            if let failedForAll {
                failures.append((file.name, failedForAll))
                continue
            }
            showProgress(current: index + 1, total: plan.uploads.count, sent: sentBefore, of: totalBytes, generation: generation)
            do {
                let path = try await send(file, batch: batch, with: uploader, sentBefore: sentBefore,
                                          current: index + 1, total: plan.uploads.count, totalBytes: totalBytes, generation: generation)
                if let escaped = TerminalDropPaste.escaped(path) {
                    paths.append(escaped)
                } else {
                    failures.append((file.name, connectionFailureDescription(TerminalDropError.unconfirmed)))
                }
            } catch {
                guard isCurrent(generation) else { break }
                let reason = connectionFailureDescription(error)
                failures.append((file.name, reason))
                if (error as? TerminalDropError)?.concernsOnlyThisFile != true { failedForAll = reason }
            }
            sentBefore += file.size
        }
        await uploader.close()
        guard isCurrent(generation) else { return }
        task = nil
        if !paths.isEmpty { paste?(TerminalDropPaste.pasteText(escaped: paths)) }
        var grouped: [(reason: String, names: [String])] = []
        for failure in failures {
            if let index = grouped.firstIndex(where: { $0.reason == failure.reason }) {
                grouped[index].names.append(failure.name)
            } else {
                grouped.append((failure.reason, [failure.name]))
            }
        }
        let lines = notes + grouped.map { Self.failure($0.names, $0.reason) }
        activity = lines.isEmpty ? .idle : .finished(lines)
    }

    /// One file, given up on after `stallLimit` without progress.
    private func send(
        _ file: TerminalDropFile, batch: String, with uploader: any TerminalDropUploading,
        sentBefore: Int64, current: Int, total: Int, totalBytes: Int64, generation: Int
    ) async throws -> String {
        let meter = TerminalDropMeter()
        let stallLimit = stallLimit
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await uploader.upload(file, batch: batch, progress: { meter.record($0) })
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    let reading = meter.reading
                    await self.showProgress(current: current, total: total, sent: sentBefore + reading.sent,
                                            of: totalBytes, generation: generation)
                    if reading.idle > stallLimit { throw TerminalDropError.stalled }
                }
            }
            defer { group.cancelAll() }
            do {
                guard let path = try await group.next() else { throw CancellationError() }
                return path
            } catch TerminalDropError.stalled {
                // Close before the group waits for an upload stuck in a
                // write, as `FilePreviewModel` does for a stuck read.
                await uploader.close()
                throw TerminalDropError.stalled
            }
        }
    }

    private func showProgress(current: Int, total: Int, sent: Int64, of totalBytes: Int64, generation: Int) {
        guard self.generation == generation, isUploading else { return }
        activity = .uploading(current: current, total: total,
                              fraction: totalBytes > 0 ? min(1, Double(sent) / Double(totalBytes)) : 0)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    private static func list(_ names: [String]) -> String {
        names.formatted(.list(type: .and))
    }

    private static func failure(_ names: [String], _ reason: String) -> String {
        String(localized: "Couldn't upload \(list(names)). \(reason)")
    }
}

/// How far one upload has got, and since when it hasn't moved: written from
/// wherever the upload runs, read by the controller's watch on it.
private nonisolated final class TerminalDropMeter: Sendable {
    private let state = Mutex((sent: Int64(0), at: ContinuousClock.now))

    func record(_ sent: Int64) {
        state.withLock { state in
            if sent != state.sent { state = (sent, ContinuousClock.now) }
        }
    }

    var reading: (sent: Int64, idle: Duration) {
        state.withLock { ($0.sent, ContinuousClock.now - $0.at) }
    }
}
