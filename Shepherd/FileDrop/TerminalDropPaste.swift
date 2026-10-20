import Foundation

/// What a file drop on a terminal turns into: the text pasted for it, and,
/// for a pane on another machine, which files go there, under what names,
/// and the command that receives each one there.
///
/// Every terminal app does a drop the same way — the files' paths, escaped
/// as a shell would need them and joined with spaces, sent as one paste —
/// and Claude Code attaches an image when a pasted path names one. A pane
/// on another machine needs a path that is valid there, so its images are
/// uploaded first (see `TerminalDropUploading`) and their paths there are
/// what gets pasted.
nonisolated enum TerminalDropPaste {
    /// The images Claude Code takes from a pasted path (its own
    /// `/\.(png|jpe?g|gif|webp)$/i`), and so the only files uploaded.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// herdr's own limit on an image it carries to another machine.
    static let maximumFileBytes: Int64 = 16 * 1024 * 1024
    static let maximumFiles = 20
    /// The longest name, before its extension, an upload is given.
    static let maximumNameLength = 80

    // MARK: - Pasting

    /// The characters a shell would take for something else, which Ghostty
    /// and iTerm2 put a backslash before in a dropped path. Claude Code
    /// takes every backslash-escape back out.
    private static let escapedCharacters: Set<Character> = [
        " ", "\\", "'", "\"", "`", "(", ")", "[", "]", "{", "}", "<", ">",
        "!", "#", "$", "&", ";", "|", "*", "?",
    ]

    /// `path` as it goes into the paste, or nil for a path with a control
    /// character in it: one of those could end the paste early (ESC is how
    /// the bracketed paste's own end marker begins) and send the rest of
    /// the path to the program as keystrokes.
    static func escaped(_ path: String) -> String? {
        guard !path.isEmpty, !containsControlCharacter(path) else { return nil }
        var result = ""
        for character in path {
            if escapedCharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The text pasted for `paths`, each already `escaped`: joined with
    /// spaces, and one after the last, as iTerm2 does, so that what is
    /// typed next doesn't run into it.
    static func pasteText(escaped paths: [String]) -> String {
        paths.joined(separator: " ") + " "
    }

    static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    // MARK: - What goes to another machine

    struct Plan: Equatable, Sendable {
        struct Upload: Equatable, Sendable {
            let url: URL
            /// The name it is given there (see `remoteName`).
            let remoteName: String
            var name: String { url.lastPathComponent }
        }
        var uploads: [Upload] = []
        /// The names of what was dropped but isn't an image: other files,
        /// and folders.
        var notImages: [String] = []
        /// The names of the images past `maximumFiles`.
        var overLimit: [String] = []
    }

    static func isImage(_ url: URL) -> Bool {
        !url.hasDirectoryPath && imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Sorts a drop on a pane on another machine into the images that are
    /// uploaded, the first `maximumFiles` of them, and the rest.
    static func plan(_ urls: [URL]) -> Plan {
        var plan = Plan()
        var taken: Set<String> = []
        for url in urls {
            if !url.isFileURL || !isImage(url) {
                plan.notImages.append(url.lastPathComponent)
            } else if plan.uploads.count == maximumFiles {
                plan.overLimit.append(url.lastPathComponent)
            } else {
                let name = remoteName(for: url.lastPathComponent, avoiding: taken)
                taken.insert(name.lowercased())
                plan.uploads.append(.init(url: url, remoteName: name))
            }
        }
        return plan
    }

    /// A name for an image there that can be passed through any shell and
    /// stand in any file system: `original` with everything but ASCII
    /// letters, digits, `.`, `_` and `-` made `_` — so a Korean name is all
    /// underscores — not starting with `.` or `-`, its extension lowercase,
    /// and numbered on when it is in `taken` (lowercased, for a file system
    /// that ignores case).
    static func remoteName(for original: String, avoiding taken: Set<String>) -> String {
        let url = URL(fileURLWithPath: original)
        let pathExtension = url.pathExtension.lowercased()
        let stem = String(original.dropLast(url.pathExtension.isEmpty ? 0 : url.pathExtension.count + 1))
        var base = String(stem.map { character -> Character in
            guard let ascii = character.asciiValue,
                  character.isLetter || character.isNumber || "._-".contains(character) else { return "_" }
            return Character(Unicode.Scalar(ascii))
        }.prefix(maximumNameLength))
        if base.isEmpty { base = "image" }
        if base.first == "." || base.first == "-" { base = "_" + base }
        let suffix = pathExtension.isEmpty ? "" : "." + pathExtension
        var candidate = base + suffix
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base)-\(number)\(suffix)"
            number += 1
        }
        return candidate
    }

    // MARK: - Receiving there

    /// Run with `sh -c` on the pane's machine, with the drop's batch (a
    /// lowercase UUID), the file's name there and its size as `$1`–`$3`, and
    /// the file's bytes on standard input. It is the same fixed text every
    /// time — only those three arguments change — and checks them again
    /// itself.
    ///
    /// The file is written to ~/.cache/3rdr/drops/<batch>/<name>, as
    /// herdr keeps the images it carries: the folders only the account's
    /// (0700), the file too (0600), and the drops folder refused if it, or
    /// the folder it is in, is a symbolic link. Until it is complete it is
    /// `<name>.part`; anything short of a complete file of the stated size
    /// — a dropped connection, a cancelled upload — is removed on the way
    /// out, the batch's folder with it if that leaves it empty. Batches over
    /// a day old are removed the next time anything is received, and so are
    /// those in ~/.cache/shepherd/drops, where earlier versions put them,
    /// with that folder itself once it is empty; nothing outside it, and
    /// nothing if it, or the folder it is in, is a symbolic link.
    ///
    /// The one line on stdout that counts is the last one starting
    /// `SHEPHERD_DROP_OK`, with the file's path: the account's shell
    /// startup files may print lines of their own.
    ///
    /// It has to read the same in every login shell the command gets
    /// through on its way to `sh`: so one line (csh takes no newline inside
    /// quotes), no `!` (csh expands history even in `csh -c`, inside single
    /// quotes too) and no backslash pairs (fish reads those inside single
    /// quotes). Hence `expr` rather than `case` with `[!…]` for the checks.
    static let receiveScript = [
        "set -u",
        "umask 077",
        "base=${HOME:?}/.cache/3rdr/drops",
        "LC_ALL=C expr \"x$1\" : 'x[0-9a-f][0-9a-f-]*$' >/dev/null || exit 64",
        "LC_ALL=C expr \"x$2\" : 'x[A-Za-z0-9_][A-Za-z0-9._-]*$' >/dev/null || exit 64",
        "LC_ALL=C expr \"x$3\" : 'x[0-9][0-9]*$' >/dev/null || exit 64",
        "mkdir -p -- \"$base\" || exit 70",
        "[ -d \"$base\" ] || exit 70",
        "[ -L \"$base\" ] && exit 70",
        "[ -L \"${base%/*}\" ] && exit 70",
        "chmod 700 \"$base\" && cd -- \"$base\" || exit 70",
        "find . -path './*' -prune -type d -mtime +0 -exec rm -rf -- {} + 2>/dev/null",
        "old=$HOME/.cache/shepherd/drops",
        "[ -L \"$old\" ] || [ -L \"${old%/*}\" ] || ( cd -- \"$old\" && find . -path './*' -prune -type d -mtime +0 -exec rm -rf -- {} + ; cd / && rmdir -- \"$old\" ) 2>/dev/null",
        "mkdir -p -- \"$1\" && cd -- \"$1\" || exit 71",
        "trap 'rm -f -- \"$2.part\"; cd .. && rmdir -- \"$1\" 2>/dev/null' EXIT",
        "[ -e \"$2\" ] && exit 72",
        "set -C",
        "cat > \"$2.part\" || exit 73",
        "n=$(wc -c < \"$2.part\" | tr -dc 0-9) && [ \"$n\" = \"$3\" ] || exit 74",
        "mv -- \"$2.part\" \"$2\" || exit 75",
        "trap - EXIT",
        "printf '%s %s/%s\\n' SHEPHERD_DROP_OK \"$(pwd)\" \"$2\"",
    ].joined(separator: "; ")

    static let receiptPrefix = "SHEPHERD_DROP_OK "

    /// The command line, for the login shell of the pane's machine, that
    /// receives one file: `receiveScript` in `sh -c`, each argument quoted.
    static func receiveCommand(batch: String, name: String, size: Int64) -> String {
        "sh -c " + [receiveScript, "3rdr-drop", batch, name, String(size)].map(shellQuoted).joined(separator: " ")
    }

    /// The `ssh` arguments that run `receive` on one of herdr's machines:
    /// with the options herdr itself reaches it with, so with the same keys
    /// and the same refusal of a host key it hasn't seen, and without a
    /// terminal, which would change the bytes on the way. `--` keeps a
    /// target from being read as an option, which `isUsableTarget` also
    /// refuses. ssh hands `receive` on to that machine's login shell as it is.
    static func sshArguments(to target: String, running receive: String) -> [String] {
        ["-T"] + HerdrExecutable.sshOptions + ["--", target, receive]
    }

    /// The command line, for the host's login shell, that receives one file
    /// on one of the host's herdr machines: the host's own `ssh` carrying
    /// `receive` on, as it carries the attach (see `TerminalSession`), with
    /// the file's bytes passed through and nothing kept on the host.
    static func hostCommand(target: String, receive: String) -> String {
        (["ssh"] + sshArguments(to: target, running: receive)).map(shellQuoted).joined(separator: " ")
    }

    /// Whether a herdr machine's target can be put on an `ssh` command
    /// line. herdr refuses all of these when a machine is saved; it is
    /// checked again because the value comes from the host.
    static func isUsableTarget(_ target: String) -> Bool {
        !target.isEmpty && target.utf8.count <= 1024 && !target.hasPrefix("-") && !containsControlCharacter(target)
    }

    /// The path the file was written to, from what `receiveScript` printed,
    /// or nil unless that is an absolute path to exactly the file asked for.
    static func receivedPath(in output: String, batch: String, name: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(receiptPrefix) }) else { return nil }
        let path = String(line.dropFirst(receiptPrefix.count))
        guard path.hasPrefix("/"), path.hasSuffix("/.cache/3rdr/drops/\(batch)/\(name)"),
              !containsControlCharacter(path) else { return nil }
        return path
    }

    /// The last line with something on it in `text`: ssh's own error, when
    /// it is ssh that failed.
    static func lastLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return containsControlCharacter(line) ? "" : String(line.prefix(300))
    }
}
