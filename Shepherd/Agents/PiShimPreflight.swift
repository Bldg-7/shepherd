import Foundation

/// Checks, before a managed Pi launch creates its pane, that the shell herdr
/// will type `pi` into finds Shepherd's session shim and not some other `pi`.
///
/// `stagePi` puts the shim's folder at the front of the PATH the new pane's
/// shell starts with (`PiStagedLaunch.environment`). But the shell is an
/// interactive one, and its startup files run before herdr types anything:
/// a `~/.zshrc` that puts `~/.bun/bin` or `~/.local/bin` ahead of PATH again
/// makes `pi` the CLI installed there, and the shim never runs. The launch
/// then goes on for 20 seconds before it fails with
/// `pi-foreground-binding-lost`, which says nothing about why — and the
/// pane, kept as every failed launch's pane is, shows that failure for as
/// long as it lives.
///
/// So the same question is put to the same kind of shell first: an
/// interactive login shell, started with the staged PATH, is asked what
/// `command -v pi` finds. Anything but the shim refuses the launch at once,
/// with the path that was found, before there is a pane to keep.
nonisolated enum PiShimPreflight {
    /// The reason code in the refusal, for the diagnostics and the docs.
    static let rejectionCode = "pi-shim-shadowed-by-shell-path"

    /// The command `sh -c` runs (see `HerdrTransport.runScript`): the login
    /// shell, interactive so that its startup files run as they will in the
    /// pane, started with the staged `path`, printing what it finds for
    /// `pi`. `exec` so that the shell's exit status is the script's: a shell
    /// that finds no `pi` at all fails the script, and `runScript` reports
    /// its stderr.
    static func script(path: String, shell: String) -> String {
        "PATH=\(shellQuoted(path)) exec \(shellQuoted(shell)) -ic 'command -v pi'"
    }

    /// What the shell found: the last line it printed that isn't blank.
    /// Startup files print what they like before `command -v` does, so the
    /// first line is no use.
    static func resolvedPath(in output: Data) -> String {
        String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }

    /// Throws `PiShimPreflightError` unless `output` names `shim`.
    static func check(output: Data, shim: String) throws {
        let resolved = resolvedPath(in: output)
        guard resolved == shim else { throw PiShimPreflightError(resolved: resolved, shim: shim) }
    }

    /// The account's login shell, which herdr starts in a new pane: from the
    /// password database, as `HerdrExecutable.localPath` reads the home
    /// directory, else the app's own `SHELL`, else zsh, which macOS gives
    /// new accounts.
    static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/") { return path }
        }
        if let shell = environment["SHELL"], shell.hasPrefix("/") { return shell }
        return "/bin/zsh"
    }
}

/// The shell found another `pi` than the session shim. Shown as it is, in
/// the launcher, so it names both.
nonisolated struct PiShimPreflightError: Error, LocalizedError, Equatable {
    /// What `command -v pi` printed; empty when it printed nothing.
    let resolved: String
    let shim: String

    var errorDescription: String? {
        let code = PiShimPreflight.rejectionCode
        guard !resolved.isEmpty else {
            return String(localized: "The shell finds nothing to run for pi, not even Shepherd's session shim at \(shim). A shell startup file replaces PATH, so a managed Pi launch can't go through there. (\(code))")
        }
        return String(localized: "The shell runs \(resolved) for pi, not Shepherd's session shim at \(shim). A shell startup file puts that directory ahead of PATH, so a managed Pi launch can't go through there. (\(code))")
    }
}
