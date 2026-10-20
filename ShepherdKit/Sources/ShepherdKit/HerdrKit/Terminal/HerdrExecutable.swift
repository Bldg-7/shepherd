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
public nonisolated enum HerdrExecutable {
    /// Where herdr's install script (`~/.local/bin`) and Homebrew put the
    /// binary, in the order they are tried. A path without a leading slash
    /// is relative to the home directory.
    public static let usualLocations = [".local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]

    #if os(macOS)
    /// The first usual location on this Mac holding an executable herdr.
    public static func localPath() -> String? {
        // Not `NSHomeDirectory()` first, for the same reason as
        // `LocalHerdrTransport.defaultSocketPath`: the password database has
        // the real home directory whatever the app's environment says.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return usualLocations
            .map { $0.hasPrefix("/") ? $0 : "\(home)/\($0)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    #endif

    /// The herdr configuration Shepherd's own attaches run with, and nothing
    /// else: `herdr terminal attach` turns mouse reporting on in the
    /// terminal it runs in whenever this is true (the default) or the pane's
    /// program has asked for the mouse. Off, Shepherd's terminal has mouse
    /// reporting on exactly when the pane's program does, so in a shell or
    /// a Claude Code pane a drag selects text, and in Pi or Codex it still
    /// goes to the program.
    ///
    /// It is handed to that one process through `HERDR_CONFIG_PATH`, in a
    /// file of Shepherd's own: the account's herdr configuration, herdr's
    /// own windows, its server and the panes' programs never see it, and
    /// the server's socket is found as before (`XDG_CONFIG_HOME` would move
    /// it). The attach then has herdr's defaults for everything else, as
    /// three lines per wheel notch.
    public static let attachConfiguration = "[ui]\nmouse_capture = false\n"

    /// The environment variable herdr reads its configuration file's path
    /// from.
    public static let configurationPathVariable = "HERDR_CONFIG_PATH"

    /// Where an attach on another machine keeps `attachConfiguration`,
    /// relative to the home directory there: beside the files dropped on
    /// that machine (~/.cache/3rdr/drops).
    public static let remoteAttachConfigurationPath = ".cache/3rdr/herdr-attach.toml"

    /// A command line for the remote account's login shell that runs herdr
    /// with `arguments`, each of which must already be quoted with
    /// `shellQuoted`: from the first usual location that has it, otherwise
    /// through `zsh -ic`. `withoutMouseCapture` is for an attach (see
    /// `attachConfiguration`).
    ///
    /// The lookup runs in `sh -c` rather than in the login shell itself,
    /// so it means the same whatever that shell is (fish doesn't take POSIX
    /// `for`/`if`); `sh -c '…'` is one simple command every shell can run.
    /// That makes three layers of parsing on the fallback path — the login
    /// shell, sh, zsh — and the quoting below peels off one per layer:
    /// `arguments` is quoted for whichever shell finally runs herdr, the
    /// fallback's whole command line once more for sh, and the script once
    /// more for the login shell.
    public static func remoteCommand(arguments: String, withoutMouseCapture: Bool = false) -> String {
        "sh -c \(shellQuoted(execScript(arguments: arguments, withoutMouseCapture: withoutMouseCapture)))"
    }

    /// The lookup `remoteCommand` runs, for a POSIX shell that is already
    /// running: replaces it with herdr, run with `arguments` (quoted with
    /// `shellQuoted`, as for `remoteCommand`), and with
    /// `withoutMouseCapture`, with `attachConfigurationScript` run first.
    public static func execScript(arguments: String, withoutMouseCapture: Bool = false) -> String {
        let candidates = usualLocations
            .map { $0.hasPrefix("/") ? shellQuoted($0) : "\"$HOME\"/\(shellQuoted($0))" }
            .joined(separator: " ")
        let lookup = "for h in \(candidates); do if [ -x \"$h\" ]; then exec \"$h\" \(arguments); fi; done; exec zsh -ic \(shellQuoted("herdr \(arguments)"))"
        return withoutMouseCapture ? attachConfigurationScript + "; " + lookup : lookup
    }

    /// Puts `attachConfiguration` at `remoteAttachConfigurationPath`, if
    /// it isn't there already, and exports its path for the herdr the
    /// script goes on to start. The file is written whole under another
    /// name and then renamed, so an attach starting at the same moment
    /// reads all of it or none, and only the account can read it (umask
    /// 077, as for the drops). When it can't be written — no home
    /// directory, a full disk — nothing is exported and the attach goes on
    /// as it would without, with the mouse reporting herdr defaults to.
    ///
    /// Like the rest of `remoteCommand` it reads the same in every login
    /// shell: one line, no `!`, and no backslash pairs.
    static var attachConfigurationScript: String {
        let lines = attachConfiguration.split(separator: "\n").map { shellQuoted(String($0)) }.joined(separator: " ")
        let wanted = "\"$(cat \"$herdr_attach_config\" 2>/dev/null)\" = \"$herdr_attach_wanted\""
        return [
            "herdr_attach_wanted=$(printf '%s\\n' \(lines))",
            "herdr_attach_config=\"$HOME\"/\(shellQuoted(remoteAttachConfigurationPath))",
            "[ \(wanted) ] || (umask 077; mkdir -p \"${herdr_attach_config%/*}\" && printf '%s\\n' \"$herdr_attach_wanted\" > \"$herdr_attach_config.$$\" && mv -f \"$herdr_attach_config.$$\" \"$herdr_attach_config\" || rm -f \"$herdr_attach_config.$$\") 2>/dev/null",
            "[ \(wanted) ] && export \(configurationPathVariable)=\"$herdr_attach_config\"",
        ].joined(separator: "; ")
    }

    /// The options herdr itself gives `ssh` for a saved machine (its
    /// `apply_noninteractive_ssh_options`), so that an attach reaches a
    /// `HerdrMachine` the way herdr's own requests to it do — same keys and
    /// ~/.ssh/config, same host-key policy — and fails rather than stopping
    /// to ask for a password or to trust a new host key.
    public static let sshOptions = [
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
    public static func attachArguments(terminalID: String) -> [String] {
        ["terminal", "attach", terminalID, "--takeover"]
    }

    /// The `ssh` arguments that attach to `terminalID` on a herdr machine.
    /// herdr's `--machine` doesn't do attaches (it only carries API
    /// requests), so this goes to the machine directly: with a terminal of
    /// its own (`-tt`; an attach is a full-screen program, and ssh only sets
    /// one up for an interactive stdin otherwise), running there the same
    /// find-herdr-then-run as `remoteCommand`, in that machine's session,
    /// with the attach configuration on that machine (`withoutMouseCapture`).
    public static func sshAttachArguments(to machine: HerdrMachine, terminalID: String, withoutMouseCapture: Bool = false) -> [String] {
        let attach = (["--session", machine.session] + attachArguments(terminalID: terminalID)).map(shellQuoted)
        return ["-tt"] + sshOptions + [machine.target, remoteCommand(arguments: attach.joined(separator: " "), withoutMouseCapture: withoutMouseCapture)]
    }

    /// The command an SSH host's login shell runs to attach to
    /// `terminalID`: herdr there, in `sessionName` (empty for herdr's own
    /// "default"), or, for a pane on one of that host's herdr machines, the
    /// host's own `ssh` carrying the attach on, as it carries herdr's
    /// requests to that machine. `sessionName` is the host's session, not
    /// the machine's — `sshAttachArguments` uses the machine's own.
    ///
    /// The command goes through more than one shell before herdr sees its
    /// arguments (see `remoteCommand`), so each dynamic argument is quoted
    /// here, for the shell that finally runs herdr, and the layers above add
    /// their own. Quoting only for the outermost shell would hand the inner
    /// one the session name and terminal ID bare: a space would split the
    /// argument, and `;` or `$(…)` would run as code.
    public static func remoteAttachCommand(sessionName: String, terminalID: String, herdrMachine: HerdrMachine?, withoutMouseCapture: Bool = false) -> String {
        if let herdrMachine {
            return (["ssh"] + sshAttachArguments(to: herdrMachine, terminalID: terminalID, withoutMouseCapture: withoutMouseCapture))
                .map(shellQuoted)
                .joined(separator: " ")
        }
        var arguments: [String] = []
        if !sessionName.isEmpty {
            arguments += ["--session", shellQuoted(sessionName)]
        }
        arguments += attachArguments(terminalID: terminalID).map(shellQuoted)
        return remoteCommand(arguments: arguments.joined(separator: " "), withoutMouseCapture: withoutMouseCapture)
    }

    #if os(macOS)
    /// Puts `attachConfiguration` in `folder` on this Mac, if it isn't
    /// there already, and returns the file's path; nil when it can't be
    /// written, and the attach then goes on without it. Written whole and
    /// then moved into place, readable by this account only.
    public static func localAttachConfiguration(in folder: URL) -> String? {
        let file = folder.appending(path: "herdr-attach.toml", directoryHint: .notDirectory)
        let contents = Data(attachConfiguration.utf8)
        if (try? Data(contentsOf: file)) == contents { return file.path(percentEncoded: false) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try contents.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
        } catch {
            return nil
        }
        return file.path(percentEncoded: false)
    }

    /// Runs this Mac's herdr CLI to completion and returns its stdout (see
    /// `LocalCommand.run`).
    public static func runLocally(_ arguments: [String]) async throws -> Data {
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
