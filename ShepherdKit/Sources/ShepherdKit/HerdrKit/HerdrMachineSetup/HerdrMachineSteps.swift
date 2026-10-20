import Foundation

/// The herdr side of adding a herdr machine, removing one and checking one
/// again: `HostStep`s that run the host's herdr CLI, found the way every
/// other herdr command on the host is (`HerdrExecutable.execScript`), and
/// what their results mean.
public nonisolated enum HerdrMachineSteps {
    /// 4: `herdr machine add <target> --label <label>`, with no terminal to
    /// ask anyone anything on (120 s). herdr checks the target, has its herdr
    /// installed or replaced there if that is needed and asked for, starts its
    /// server and saves the machine — or, with no terminal, turns down
    /// whatever it would have asked about. `pidFile` is for stopping it
    /// (`HostStep.stop(pidFile:)`); killed, it leaves an SSH connection and a
    /// folder behind, which the step ends and removes.
    public static func add(target: String, label: String, pidFile: String) -> HostStep {
        HostStep(command: herdr(["machine", "add", target, "--label", label]), deadline: 120,
                 pidFile: pidFile, herdrCleanupTarget: target)
    }

    /// Where `add` keeps the process ID of its herdr: in the host's
    /// temporary folder, under a token of the attempt's own.
    public static func pidFile(token: String) -> String {
        "\"${TMPDIR:-/tmp}/shepherd-herdr-add-\(token).pid\""
    }

    /// `herdr machine remove <id>` (15 s). herdr only changes its own list;
    /// it reaches no machine.
    public static func remove(id: String) -> HostStep {
        HostStep(command: herdr(["machine", "remove", id]), deadline: 15)
    }

    /// `herdr --machine <id> status server` (25 s): whether herdr can reach
    /// a saved machine's server again.
    public static func serverStatus(id: String) -> HostStep {
        HostStep(command: herdr(["--machine", id, "status", "server"]), deadline: 25)
    }

    private static func herdr(_ arguments: [String]) -> String {
        HerdrExecutable.execScript(arguments: arguments.map(shellQuoted).joined(separator: " "))
    }

    /// herdr's own text for a failure: its stderr, without the "error: "
    /// it starts with.
    static func message(_ result: HostStepResult) -> String {
        let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
            let line = String(line)
            return line.hasPrefix("error: ") ? String(line.dropFirst(7)) : line
        }
        return lines.joined(separator: "\n")
    }
}

/// How `herdr machine add` went.
public nonisolated enum HerdrMachineAddOutcome: Sendable, Equatable {
    /// Saved, under the profile ID herdr printed, if it printed one.
    case saved(id: String?)
    /// herdr turned the target or the label down before trying anything
    /// (exit status 2).
    case invalid(String)
    /// herdr needs someone at a terminal: to approve installing or replacing
    /// herdr on the machine, or to answer a question of OpenSSH's.
    case needsTerminal(String)
    case permissionDenied(String)
    case failed(String)
    /// Stopped — by the person, or by the deadline running out.
    case stopped(timedOut: Bool)

    /// The phrases herdr 0.9.1 ends a refusal with when it would have asked
    /// a person (src/remote/attach.rs), and the one it fails with when the
    /// machine's server isn't one it can save.
    static let terminalSigns = [
        "run from an interactive terminal to approve",
        "not ready for saved machines",
        "Host key verification failed",
        "REMOTE HOST IDENTIFICATION HAS CHANGED",
        "can't be established",
        "https://",
    ]

    public static func classify(_ result: HostStepResult) -> HerdrMachineAddOutcome {
        if result.timedOut { return .stopped(timedOut: true) }
        let message = HerdrMachineSteps.message(result)
        switch result.status {
        case 0:
            return .saved(id: savedID(in: result.stdoutText))
        case 2:
            return .invalid(message)
        case 128...:
            return .stopped(timedOut: false)
        default:
            let stderr = result.stderrText
            if terminalSigns.contains(where: stderr.contains) {
                return .needsTerminal(message)
            }
            if stderr.contains("Permission denied") {
                return .permissionDenied(message)
            }
            return .failed(message.isEmpty ? String(localized: "herdr exited with status \(result.status).", bundle: .shepherdKit) : message)
        }
    }

    /// The ID in herdr's "Saved SSH machine <32 hex digits>. …".
    static func savedID(in stdout: String) -> String? {
        guard let range = stdout.range(of: "Saved SSH machine ") else { return nil }
        let id = stdout[range.upperBound...].prefix { $0.isHexDigit }
        return id.count == 32 ? String(id) : nil
    }
}

/// How `herdr machine remove` went.
public nonisolated enum HerdrMachineRemoveOutcome: Sendable, Equatable {
    case removed
    case failed(String)

    /// herdr 0.9.1 answers 0 for a machine it removed and 1 with "machine
    /// profile <id> was not found" for one it doesn't have, which is gone
    /// all the same (src/cli/machine.rs).
    public static func classify(_ result: HostStepResult) -> HerdrMachineRemoveOutcome {
        if result.timedOut {
            return .failed(String(localized: "herdr didn't finish removing the machine within \(15) seconds.", bundle: .shepherdKit))
        }
        if result.status == 0 || (result.status == 1 && result.stderrText.contains("was not found")) {
            return .removed
        }
        let message = HerdrMachineSteps.message(result)
        return .failed(message.isEmpty ? String(localized: "herdr exited with status \(result.status).", bundle: .shepherdKit) : message)
    }
}

/// How `herdr --machine <id> status server` went, checking a saved machine
/// again.
public nonisolated enum HerdrMachineStatusOutcome: Sendable, Equatable {
    case reachable
    /// herdr can reach the machine but wants its server set up again —
    /// installed, updated or restarted — which herdr asks about in a
    /// terminal.
    case needsTerminal(String)
    case failed(String)

    /// The words herdr 0.9.1 uses for a saved machine that needs a person
    /// (its `saved_ssh_failure_needs_attention`, src/remote/saved.rs), and
    /// its refusals without a terminal.
    static let attentionSigns = ["not ready", "install or update", "protocol", "handshake", "interactive terminal",
                                 "unsupported remote platform", "no matching host key"]

    public static func classify(_ result: HostStepResult) -> HerdrMachineStatusOutcome {
        if result.timedOut {
            return .failed(String(localized: "herdr didn't reach the machine within \(25) seconds.", bundle: .shepherdKit))
        }
        if result.status == 0 { return .reachable }
        let message = HerdrMachineSteps.message(result)
        let lowered = message.lowercased()
        if attentionSigns.contains(where: lowered.contains) {
            return .needsTerminal(message)
        }
        return .failed(message.isEmpty ? String(localized: "herdr exited with status \(result.status).", bundle: .shepherdKit) : message)
    }
}

/// Removes a herdr machine from the host's herdr.
public nonisolated enum HerdrMachineRemoval {
    /// Throws what herdr said when it didn't remove `machine`.
    @MainActor
    public static func remove(_ machine: HerdrMachine, using runner: some HostStepRunning) async throws {
        let result = try await runner.run(HerdrMachineSteps.remove(id: machine.id))
        if case .failed(let message) = HerdrMachineRemoveOutcome.classify(result) {
            throw HerdrCommandError(status: result.status, message: message)
        }
    }
}
