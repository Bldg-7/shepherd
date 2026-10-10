import Foundation

/// How an attach finds the herdr binary to run.
///
/// It used to always go through `zsh -ic`: a plain exec doesn't read
/// ~/.zshrc, which is often the only place herdr gets put on PATH. But an
/// interactive zsh runs the account's whole rc setup on every attach, and
/// some of that setup outlives the shell — with powerlevel10k, every attach
/// left an idle zsh behind, reparented to launchd, for good, on this Mac and
/// on the far end of SSH alike. So the places herdr is normally installed
/// are tried first and herdr is started directly from there; the
/// interactive shell is only the fallback for an install somewhere else.
nonisolated enum HerdrExecutable {
    /// Where herdr's install script (`~/.local/bin`) and Homebrew put the
    /// binary, in the order they are tried. A path without a leading slash
    /// is relative to the home directory.
    static let usualLocations = [".local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]

    #if os(macOS)
    /// The first usual location on this Mac holding an executable herdr.
    static func localPath() -> String? {
        // Not `NSHomeDirectory()` first, for the same reason as
        // `LocalHerdrTransport.defaultSocketPath`: the password database has
        // the real home directory whatever the app's environment says.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return usualLocations
            .map { $0.hasPrefix("/") ? $0 : "\(home)/\($0)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    #endif

    /// A command line for the remote account's login shell that runs herdr
    /// with `arguments`, each of which must already be quoted with
    /// `shellQuoted`: from the first usual location that has it, otherwise
    /// through `zsh -ic`.
    ///
    /// The lookup runs in `sh -c` rather than in the login shell itself,
    /// so it means the same whatever that shell is (fish doesn't take POSIX
    /// `for`/`if`); `sh -c '…'` is one simple command every shell can run.
    /// That makes three layers of parsing on the fallback path — the login
    /// shell, sh, zsh — and the quoting below peels off one per layer:
    /// `arguments` is quoted for whichever shell finally runs herdr, the
    /// fallback's whole command line once more for sh, and the script once
    /// more for the login shell.
    static func remoteCommand(arguments: String) -> String {
        let candidates = usualLocations
            .map { $0.hasPrefix("/") ? shellQuoted($0) : "\"$HOME\"/\(shellQuoted($0))" }
            .joined(separator: " ")
        let script = "for h in \(candidates); do if [ -x \"$h\" ]; then exec \"$h\" \(arguments); fi; done; exec zsh -ic \(shellQuoted("herdr \(arguments)"))"
        return "sh -c \(shellQuoted(script))"
    }

    /// The options herdr itself gives `ssh` for a saved machine (its
    /// `apply_noninteractive_ssh_options`), so that an attach reaches a
    /// `HerdrMachine` the way herdr's own requests to it do — same keys and
    /// ~/.ssh/config, same host-key policy — and fails rather than stopping
    /// to ask for a password or to trust a new host key.
    static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
    ]

    /// The herdr arguments that attach to a pane's terminal and take it over
    /// — `terminal attach` rather than `agent attach`, which only reaches a
    /// terminal by way of the agent in its pane, and so not at all in a pane
    /// that has none. Unquoted; a caller that hands them to a shell quotes
    /// them for it.
    static func attachArguments(terminalID: String) -> [String] {
        ["terminal", "attach", terminalID, "--takeover"]
    }

    /// The `ssh` arguments that attach to `terminalID` on a herdr machine.
    /// herdr's `--machine` doesn't do attaches (it only carries API
    /// requests), so this goes to the machine directly: with a terminal of
    /// its own (`-tt`; an attach is a full-screen program, and ssh only sets
    /// one up for an interactive stdin otherwise), running there the same
    /// find-herdr-then-run as `remoteCommand`, in that machine's session.
    static func sshAttachArguments(to machine: HerdrMachine, terminalID: String) -> [String] {
        let attach = (["--session", machine.session] + attachArguments(terminalID: terminalID)).map(shellQuoted)
        return ["-tt"] + sshOptions + [machine.target, remoteCommand(arguments: attach.joined(separator: " "))]
    }

    #if os(macOS)
    /// Runs this Mac's herdr CLI to completion and returns its stdout (see
    /// `LocalCommand.run`).
    static func runLocally(_ arguments: [String]) async throws -> Data {
        let command: LocalCommand.Command
        if let herdr = localPath() {
            command = .init(executable: URL(fileURLWithPath: herdr), arguments: arguments)
        } else {
            command = .init(executable: URL(fileURLWithPath: "/bin/zsh"),
                            arguments: ["-ic", (["herdr"] + arguments.map(shellQuoted)).joined(separator: " ")])
        }
        return try await LocalCommand.run(command) { status, stderr in
            HerdrCommandError(status: status, message: stderr)
        }
    }
    #endif
}
