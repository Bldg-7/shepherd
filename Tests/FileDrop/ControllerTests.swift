import Foundation
import Darwin

/// Stands in for an uploader: records what it is given, answers with the
/// path the receive script would print, or fails, waits or stalls as told.
nonisolated final class FakeUploader: TerminalDropUploading, @unchecked Sendable {
    enum Mode { case answer, wait, stall, slow }
    private let lock = NSLock()
    private var _uploads: [(name: String, remote: String, batch: String)] = []
    private var _closes = 0
    let failures: [String: TerminalDropError]
    let mode: Mode
    init(mode: Mode = .answer, failures: [String: TerminalDropError] = [:]) { self.mode = mode; self.failures = failures }
    var uploads: [(name: String, remote: String, batch: String)] { lock.withLock { _uploads } }
    var closes: Int { lock.withLock { _closes } }

    func upload(_ file: TerminalDropFile, batch: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        lock.withLock { _uploads.append((file.name, file.remoteName, batch)) }
        if let failure = failures[file.remoteName] { throw failure }
        switch mode {
        case .answer: break
        case .slow: try await Task.sleep(for: .milliseconds(300))
        case .wait:
            progress(1)
            try await Task.sleep(for: .seconds(60))
        case .stall:
            try await Task.sleep(for: .seconds(60))
        }
        progress(file.size)
        return "/home/u/.cache/shepherd/drops/\(batch)/\(file.remoteName)"
    }

    func close() async { lock.withLock { _closes += 1 } }
}

@main @MainActor enum ControllerTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: String) { precondition(condition, why); checks += 1 }
    static var work = ""
    static func url(_ name: String) -> URL { URL(fileURLWithPath: "\(work)/\(name)", isDirectory: name.hasSuffix("/")) }
    static func list(_ names: [String]) -> String { names.formatted(.list(type: .and)) }

    static func settle(_ controller: TerminalDropController) async {
        let start = ContinuousClock.now
        while controller.isUploading {
            try? await Task.sleep(for: .milliseconds(10))
            precondition(ContinuousClock.now - start < .seconds(15), "the upload never ended")
        }
    }
    static func until(_ condition: () -> Bool) async {
        let start = ContinuousClock.now
        while !condition() {
            try? await Task.sleep(for: .milliseconds(10))
            precondition(ContinuousClock.now - start < .seconds(15), "timed out waiting")
        }
    }

    final class Harness {
        var pasted: [String] = []
        var destinations = 0
        var connects = 0
        var enabled = true
        let controller: TerminalDropController
        init(_ uploader: FakeUploader?, connectError: (any Error)? = nil, destinationError: (any Error)? = nil, stallLimit: Duration = .seconds(120)) {
            var harness: Harness?
            controller = TerminalDropController(isEnabled: { harness?.enabled ?? false }, destination: {
                harness?.destinations += 1
                if let destinationError { throw destinationError }
                guard let uploader else { return .thisMac }
                return .elsewhere {
                    harness?.connects += 1
                    if let connectError { throw connectError }
                    return uploader
                }
            }, stallLimit: stallLimit)
            harness = self
            controller.paste = { [weak self] in self?.pasted.append($0) }
        }
    }

    static func main() async throws {
        work = CommandLine.arguments[1]
        let fm = FileManager.default
        for name in ["a.png", "b.jpg", "c.gif", "notes.pdf", "space dir/x y.png"] + (1...22).map({ "many/m\($0).png" }) {
            try fm.createDirectory(atPath: (("\(work)/\(name)") as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url(name))
        }
        try fm.createDirectory(at: url("folder/"), withIntermediateDirectories: true)
        let big = Darwin.open("\(work)/big.png", O_CREAT | O_WRONLY, 0o600)
        precondition(big >= 0 && ftruncate(big, off_t(TerminalDropPaste.maximumFileBytes + 1)) == 0); Darwin.close(big)

        routes()
        try await thisMac()
        try await elsewhere()
        try await failures()
        try await leaving()
        print("controller checks: \(checks)")
    }

    static func routes() {
        let machine = HerdrMachine(id: "m", label: "M", target: "gpu", session: "default", enabled: true)
        check(TerminalDropRoute(isLocal: true, herdrMachine: nil) == .thisMac, "A: this Mac's herdr")
        check(TerminalDropRoute(isLocal: false, herdrMachine: nil) == .host, "B: the host's herdr")
        check(TerminalDropRoute(isLocal: true, herdrMachine: machine) == .thisMacMachine(machine), "C: this Mac's herdr machine")
        check(TerminalDropRoute(isLocal: false, herdrMachine: machine) == .hostMachine(machine), "D: the host's herdr machine")
    }

    static func thisMac() async throws {
        let harness = Harness(nil)
        harness.controller.drop([url("a.png"), url("notes.pdf"), url("folder/"), url("space dir/x y.png")])
        // The work folder's own name has a space in it (escaping itself is
        // checked in FileDropTests).
        let w = TerminalDropPaste.escaped(work)!
        check(w.contains("\\ ") && harness.pasted == ["\(w)/a.png \(w)/notes.pdf \(w)/folder \(w)/space\\ dir/x\\ y.png "],
              "every path, any kind, one paste: \(harness.pasted)")
        check(harness.controller.activity == .idle && harness.connects == 0, "nothing to upload or say")

        harness.pasted = []
        harness.controller.drop([url("a.png"), URL(fileURLWithPath: "/tmp/bad\u{1b}[201~name.png")])
        check(harness.pasted == ["\(w)/a.png "], "the rest still pasted")
        check(harness.controller.activity == .finished(["Couldn't paste bad\u{1b}[201~name.png: the path has control characters in it."]), "\(harness.controller.activity)")
        harness.controller.dismiss()
        check(harness.controller.activity == .idle, "dismissed")

        harness.enabled = false
        harness.pasted = []
        let before = harness.destinations
        harness.controller.drop([url("a.png")])
        check(harness.pasted.isEmpty && harness.destinations == before, "turned off: a drop is not taken at all")
    }

    static func elsewhere() async throws {
        // Nothing but non-images: nothing to connect for.
        let none = FakeUploader()
        let noImages = Harness(none)
        noImages.controller.drop([url("notes.pdf"), url("folder/")])
        check(noImages.controller.activity == .finished(["Only PNG, JPEG, GIF, and WebP images can be attached to panes on another machine."]), "\(noImages.controller.activity)")
        check(noImages.connects == 0 && none.uploads.isEmpty, "no connection, no Keychain read")

        // Mixed: the image goes, the rest are named.
        let uploader = FakeUploader(mode: .slow)
        let mixed = Harness(uploader)
        mixed.controller.drop([url("a.png"), url("notes.pdf"), url("folder/")])
        guard case .uploading(1, 1, let fraction) = mixed.controller.activity else { preconditionFailure("\(mixed.controller.activity)") }
        check(fraction == 0, "starts at nothing sent")
        mixed.enabled = false // turning it off doesn't stop an upload under way
        await settle(mixed.controller)
        let batch = uploader.uploads.first?.batch ?? ""
        check(UUID(uuidString: batch) != nil && batch == batch.lowercased(), "a lowercase UUID batch")
        check(mixed.pasted == ["/home/u/.cache/shepherd/drops/\(batch)/a.png "], "the uploaded path pasted: \(mixed.pasted)")
        check(mixed.controller.activity == .finished(["Non-image items skipped (2): \(list(["notes.pdf", "folder"]))"]), "\(mixed.controller.activity)")
        check(uploader.closes == 1 && mixed.connects == 1, "one connection, closed")

        // Over the limit.
        let many = FakeUploader()
        let limited = Harness(many)
        limited.controller.drop((1...22).map { url("many/m\($0).png") })
        await settle(limited.controller)
        check(many.uploads.count == 20 && Set(many.uploads.map(\.batch)).count == 1, "20 uploads, one batch")
        check(limited.pasted.count == 1 && limited.pasted[0].split(separator: " ").count == 20, "20 paths in one paste")
        check(limited.controller.activity == .finished(["Over the limit of 20 images per drop, skipped (2): \(list(["m21.png", "m22.png"]))"]), "\(limited.controller.activity)")
    }

    static func failures() async throws {
        // One file's own failure: the others go on and are pasted.
        let partial = FakeUploader(failures: ["b.jpg": .failed(status: 72, detail: "")])
        let harness = Harness(partial)
        harness.controller.drop([url("a.png"), url("b.jpg"), url("c.gif")])
        await settle(harness.controller)
        let batch = partial.uploads.first?.batch ?? ""
        check(partial.uploads.map(\.name) == ["a.png", "b.jpg", "c.gif"], "all tried")
        check(harness.pasted == ["/home/u/.cache/shepherd/drops/\(batch)/a.png /home/u/.cache/shepherd/drops/\(batch)/c.gif "], "\(harness.pasted)")
        check(harness.controller.activity == .finished(["Couldn't upload b.jpg. A file with that name is already there."]), "\(harness.controller.activity)")

        // A failure the rest would meet too: not tried, named together.
        let unreachable = FakeUploader(failures: ["a.png": .failed(status: 255, detail: "ssh: connect to host gpu port 22: Connection refused")])
        let ended = Harness(unreachable)
        ended.controller.drop([url("a.png"), url("b.jpg"), url("c.gif")])
        await settle(ended.controller)
        check(unreachable.uploads.count == 1 && ended.pasted.isEmpty, "the rest not tried, nothing pasted")
        check(ended.controller.activity == .finished(["Couldn't upload \(list(["a.png", "b.jpg", "c.gif"])). ssh: connect to host gpu port 22: Connection refused"]), "\(ended.controller.activity)")

        // Too large: refused before anything is sent; the others go.
        let sized = FakeUploader()
        let large = Harness(sized)
        large.controller.drop([url("big.png"), url("a.png")])
        await settle(large.controller)
        check(sized.uploads.map(\.name) == ["a.png"] && large.pasted.count == 1, "only the small one sent")
        check(large.controller.activity == .finished(["Couldn't upload big.png. It is larger than 16 MiB."]), "\(large.controller.activity)")

        // No pinned host key / no credential: nothing connects.
        let unpinned = FakeUploader()
        let refused = Harness(unpinned, connectError: TerminalDropError.needsHostKey)
        refused.controller.drop([url("a.png"), url("notes.pdf")])
        check(unpinned.uploads.isEmpty && refused.pasted.isEmpty, "nothing sent")
        check(refused.controller.activity == .finished(["Non-image items skipped (1): notes.pdf",
                                                        "Couldn't upload a.png. Connect to this machine's terminal first to verify its host key."]), "\(refused.controller.activity)")

        // The pane's machine changed under the view.
        struct Changed: LocalizedError { var errorDescription: String? { "The machine settings changed." } }
        let changed = Harness(FakeUploader(), destinationError: Changed())
        changed.controller.drop([url("a.png")])
        check(changed.controller.activity == .finished(["The machine settings changed."]) && changed.connects == 0, "\(changed.controller.activity)")

        // Stalled: given up on, its connection closed.
        let stalled = FakeUploader(mode: .stall)
        let slow = Harness(stalled, stallLimit: .seconds(1))
        slow.controller.drop([url("a.png"), url("b.jpg")])
        await settle(slow.controller)
        check(stalled.uploads.count == 1 && slow.pasted.isEmpty && stalled.closes >= 1, "stopped, closed, nothing pasted")
        check(slow.controller.activity == .finished(["Couldn't upload \(list(["a.png", "b.jpg"])). The upload stopped making progress."]), "\(slow.controller.activity)")
    }

    static func leaving() async throws {
        let waiting = FakeUploader(mode: .wait)
        let harness = Harness(waiting)
        harness.controller.drop([url("a.png"), url("b.jpg")])
        await until { !waiting.uploads.isEmpty }
        await until {
            if case .uploading(1, 2, let fraction) = harness.controller.activity { return fraction > 0 }
            return false
        }
        check(true, "progress shown while uploading")
        // One drop at a time.
        let destinations = harness.destinations
        harness.controller.drop([url("c.gif")])
        check(harness.destinations == destinations && waiting.uploads.count == 1, "a second drop while uploading is not taken")
        // The pane goes away.
        harness.controller.cancel()
        check(harness.controller.activity == .idle, "nothing left showing")
        await until { waiting.closes == 1 }
        try await Task.sleep(for: .milliseconds(300))
        check(harness.pasted.isEmpty && waiting.uploads.count == 1 && harness.controller.activity == .idle, "nothing pasted, nothing more sent")
    }
}
