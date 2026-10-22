import Foundation
import CoreGraphics
import Observation
import Citadel
import NIOConcurrencyHelpers

struct HostCredential {
    let authMethod: Machine.AuthMethod
    let secretData: Data
    nonisolated func authenticationMethod(username: String) throws -> OwnedAuth { .init() }
}
struct TOFUHostKeyValidator: OwnedValidator {
    let pinnedFingerprint: String?
    let observedFingerprint: NIOLockedValueBox<String?>
}
// Only the pane value used to create a request is a seam; real store/reader/
// model are compiled unchanged. Full-app builds use real AgentSummary.
struct AgentSummary {
    let paneID: String
    let terminalID: String
    let workingDirectory: String?
    let herdrMachine: OwnedHerdrMachine?
}
struct OwnedHerdrMachine { let id: String }
/// Whether an observed property was changed.
nonisolated final class Changed: @unchecked Sendable { var value = false }
final class OwnedSecrets: MachineSecretStore {
    var values: [String: Data] = [:]
    var loads = 0
    func saveSecret(_ data: Data, tag: String) throws { values[tag] = data }
    func loadSecret(tag: String) throws -> Data? { loads += 1; return values[tag] }
    func deleteSecret(tag: String) throws { values[tag] = nil }
}

@main @MainActor enum ModelTests {
    static var checks = 0
    static func check(_ b: Bool, line: Int = #line) { precondition(b, "check at line \(line)"); checks += 1 }
    static func text(_ model: FilePreviewModel) -> String? {
        if case .loaded(let document) = model.state, case .text(let text, _) = document.content { return text }
        return nil
    }
    static func failure(_ model: FilePreviewModel) -> String? {
        if case .failed(let message) = model.state { return message }
        return nil
    }
    static func isLoading(_ model: FilePreviewModel) -> Bool {
        if case .loading = model.state { return true }
        return false
    }
    static func main() async throws {
        let directory = ProcessInfo.processInfo.arguments[1]
        let suite = "owned-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = OwnedSecrets()
        let local = Machine(displayName: "Owned Local", hostname: "localhost", username: "owned", isLocal: true)
        let store = MachineStore(defaults: defaults, localMachine: local, keychain: secrets)
        let pane = AgentSummary(paneID: "owned-pane", terminalID: "owned-terminal", workingDirectory: directory, herdrMachine: nil)
        let path = directory + "/model.md"
        try Data("# Local newest".utf8).write(to: URL(fileURLWithPath: path))
        let request = FilePreviewRequest(machine: local, pane: pane, link: "model.md")
        let model = FilePreviewModel()
        await model.load(request, store: store)
        if case .loaded = model.state { checks += 1 } else { preconditionFailure("local loaded") }
        check(secrets.loads == 0)
        check(model.link?.path == path)
        let next = request.following("next.md", directory: directory)
        check(next.id != request.id && next.paneID == request.paneID && next.machine.connectionIdentity == request.machine.connectionIdentity)
        check(request.herdrMachineID == nil && next.herdrMachineID == nil)
        let nested = AgentSummary(paneID: "owned-pane", terminalID: "owned-terminal", workingDirectory: directory, herdrMachine: OwnedHerdrMachine(id: "nested"))
        let nestedRequest = FilePreviewRequest(machine: local, pane: nested, link: "model.md")
        check(nestedRequest.herdrMachineID == "nested" && nestedRequest.following("x.md", directory: directory).herdrMachineID == "nested")
        await model.load(nestedRequest, store: store)
        if case .failed = model.state { checks += 1 } else { preconditionFailure("nested must not read local") }
        check(secrets.loads == 0)
        // A failure is kept for its pane too: shown again, the preview is
        // not read again; Retry (`load`) reads.
        await model.loadIfNeeded(nestedRequest, store: store)
        if case .failed = model.state { checks += 1 } else { preconditionFailure("kept failure") }
        // Source or rendering: each read starts with the rendering, a link
        // to a line with the source; a preview shown again keeps the choice.
        let lined = FilePreviewModel()
        let linedRequest = FilePreviewRequest(machine: local, pane: pane, link: "model.md:1")
        await lined.load(linedRequest, store: store)
        check(lined.showsSource && lined.link?.line == 1)
        lined.showsSource = false; lined.scrollOffset = CGPoint(x: 0, y: 40)
        await lined.loadIfNeeded(linedRequest, store: store)
        check(!lined.showsSource && lined.scrollOffset == CGPoint(x: 0, y: 40))
        await lined.load(linedRequest, store: store)
        check(lined.showsSource && lined.scrollOffset == nil)
        let plain = FilePreviewModel()
        await plain.load(request, store: store)
        check(!plain.showsSource)
        // The table of contents: on for each read, off for this preview
        // only, kept while shown again; where it scrolls the preview to.
        check(plain.showsOutline && plain.scrollRequest == nil && plain.visibleBlocks.isEmpty && plain.visibleLines.isEmpty)
        plain.showsOutline = false; plain.visibleBlocks = [3, 4]; plain.visibleLines = [7]
        plain.reveal(.block(4))
        let first = plain.scrollRequest
        plain.reveal(.block(4))
        check(first?.target == .block(4) && plain.scrollRequest?.target == .block(4) && plain.scrollRequest != first)
        await plain.loadIfNeeded(request, store: store)
        check(!plain.showsOutline && model.showsOutline && lined.showsOutline)
        await plain.load(request, store: store)
        check(plain.showsOutline && plain.scrollRequest == nil && plain.visibleBlocks.isEmpty && plain.visibleLines.isEmpty)
        let remote = Machine(displayName: "Owned Remote", hostname: "owned.invalid", username: "owned", authMethod: .password)
        try store.addMachine(remote, password: "synthetic-only")
        let remoteRequest = FilePreviewRequest(machine: remote, pane: pane, link: "/remote/a.md")
        await model.load(remoteRequest, store: store)
        if case .failed = model.state { checks += 1 } else { preconditionFailure("unpinned") }
        check(secrets.loads == 0)
        store.pinHostKeyFingerprint("owned-pin", for: remote)
        await OwnedSFTP.shared.plan(Array("# Synthetic remote".utf8))
        await model.load(remoteRequest, store: store)
        if case .loaded = model.state { checks += 1 } else { preconditionFailure("refreshed pin should work") }
        let pins = await OwnedSFTP.shared.pins
        check(pins == ["owned-pin"])
        check(secrets.loads == 1)
        // Shown again with its pane, a remote preview that was read is not
        // read again: no SSH connection, no Keychain read.
        let connectsBefore = await OwnedSFTP.shared.connects
        await model.loadIfNeeded(remoteRequest, store: store)
        if case .loaded = model.state { checks += 1 } else { preconditionFailure("kept remote read") }
        let connectsAfter = await OwnedSFTP.shared.connects
        check(connectsAfter == connectsBefore && secrets.loads == 1)
        // A read cancelled when its pane was left is made again on return.
        let returning = FilePreviewModel()
        await OwnedSFTP.shared.plan(Array("# Returned".utf8), heldRead: true)
        let left = Task { await returning.loadIfNeeded(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingRead) { await Task.yield() }
        left.cancel()
        await left.value
        if case .loading = returning.state { checks += 1 } else { preconditionFailure("cancelled read must not publish") }
        await OwnedSFTP.shared.plan(Array("# Returned".utf8))
        await returning.loadIfNeeded(remoteRequest, store: store)
        if case .loaded(let doc) = returning.state, case .text(let value, _) = doc.content { check(value == "# Returned") }
        else { preconditionFailure("read again after a cancelled read") }
        // (`plan` counts from zero.)
        let connectsReturned = await OwnedSFTP.shared.connects
        check(connectsReturned == 1)
        // A late completion must not replace a newer local preview or its path.
        await OwnedSFTP.shared.plan(Array("# Late".utf8), heldConnect: true)
        let old = Task { await model.load(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingConnect) { await Task.yield() }
        await model.load(request, store: store)
        await OwnedSFTP.shared.releaseConnect()
        await old.value
        if case .loaded(let doc) = model.state, case .text(let value, _) = doc.content {
            check(value == "# Local newest")
        } else { preconditionFailure("late result must not win") }
        check(model.link?.path == path)
        // Cancellation closes a pending read and doesn't publish a false error.
        await OwnedSFTP.shared.plan([65], heldRead: true)
        let pending = Task { await model.load(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingRead) { await Task.yield() }
        pending.cancel()
        await pending.value
        let closed = await OwnedSFTP.shared.closes
        check(closed >= 1)
        if case .loading = model.state { checks += 1 } else { preconditionFailure("cancelled result must not publish") }
        // The actual production 15-second timer closes a blocked SFTP read.
        await OwnedSFTP.shared.plan([65], heldRead: true)
        await model.load(remoteRequest, store: store)
        if case .failed(let error) = model.state { check(error == FilePreviewError.timedOut.localizedDescription) }
        else { preconditionFailure("timeout") }
        let timeoutClosed = await OwnedSFTP.shared.closes
        check(timeoutClosed >= 1)
        // Reload (SHPHRD-98): the same request read again, keeping how the
        // file is looked at: source or rendering, scroll place, the line
        // linked to, the table of contents and the find bar.
        let localLoads = secrets.loads
        let reloadPath = directory + "/reload.md"
        try Data("# Reload one\n\nfirst".utf8).write(to: URL(fileURLWithPath: reloadPath))
        let reloadRequest = FilePreviewRequest(machine: local, pane: pane, link: "reload.md")
        let viewed = FilePreviewModel()
        await viewed.load(reloadRequest, store: store)
        check(text(viewed) == "# Reload one\n\nfirst" && !viewed.isReloading && !viewed.isReading && !viewed.showsSource)
        let linked = viewed.link
        viewed.showsSource = true; viewed.scrollOffset = CGPoint(x: 0, y: 120); viewed.showsOutline = false
        let keptAnchor = PreviewScrollAnchor(inSource: true, row: 3, offset: 8, height: 40)
        viewed.scrollAnchor = keptAnchor
        viewed.find = PreviewFindState(isShown: true, query: "one", current: 0)
        viewed.visibleLines = [2, 3]; viewed.reveal(.line(3))
        let revealed = viewed.scrollRequest
        try Data("# Reload two\n\nsecond one".utf8).write(to: URL(fileURLWithPath: reloadPath))
        await viewed.reload(reloadRequest, store: store)
        check(text(viewed) == "# Reload two\n\nsecond one" && !viewed.isReloading && !viewed.isReading)
        check(viewed.link == linked && viewed.link?.path == reloadPath && viewed.finishedRequestID == reloadRequest.id)
        check(viewed.showsSource && viewed.scrollOffset == CGPoint(x: 0, y: 120) && !viewed.showsOutline)
        check(viewed.scrollRequest == revealed && viewed.visibleLines == [2, 3])
        check(viewed.scrollAnchor == keptAnchor)
        // What the find bar looks for is kept; it counts its matches in the
        // new text, at none of them yet, as when Source is chosen.
        check(viewed.find == PreviewFindState(isShown: true, query: "one", current: nil))
        // The same file read again: nothing shown is changed.
        viewed.find.current = 1
        let stateChanged = Changed(), linkChanged = Changed()
        withObservationTracking { _ = viewed.state } onChange: { stateChanged.value = true }
        withObservationTracking { _ = viewed.link } onChange: { linkChanged.value = true }
        await viewed.reload(reloadRequest, store: store)
        check(!stateChanged.value && !linkChanged.value && viewed.find.current == 1 && text(viewed) == "# Reload two\n\nsecond one")
        // Shown again with its pane after a reload: not read again.
        try Data("# Reload three".utf8).write(to: URL(fileURLWithPath: reloadPath))
        await viewed.loadIfNeeded(reloadRequest, store: store)
        check(text(viewed) == "# Reload two\n\nsecond one")
        // The file gone: why, with how it was looked at kept for the next
        // read that works, which shows it as it was looked at.
        try FileManager.default.removeItem(atPath: reloadPath)
        await viewed.reload(reloadRequest, store: store)
        check(failure(viewed) != nil && !viewed.isReloading && !viewed.isReading)
        check(viewed.link == linked && viewed.showsSource && viewed.scrollOffset == CGPoint(x: 0, y: 120) && !viewed.showsOutline)
        check(viewed.find.isShown && viewed.find.query == "one")
        check(viewed.scrollAnchor == keptAnchor)
        await viewed.loadIfNeeded(reloadRequest, store: store)
        check(failure(viewed) != nil)
        try Data("# Reload back".utf8).write(to: URL(fileURLWithPath: reloadPath))
        await viewed.reload(reloadRequest, store: store)
        check(text(viewed) == "# Reload back" && viewed.showsSource && viewed.scrollOffset == CGPoint(x: 0, y: 120) && !viewed.showsOutline)
        check(viewed.find.isShown && viewed.find.query == "one" && viewed.link == linked)
        check(viewed.scrollAnchor == keptAnchor)
        // Past 4 MiB: too large, as for a first read.
        try Data(repeating: 65, count: FilePreviewDocument.maximumBytes + 1).write(to: URL(fileURLWithPath: reloadPath))
        await viewed.reload(reloadRequest, store: store)
        check(failure(viewed) == FilePreviewError.tooLarge.localizedDescription && viewed.showsSource)
        try Data("# Reload one\n\nfirst".utf8).write(to: URL(fileURLWithPath: reloadPath))
        // A link to a line: the source is chosen as the file is first shown,
        // not again when it is read again.
        let lineRequest = FilePreviewRequest(machine: local, pane: pane, link: "reload.md:2")
        let atLine = FilePreviewModel()
        await atLine.load(lineRequest, store: store)
        check(atLine.showsSource && atLine.link?.line == 2)
        atLine.showsSource = false
        await atLine.reload(lineRequest, store: store)
        check(!atLine.showsSource && atLine.link?.line == 2 && text(atLine) == "# Reload one\n\nfirst")
        // A link to a line whose first read failed: Retry shows it first.
        let laterPath = directory + "/later.md"
        let laterRequest = FilePreviewRequest(machine: local, pane: pane, link: "later.md:1")
        let later = FilePreviewModel()
        await later.load(laterRequest, store: store)
        check(failure(later) != nil && !later.showsSource)
        try Data("# Later".utf8).write(to: URL(fileURLWithPath: laterPath))
        await later.reload(laterRequest, store: store)
        check(text(later) == "# Later" && later.showsSource && later.link?.line == 1)
        // A new read still starts everything over.
        viewed.showsOutline = false
        await viewed.load(reloadRequest, store: store)
        check(!viewed.showsSource && viewed.scrollOffset == nil && viewed.scrollAnchor == nil && viewed.showsOutline && viewed.find == PreviewFindState())
        check(secrets.loads == localLoads)

        // Remote: what was read stays shown while it is read again; each
        // reload connects once, reads the Keychain once and checks the pin.
        let far = FilePreviewModel()
        await OwnedSFTP.shared.plan(Array("# Far one".utf8))
        let farLoads = secrets.loads
        await far.load(remoteRequest, store: store)
        check(text(far) == "# Far one" && secrets.loads == farLoads + 1)
        far.showsSource = true; far.scrollOffset = CGPoint(x: 0, y: 64)
        await OwnedSFTP.shared.plan(Array("# Far two".utf8), heldConnect: true)
        let reloading = Task { await far.reload(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingConnect) { await Task.yield() }
        check(text(far) == "# Far one" && far.isReloading && far.isReading)
        await OwnedSFTP.shared.releaseConnect()
        await reloading.value
        check(text(far) == "# Far two" && !far.isReloading && far.showsSource && far.scrollOffset == CGPoint(x: 0, y: 64))
        let farConnects = await OwnedSFTP.shared.connects, farPins = await OwnedSFTP.shared.pins
        check(farConnects == 1 && farPins == ["owned-pin"] && secrets.loads == farLoads + 2)
        await OwnedSFTP.shared.plan(Array("# Far two".utf8))
        await far.reload(remoteRequest, store: store)
        let againConnects = await OwnedSFTP.shared.connects, againPins = await OwnedSFTP.shared.pins
        check(againConnects == 1 && againPins == ["owned-pin"] && secrets.loads == farLoads + 3)
        // Left with its pane while read again: the read is closed, what was
        // read stays, and the reload is made again once on return.
        await OwnedSFTP.shared.plan(Array("# Far three".utf8), heldRead: true)
        let away = Task { await far.reload(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingRead) { await Task.yield() }
        check(far.isReloading)
        away.cancel()
        await away.value
        let leftCloses = await OwnedSFTP.shared.closes
        check(text(far) == "# Far two" && !far.isReloading && !far.isReading && leftCloses >= 1)
        await OwnedSFTP.shared.plan(Array("# Far three".utf8))
        await far.loadIfNeeded(remoteRequest, store: store)
        let backConnects = await OwnedSFTP.shared.connects
        check(text(far) == "# Far three" && backConnects == 1 && far.showsSource && far.scrollOffset == CGPoint(x: 0, y: 64))
        await far.loadIfNeeded(remoteRequest, store: store)
        let stayConnects = await OwnedSFTP.shared.connects
        check(stayConnects == 1)
        // A failed preview read again shows that it is reading.
        await OwnedSFTP.shared.plan(Array("# Far".utf8), mode: 0o040755)
        await far.reload(remoteRequest, store: store)
        check(failure(far) == FilePreviewError.notRegularFile.localizedDescription && far.showsSource)
        await OwnedSFTP.shared.plan(Array("# Far four".utf8), heldConnect: true)
        let retry = Task { await far.reload(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingConnect) { await Task.yield() }
        check(isLoading(far) && !far.isReloading && far.isReading)
        await OwnedSFTP.shared.releaseConnect()
        await retry.value
        check(text(far) == "# Far four" && far.showsSource && far.scrollOffset == CGPoint(x: 0, y: 64))
        // And left with its pane then: read again on return.
        await OwnedSFTP.shared.plan(Array("# Far".utf8), mode: 0o040755)
        await far.reload(remoteRequest, store: store)
        await OwnedSFTP.shared.plan(Array("# Far five".utf8), heldRead: true)
        let gone = Task { await far.reload(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingRead) { await Task.yield() }
        gone.cancel()
        await gone.value
        check(isLoading(far))
        await OwnedSFTP.shared.plan(Array("# Far five".utf8))
        await far.loadIfNeeded(remoteRequest, store: store)
        check(text(far) == "# Far five" && far.showsSource)
        // A late reload doesn't win over a newer read of another request.
        await OwnedSFTP.shared.plan(Array("# Late reload".utf8), heldConnect: true)
        let late = Task { await far.reload(remoteRequest, store: store) }
        while !(await OwnedSFTP.shared.waitingConnect) { await Task.yield() }
        await far.load(reloadRequest, store: store)
        await OwnedSFTP.shared.releaseConnect()
        await late.value
        check(text(far) == "# Reload one\n\nfirst" && far.link?.path == reloadPath && !far.isReloading && !far.showsSource)
        // A nested herdr's pane: the same error read again.
        await far.reload(nestedRequest, store: store)
        check(failure(far) == FilePreviewError.nestedMachine.localizedDescription)

        // Stale credential/endpoint records never reach the reader or Keychain.
        let oldLoads = secrets.loads
        var edited = remote; edited.hostname = "new-owned.invalid"
        try store.updateMachine(edited, replacing: remote)
        await OwnedSFTP.shared.plan()
        await model.load(remoteRequest, store: store)
        if case .failed = model.state { checks += 1 } else { preconditionFailure("stale connection") }
        check(secrets.loads == oldLoads)
        let staleConnects = await OwnedSFTP.shared.connects; check(staleConnects == 0)
        print("PASS \(checks) real preview model/store request, no-local-secret, refreshed-pin, stale-epoch, cancellation, 15s timeout and reload checks; in-memory SSH/secret seams only")
    }
}
