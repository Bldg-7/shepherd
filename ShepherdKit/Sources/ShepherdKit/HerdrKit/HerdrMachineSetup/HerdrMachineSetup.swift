import Foundation
import Observation

/// Adding a herdr machine to a host's herdr from Shepherd, or checking a
/// failing one again: what the person has picked, the checks run on the
/// host one after another, and what they are asked when the checks stop.
///
/// Adding asks for the SSH target — a Host alias from the host's
/// ~/.ssh/config, or typed in — and a name, then checks, on the host:
/// 1. what OpenSSH resolves the target to (`ssh -G`);
/// 2. signing in to it the way herdr will once the machine is saved —
///    without asking anyone anything, a host key it doesn't know turned
///    down — and where herdr is there. A key it doesn't know is fetched
///    (2b) and shown to the person, and once they trust it, added to the
///    host's known_hosts (2c), and signing in is tried again;
/// 3. what was found of herdr there;
/// 4. `herdr machine add`, which saves the machine.
///
/// Whatever only a person at a terminal can answer — herdr asking to
/// install or replace itself on the machine, OpenSSH asking about a jump
/// host's key or for a login in a browser — goes to a new tab on the host,
/// with the command that asks it (`TerminalHandoff`). A key that isn't the
/// one known for the target, or that was revoked, is never written over:
/// the checks stop there.
///
/// Checking again (`Mode.reconnect`) runs 1–3 for a saved machine, and then
/// asks herdr whether it reaches the machine's server.
@MainActor @Observable
public final class HerdrMachineSetup {
    public enum Mode: Equatable, Sendable {
        case add
        case reconnect(HerdrMachine)
    }

    public enum Stage: Equatable, Sendable {
        case target
        case name
        case checks
    }

    public enum CheckKind: Equatable, Hashable, Sendable {
        case resolve
        case signIn
        case herdr
        case save
        case reconnect
    }

    public enum CheckState: Equatable, Sendable {
        case pending
        case running(since: Date)
        /// Stopped until the person answers.
        case waiting
        case passed
        case failed
        case stopped
    }

    public struct Check: Identifiable, Equatable, Sendable {
        public let kind: CheckKind
        public var state: CheckState = .pending
        /// What it found, or is doing, in a line.
        public var detail: String?
        public var id: CheckKind { kind }
    }

    /// What the person can do when the checks stop.
    public enum Action: Hashable, Sendable {
        case trust
        case cancel
        case tryAgain
        case openTerminal
        case continueInTerminal
        case done
    }

    public enum Prompt: Equatable, Sendable {
        /// The target's host key, for the person to trust or not.
        case trust(HostKeyApproval)
        case problem(message: String, actions: [Action])
        case finished(message: String, actions: [Action])

        public var actions: [Action] {
            switch self {
            case .trust: [.trust, .cancel]
            case .problem(_, let actions), .finished(_, let actions): actions
            }
        }
    }

    /// A new tab on the host for what only a person at a terminal can do:
    /// the command to run there, or nil for a shell to work in.
    public struct TerminalHandoff: Equatable, Sendable {
        public let tabName: String
        public let argv: [String]?
    }

    public let mode: Mode
    /// The host's name, as the board shows it.
    public let hostName: String
    public private(set) var stage: Stage
    public private(set) var target: String?
    public private(set) var label: String?
    /// The Host aliases in the host's ~/.ssh/config and what it includes.
    public private(set) var hostAliases: [String] = []
    /// Why what was typed for the target or the name can't be taken.
    public private(set) var inputError: String?
    public private(set) var checks: [Check] = []
    public private(set) var prompt: Prompt?
    /// Whether `herdr machine add` is running, which Esc stops rather than
    /// leaves running unseen.
    public private(set) var isSaving = false
    public private(set) var isStopping = false
    /// The ID herdr saved the machine under, once it has.
    public private(set) var savedMachineID: String?
    public private(set) var isClosed = false
    /// Whether it closed handing over to a tab on the host, which then has
    /// the keyboard.
    public private(set) var didHandOff = false

    /// Opens a tab on the host for `TerminalHandoff`, and selects it.
    @ObservationIgnored public var onTerminal: (@MainActor (TerminalHandoff) async throws -> Void)?
    /// The host's herdr machines changed: read them again.
    @ObservationIgnored public var onMachinesChanged: (@MainActor () -> Void)?
    @ObservationIgnored public var onClose: (@MainActor () -> Void)?
    /// Closed, and done with the host: nothing runs there for it any more.
    /// Later than `onClose` for a save that was still running.
    @ObservationIgnored public var onEnded: (@MainActor () -> Void)?

    private let runner: any HostStepRunning
    private let savedMachines: @MainActor () -> [HerdrMachine]
    private let listMachines: @MainActor () async throws -> [HerdrMachine]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resolved: SSHResolvedConfig?
    @ObservationIgnored private var trustedKey = false
    @ObservationIgnored private var addPIDFile: String?
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var hasBegun = false

    /// - `runner` runs the steps on the host.
    /// - `savedMachines` is every herdr machine the host has, as last read:
    ///   what a new one's target and name are checked against.
    /// - `listMachines` reads them anew: whether a stopped
    ///   `herdr machine add` saved the machine after all.
    public init(mode: Mode, hostName: String, runner: any HostStepRunning,
                savedMachines: @escaping @MainActor () -> [HerdrMachine],
                listMachines: @escaping @MainActor () async throws -> [HerdrMachine]) {
        self.mode = mode
        self.hostName = hostName
        self.runner = runner
        self.savedMachines = savedMachines
        self.listMachines = listMachines
        switch mode {
        case .add:
            stage = .target
        case .reconnect(let machine):
            stage = .checks
            target = machine.target
            label = machine.label
        }
    }

    /// Starts: reads the host's Host aliases to pick from, or, checking a
    /// machine again, starts the checks.
    public func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        switch mode {
        case .add:
            task = Task { await loadHostAliases() }
        case .reconnect:
            startChecks()
        }
    }

    // MARK: Target and name

    /// The label of the saved machine `target` is already saved as, in the
    /// session herdr uses by default — the one a new machine is saved in.
    public func savedLabel(forTarget target: String) -> String? {
        savedMachines().first { $0.target == target && $0.session == Self.defaultSession }?.label
    }

    /// Takes `text` for the target and asks for the name, or says why it
    /// can't be taken.
    @discardableResult
    public func chooseTarget(_ text: String) -> Bool {
        guard stage == .target else { return false }
        let target = text.trimmingCharacters(in: .whitespaces)
        if let error = Self.targetProblem(target, saved: savedMachines()) {
            inputError = error
            return false
        }
        inputError = nil
        self.target = target
        stage = .name
        return true
    }

    /// The name the machine gets when none is typed: the target's host,
    /// made unlike every name already saved.
    public var suggestedLabel: String {
        Self.suggestedLabel(for: target ?? "", saved: savedMachines())
    }

    /// Takes `text` for the name — `suggestedLabel` for an empty one — and
    /// starts the checks, or says why it can't be taken.
    @discardableResult
    public func chooseName(_ text: String) -> Bool {
        guard stage == .name else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let label = trimmed.isEmpty ? suggestedLabel : trimmed
        if let error = Self.labelProblem(label, saved: savedMachines()) {
            inputError = error
            return false
        }
        inputError = nil
        self.label = label
        stage = .checks
        startChecks()
        return true
    }

    /// Backspace in an empty field: back to the step before. Not while a
    /// check runs, nor from the checks of a machine being checked again,
    /// which has no steps before them.
    public func stepBack() {
        switch stage {
        case .target:
            break
        case .name:
            stage = .target
            inputError = nil
        case .checks:
            guard mode == .add, !isRunning else { return }
            task?.cancel()
            run += 1
            prompt = nil
            checks = []
            inputError = nil
            stage = .name
        }
    }

    /// Whether a check is running.
    public var isRunning: Bool {
        checks.contains { if case .running = $0.state { true } else { false } }
    }

    // MARK: Answers

    public func perform(_ action: Action) {
        guard prompt?.actions.contains(action) == true else { return }
        switch action {
        case .trust:
            trustHostKey()
        case .cancel, .done:
            close()
        case .tryAgain:
            startChecks()
        case .openTerminal:
            handOff(TerminalHandoff(tabName: label ?? target ?? "", argv: nil))
        case .continueInTerminal:
            handOff(terminalHandoff)
        }
    }

    /// Esc while saving: stops `herdr machine add`. What it leaves behind is
    /// cleaned up as it ends, and whether it saved the machine all the same
    /// is read afterwards.
    public func stop() {
        guard isSaving, !isStopping, let addPIDFile else { return }
        isStopping = true
        updateCheck(.save, detail: String(localized: "Stopping…", bundle: .shepherdKit))
        let runner = self.runner
        Task { _ = try? await runner.run(HostStep.stop(pidFile: addPIDFile)) }
    }

    /// Esc, Cancel or Done. A save still running is stopped first; the rest
    /// of it — the cleanup and the check for a late save — goes on without
    /// the overlay.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        if isSaving {
            stop()
            onClose?()
        } else {
            task?.cancel()
            run += 1
            onClose?()
            onEnded?()
        }
    }

    // MARK: The checks

    private func startChecks() {
        task?.cancel()
        run += 1
        let id = run
        prompt = nil
        trustedKey = false
        resolved = nil
        let kinds: [CheckKind] = mode == .add ? [.resolve, .signIn, .herdr, .save] : [.resolve, .signIn, .herdr, .reconnect]
        checks = kinds.map { Check(kind: $0) }
        task = Task { await resolveTarget(run: id) }
    }

    private func isCurrent(_ id: Int) -> Bool {
        run == id && !Task.isCancelled
    }

    /// 1: `ssh -G`.
    private func resolveTarget(run id: Int) async {
        guard let target else { return }
        startCheck(.resolve)
        guard let result = await runStep(SSHSteps.resolve(target), for: .resolve, run: id) else { return }
        if result.timedOut {
            return fail(.resolve, String(localized: "OpenSSH didn't answer within \(10) seconds.", bundle: .shepherdKit), [.tryAgain])
        }
        guard result.status == 0, let config = SSHResolvedConfig.parse(result.stdoutText) else {
            let message = SSHSignInOutcome.summary(result.stderrText)
            return fail(.resolve, message.isEmpty ? String(localized: "OpenSSH couldn't read its configuration for this target.", bundle: .shepherdKit) : message, [.tryAgain])
        }
        if let blocker = config.blocker {
            return fail(.resolve, blocker, [.tryAgain])
        }
        resolved = config
        pass(.resolve, detail: config.destination)
        await signIn(run: id)
    }

    /// 2: signing in the way herdr will.
    private func signIn(run id: Int) async {
        guard let target, let config = resolved else { return }
        startCheck(.signIn)
        guard let result = await runStep(SSHSteps.signIn(target), for: .signIn, run: id) else { return }
        let keyMessage = String(localized: "Nothing was changed. If the machine was set up again, remove its old key with `ssh-keygen -R \(config.knownHostsName)` on \(hostName), then try again.", bundle: .shepherdKit)
        switch SSHSignInOutcome.classify(result, hostKeyNames: config.hostKeyNames) {
        case .signedIn(let probe):
            pass(.signIn, detail: nil)
            startCheck(.herdr)
            pass(.herdr, detail: probe.summary)
            switch mode {
            case .add: await save(run: id)
            case .reconnect(let machine): await reconnect(machine, run: id)
            }
        case .unknownHostKey where !trustedKey:
            updateCheck(.signIn, detail: String(localized: "The host key isn't known yet. Fetching it…", bundle: .shepherdKit))
            await fetchHostKey(run: id)
        case .unknownHostKey:
            fail(.signIn, String(localized: "OpenSSH still doesn't know the host key after it was added. Continue in a terminal, where OpenSSH can ask about it.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
        case .jumpHostKey:
            fail(.signIn, String(localized: "The host key of the machine this target is reached through isn't known yet. Continue in a terminal, where OpenSSH can ask about it.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
        case .changedHostKey:
            fail(.signIn, String(localized: "The target's host key isn't the one known for it. That happens when a machine is set up again — and when someone is in between.", bundle: .shepherdKit) + "\n" + keyMessage, [.tryAgain])
        case .revokedHostKey:
            fail(.signIn, String(localized: "The target's host key has been revoked.", bundle: .shepherdKit) + "\n" + keyMessage, [.tryAgain])
        case .otherHostKey(let message):
            fail(.signIn, message + "\n" + String(localized: "Continue in a terminal, where OpenSSH can ask about it.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
        case .permissionDenied(let message):
            fail(.signIn, String(localized: "herdr signs in without asking for a password, so it needs a key: load yours into ssh-agent with `ssh-add`, or set this account up for key login. Then try again.", bundle: .shepherdKit) + "\n" + message, [.tryAgain, .openTerminal])
        case .authenticationURL(let url):
            fail(.signIn, String(localized: "Signing in to this target wants a browser (\(url)). Continue in a terminal to sign in.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
        case .network(let message):
            fail(.signIn, message, [.tryAgain])
        case .remoteCommand:
            fail(.signIn, String(localized: "OpenSSH's configuration gives this target a RemoteCommand, which leaves herdr no way to run its own commands there. Use a Host alias without one.", bundle: .shepherdKit), [.tryAgain])
        case .timedOut:
            fail(.signIn, String(localized: "Signing in didn't finish within \(25) seconds.", bundle: .shepherdKit), [.tryAgain, .continueInTerminal])
        case .failed(let message):
            fail(.signIn, message, [.tryAgain, .openTerminal])
        }
    }

    /// 2b: fetches the target's host key and asks the person about it.
    private func fetchHostKey(run id: Int) async {
        guard let target, let config = resolved else { return }
        guard let result = await runStep(SSHSteps.fetchHostKey(target), for: .signIn, run: id) else { return }
        guard let key = KnownHostLine.first(in: result.stdoutText) else {
            switch SSHSignInOutcome.classify(result, hostKeyNames: config.hostKeyNames) {
            case .network(let message):
                return fail(.signIn, message, [.tryAgain])
            case .timedOut:
                return fail(.signIn, String(localized: "Fetching the host key didn't finish within \(25) seconds.", bundle: .shepherdKit), [.tryAgain, .continueInTerminal])
            default:
                return fail(.signIn, String(localized: "OpenSSH didn't hand over the target's host key — it may be reached through a machine whose key isn't known yet. Continue in a terminal, where OpenSSH can ask about it.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
            }
        }
        guard let file = config.knownHostsFile, SSHSteps.appendKnownHost(key.line, to: file) != nil else {
            return fail(.signIn, String(localized: "The host key can't be added to the known_hosts file OpenSSH's configuration names (\(config.knownHostsFile ?? "")). Continue in a terminal, where OpenSSH can add it.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
        }
        setState(.signIn, .waiting, detail: String(localized: "Waiting for you to trust the host key.", bundle: .shepherdKit))
        prompt = .trust(HostKeyApproval(label: label ?? target, destination: config.destination, key: key, file: file, hostName: hostName))
    }

    /// 2c: adds the trusted key to the host's known_hosts, and signs in
    /// again.
    private func trustHostKey() {
        guard case .trust(let approval) = prompt, let step = SSHSteps.appendKnownHost(approval.key.line, to: approval.file) else { return }
        prompt = nil
        task?.cancel()
        run += 1
        let id = run
        task = Task {
            startCheck(.signIn)
            updateCheck(.signIn, detail: String(localized: "Adding the host key to \(approval.file)…", bundle: .shepherdKit))
            guard let result = await runStep(step, for: .signIn, run: id) else { return }
            guard result.status == 0, !result.timedOut else {
                let message = HerdrMachineSteps.message(result)
                return fail(.signIn, String(localized: "The host key couldn't be added to \(approval.file).", bundle: .shepherdKit) + (message.isEmpty ? "" : "\n" + message), [.tryAgain, .continueInTerminal])
            }
            trustedKey = true
            await signIn(run: id)
        }
    }

    /// 4: `herdr machine add`.
    private func save(run id: Int) async {
        guard let target, let label else { return }
        startCheck(.save)
        let pidFile = HerdrMachineSteps.pidFile(token: HostStep.newToken())
        addPIDFile = pidFile
        isSaving = true
        isStopping = false
        let outcome: HerdrMachineAddOutcome?
        do {
            outcome = HerdrMachineAddOutcome.classify(try await runner.run(HerdrMachineSteps.add(target: target, label: label, pidFile: pidFile)))
        } catch {
            // The host stopped answering, or the step's report was lost:
            // whether herdr saved the machine is for the list to say.
            outcome = nil
        }
        isSaving = false
        addPIDFile = nil
        let stopped = isStopping
        isStopping = false
        switch outcome {
        case .saved(let id):
            saved(id)
        case .invalid(let message):
            // herdr turned the name or the target down before trying
            // anything: back to the name, with its reason.
            if isCurrent(id) {
                prompt = nil
                checks = []
                stage = .name
                inputError = message
            }
        case .needsTerminal(let message):
            fail(.save, message + "\n" + String(localized: "herdr asks about this in a terminal. Continue there to approve it.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
        case .permissionDenied(let message):
            fail(.save, String(localized: "herdr signs in without asking for a password, so it needs a key: load yours into ssh-agent with `ssh-add`, or set this account up for key login. Then try again.", bundle: .shepherdKit) + "\n" + message, [.tryAgain, .openTerminal])
        case .failed(let message):
            fail(.save, message, [.tryAgain, .continueInTerminal])
        case .stopped(let timedOut):
            await checkForLateSave(stoppedByPerson: stopped && !timedOut, timedOut: timedOut)
        case nil:
            await checkForLateSave(stoppedByPerson: stopped, timedOut: false)
        }
        // Closed while saving: this was the last of it.
        if isClosed {
            onEnded?()
        }
    }

    /// After a save that was stopped, or whose end wasn't heard: whether
    /// herdr had saved the machine by then all the same.
    private func checkForLateSave(stoppedByPerson: Bool, timedOut: Bool) async {
        updateCheck(.save, detail: String(localized: "Checking whether herdr saved it anyway…", bundle: .shepherdKit))
        if let machines = try? await listMachines(),
           let machine = machines.first(where: { $0.label == label && $0.target == target }) {
            return saved(machine.id)
        }
        let message: String = if timedOut {
            String(localized: "herdr didn't finish within \(120) seconds, and was stopped. The machine wasn't saved.", bundle: .shepherdKit)
        } else if stoppedByPerson {
            String(localized: "Stopped. The machine wasn't saved.", bundle: .shepherdKit)
        } else {
            String(localized: "The host stopped answering, and the machine wasn't saved.", bundle: .shepherdKit)
        }
        setState(.save, .stopped, detail: nil)
        prompt = .problem(message: message, actions: [.tryAgain, .continueInTerminal])
    }

    private func saved(_ id: String?) {
        savedMachineID = id
        pass(.save, detail: nil)
        onMachinesChanged?()
        prompt = .finished(message: String(localized: "“\(label ?? "")” is saved in herdr on \(hostName).", bundle: .shepherdKit), actions: [.done])
    }

    /// For a machine checked again: whether herdr reaches it now.
    private func reconnect(_ machine: HerdrMachine, run id: Int) async {
        startCheck(.reconnect)
        guard let result = await runStep(HerdrMachineSteps.serverStatus(id: machine.id), for: .reconnect, run: id) else { return }
        switch HerdrMachineStatusOutcome.classify(result) {
        case .reachable:
            pass(.reconnect, detail: nil)
            onMachinesChanged?()
            prompt = .finished(message: String(localized: "herdr on \(hostName) reaches “\(machine.label)” again.", bundle: .shepherdKit), actions: [.done])
        case .needsTerminal(let message):
            fail(.reconnect, message + "\n" + String(localized: "herdr asks about this in a terminal. Continue there to approve it.", bundle: .shepherdKit), [.continueInTerminal, .tryAgain])
        case .failed(let message):
            fail(.reconnect, message, [.tryAgain, .openTerminal])
        }
    }

    /// The command for what only a person at a terminal can answer: adding
    /// the machine there — herdr asks about installing itself, OpenSSH
    /// about keys — or, for a saved one, herdr's own way of setting it up
    /// again (`saved_ssh_bootstrap_command`, herdr 0.9.1).
    public var terminalHandoff: TerminalHandoff {
        switch mode {
        case .add:
            let label = label ?? ""
            return TerminalHandoff(tabName: String(localized: "Add \(label)", bundle: .shepherdKit),
                                   argv: ["herdr", "machine", "add", target ?? "", "--label", label])
        case .reconnect(let machine):
            return TerminalHandoff(tabName: String(localized: "Reconnect \(machine.label)", bundle: .shepherdKit),
                                   argv: ["herdr", "--remote", machine.target, "--session", machine.session])
        }
    }

    private func handOff(_ handoff: TerminalHandoff) {
        guard let onTerminal else { return }
        let previous = prompt
        prompt = nil
        Task {
            do {
                try await onTerminal(handoff)
                didHandOff = true
                close()
            } catch {
                let actions = previous?.actions ?? [.tryAgain]
                prompt = .problem(message: String(localized: "Couldn't open a tab on \(hostName): \(connectionFailureDescription(error))", bundle: .shepherdKit), actions: actions)
            }
        }
    }

    /// Runs `step` for `kind`. Nil, with the check failed, when the host
    /// couldn't run it; nil without a word when the checks have moved on.
    private func runStep(_ step: HostStep, for kind: CheckKind, run id: Int) async -> HostStepResult? {
        do {
            let result = try await runner.run(step)
            guard isCurrent(id) else { return nil }
            return result
        } catch {
            guard isCurrent(id) else { return nil }
            fail(kind, connectionFailureDescription(error), [.tryAgain])
            return nil
        }
    }

    // MARK: The checks' rows

    private func startCheck(_ kind: CheckKind) {
        setState(kind, .running(since: Date()), detail: nil)
    }

    private func pass(_ kind: CheckKind, detail: String?) {
        setState(kind, .passed, detail: detail)
    }

    private func fail(_ kind: CheckKind, _ message: String, _ actions: [Action]) {
        setState(kind, .failed, detail: nil)
        for index in checks.indices {
            if case .running = checks[index].state { checks[index].state = .pending }
        }
        prompt = .problem(message: message, actions: actions)
    }

    private func setState(_ kind: CheckKind, _ state: CheckState, detail: String?) {
        guard let index = checks.firstIndex(where: { $0.kind == kind }) else { return }
        checks[index].state = state
        checks[index].detail = detail
    }

    private func updateCheck(_ kind: CheckKind, detail: String?) {
        guard let index = checks.firstIndex(where: { $0.kind == kind }) else { return }
        checks[index].detail = detail
    }

    // MARK: Host aliases

    /// Reads the Host aliases of the host's ~/.ssh/config and of the files
    /// it includes, three levels deep — only reads them.
    private func loadHostAliases() async {
        var patterns = ["~/.ssh/config"]
        var read: Set<String> = []
        var hosts: [String] = []
        for _ in 0...3 where !patterns.isEmpty {
            guard let result = try? await runner.run(SSHSteps.readFiles(patterns)), result.status == 0, !Task.isCancelled else { break }
            var next: [String] = []
            for file in SSHSteps.parseFiles(result.stdoutText) where !read.contains(file.path) {
                read.insert(file.path)
                let parsed = SSHConfigHosts.parse(file.content)
                for host in parsed.hosts where !hosts.contains(host) { hosts.append(host) }
                next += parsed.includes
            }
            patterns = next
        }
        guard !Task.isCancelled else { return }
        hostAliases = hosts
    }

    // MARK: Rules

    /// The herdr session a machine added here is for: herdr's default.
    public static let defaultSession = "default"

    /// Why `target` can't be added as it is, or nil. herdr 0.9.1's own rules
    /// for a target (`SavedSshEndpoint::validate`), and no target saved
    /// already for the same session.
    public static func targetProblem(_ target: String, saved: [HerdrMachine]) -> String? {
        if target.isEmpty {
            return String(localized: "Type an SSH target: a Host alias, user@host or ssh://user@host:port.", bundle: .shepherdKit)
        }
        if target.hasPrefix("-") {
            return String(localized: "An SSH target can't start with “-”.", bundle: .shepherdKit)
        }
        if target.contains(where: { $0.isWhitespace }) || target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return String(localized: "An SSH target can't have spaces in it.", bundle: .shepherdKit)
        }
        if target.utf8.count > 1024 {
            return String(localized: "That SSH target is too long.", bundle: .shepherdKit)
        }
        let authority = target.hasPrefix("ssh://") ? String(target.dropFirst(6)) : target
        if let at = authority.lastIndex(of: "@"), authority[..<at].contains(":") {
            return String(localized: "Leave the password out of the target: herdr signs in with keys only.", bundle: .shepherdKit)
        }
        if let existing = saved.first(where: { $0.target == target && $0.session == defaultSession }) {
            return String(localized: "This target is saved already, as “\(existing.label)”.", bundle: .shepherdKit)
        }
        return nil
    }

    /// Why `label` can't name a new machine, or nil: herdr's rules for a
    /// label, and none saved already under it — a disabled machine's
    /// included — or under it as an ID.
    public static func labelProblem(_ label: String, saved: [HerdrMachine]) -> String? {
        if label.isEmpty {
            return String(localized: "Type a name.", bundle: .shepherdKit)
        }
        if label.utf8.count > 128 {
            return String(localized: "That name is too long.", bundle: .shepherdKit)
        }
        if label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return String(localized: "A name can't have control characters in it.", bundle: .shepherdKit)
        }
        if saved.contains(where: { $0.label == label || $0.id == label }) {
            return String(localized: "Another machine is called “\(label)” already.", bundle: .shepherdKit)
        }
        return nil
    }

    /// The target's host — an alias as it is — made unlike every saved
    /// name with a number after it.
    public static func suggestedLabel(for target: String, saved: [HerdrMachine]) -> String {
        var host = target.hasPrefix("ssh://") ? String(target.dropFirst(6)) : target
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        if host.isEmpty { host = target }
        let taken = Set(saved.map(\.label))
        guard taken.contains(host) else { return host }
        var number = 2
        while taken.contains("\(host) \(number)") { number += 1 }
        return "\(host) \(number)"
    }
}
