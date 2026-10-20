import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// The SSH side of adding a herdr machine, done on the host with its own
// OpenSSH and ~/.ssh: what a target resolves to, signing in to it the way
// herdr will once the machine is saved, and fetching its host key for the
// person to trust. The steps are `HostStep`s; what comes back is read here.

/// What `ssh -G <target>` says the host's OpenSSH will do for a target.
public nonisolated struct SSHResolvedConfig: Sendable, Equatable {
    public var hostname: String
    public var user: String?
    public var port: Int
    public var proxyJump: String?
    public var proxyCommand: String?
    public var hostKeyAlias: String?
    /// Where the person's known host keys are, first the one OpenSSH adds
    /// new ones to. As `ssh -G` prints them: OpenSSH 10 expands `~` to the
    /// home folder, older versions leave it.
    public var userKnownHostsFiles: [String]
    public var remoteCommand: String?

    /// Reads the output of `ssh -G`: one lowercased keyword and its value a
    /// line.
    public static func parse(_ output: String) -> SSHResolvedConfig? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if values[key] == nil {
                values[key] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let hostname = values["hostname"], !hostname.isEmpty else { return nil }
        func meaningful(_ key: String) -> String? {
            guard let value = values[key], !value.isEmpty, value.lowercased() != "none" else { return nil }
            return value
        }
        return SSHResolvedConfig(
            hostname: hostname,
            user: meaningful("user"),
            port: values["port"].flatMap(Int.init) ?? 22,
            proxyJump: meaningful("proxyjump"),
            proxyCommand: meaningful("proxycommand"),
            hostKeyAlias: meaningful("hostkeyalias"),
            userKnownHostsFiles: (values["userknownhostsfile"] ?? "").split(separator: " ").map(String.init),
            remoteCommand: meaningful("remotecommand")
        )
    }

    /// The names OpenSSH looks the target's host key up by, and names in
    /// its messages about it: the HostKeyAlias if there is one, otherwise
    /// the host name — in brackets with the port, for a port other than 22.
    public var hostKeyNames: Set<String> {
        if let hostKeyAlias { return [hostKeyAlias.lowercased()] }
        let host = hostname.lowercased()
        return port == 22 ? [host] : ["[\(host)]:\(port)", host]
    }

    /// The name the target's key is under in known_hosts, as
    /// `ssh-keygen -R` takes it.
    public var knownHostsName: String {
        if let hostKeyAlias { return hostKeyAlias }
        return port == 22 ? hostname : "[\(hostname)]:\(port)"
    }

    /// The known_hosts file a new key goes into: the first one named.
    public var knownHostsFile: String? {
        userKnownHostsFiles.first
    }

    /// Where the target is, for the person: `user@host`, the port when it
    /// isn't 22, and the jump host it is reached through.
    public var destination: String {
        var text = (user.map { "\($0)@" } ?? "") + hostname
        if port != 22 { text += ":\(port)" }
        if let proxyJump {
            text += " " + String(localized: "via \(proxyJump)", bundle: .shepherdKit)
        } else if proxyCommand != nil {
            text += " " + String(localized: "via a ProxyCommand", bundle: .shepherdKit)
        }
        return text
    }

    /// Why herdr could never use the target as OpenSSH resolves it, or nil
    /// when it could.
    public var blocker: String? {
        if remoteCommand != nil {
            return String(localized: "OpenSSH's configuration gives this target a RemoteCommand, which leaves herdr no way to run its own commands there. Use a Host alias without one.", bundle: .shepherdKit)
        }
        if userKnownHostsFiles.isEmpty || userKnownHostsFiles.allSatisfy({ $0 == "/dev/null" }) {
            return String(localized: "OpenSSH's configuration keeps no known host keys for this target (UserKnownHostsFile /dev/null), so herdr's strict host key checking could never pass.", bundle: .shepherdKit)
        }
        return nil
    }
}

/// What the probe run on the target after signing in found there.
public nonisolated struct SSHProbe: Sendable, Equatable {
    public var system: String?
    public var architecture: String?
    /// Where herdr is on the target, or nil when it isn't there.
    public var herdrPath: String?
    public var herdrVersion: String?

    static let beginMarker = "@@SHEPHERD-PROBE@@"
    static let endMarker = "@@SHEPHERD-PROBE-END@@"

    /// The probe, for the target's login shell to run in `sh`: the system,
    /// where herdr is — in the places herdr's own install and Homebrew put
    /// it, then on PATH — and what version it says it is.
    static var script: String {
        """
        printf '%s\\n' '\(beginMarker)'
        printf 'system %s\\n' "$(uname -s 2>/dev/null)"
        printf 'architecture %s\\n' "$(uname -m 2>/dev/null)"
        h=
        for c in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do if [ -x "$c" ]; then h=$c; break; fi; done
        [ -n "$h" ] || h=$(command -v herdr 2>/dev/null)
        printf 'herdr %s\\n' "$h"
        if [ -n "$h" ]; then printf 'client '; "$h" status client --json 2>/dev/null | tr -d '\\r\\n'; printf '\\n'; fi
        printf '%s\\n' '\(endMarker)'
        exit 0
        """
    }

    public static func parse(_ output: String) -> SSHProbe? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let begin = lines.lastIndex(of: beginMarker),
              let end = lines[begin...].firstIndex(of: endMarker) else { return nil }
        var probe = SSHProbe()
        for line in lines[(begin + 1)..<end] {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch parts[0] {
            case "system": probe.system = value
            case "architecture": probe.architecture = value
            case "herdr": probe.herdrPath = value
            case "client":
                if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                   let version = object["version"] as? String, !version.isEmpty {
                    probe.herdrVersion = version
                }
            default: continue
            }
        }
        return probe
    }

    /// The probe's findings in a line.
    public var summary: String {
        let platform = [system, architecture].compactMap { $0 }.joined(separator: " ")
        let herdr: String
        if let herdrPath {
            herdr = herdrVersion.map { String(localized: "herdr \($0)", bundle: .shepherdKit) } ?? String(localized: "herdr at \(herdrPath)", bundle: .shepherdKit)
        } else {
            herdr = String(localized: "herdr isn't installed there yet", bundle: .shepherdKit)
        }
        return platform.isEmpty ? herdr : "\(herdr) · \(platform)"
    }
}

/// How signing in to a target went, from the step `SSHSteps.signIn`.
public nonisolated enum SSHSignInOutcome: Sendable, Equatable {
    case signedIn(SSHProbe)
    /// OpenSSH knows no key for the target and was told not to take one on
    /// trust: `host` is the name it gave.
    case unknownHostKey(host: String)
    /// A jump host's — or a ProxyCommand's — host key isn't known; that one
    /// is checked by an `ssh` of its own, which takes no options from here.
    case jumpHostKey(String)
    /// The target's key isn't the one known for it.
    case changedHostKey(String)
    case revokedHostKey(String)
    /// Some other host key failure.
    case otherHostKey(String)
    /// No key or agent got the target to let the account in.
    case permissionDenied(String)
    /// Signing in wants a browser: Tailscale SSH's check mode, say.
    case authenticationURL(String)
    case network(String)
    case remoteCommand(String)
    case timedOut
    case failed(String)

    /// Reads the result of signing in. `hostKeyNames` are the names the
    /// target's own key is known by (`SSHResolvedConfig.hostKeyNames`): a
    /// key message about any other host is a jump host's.
    ///
    /// The messages are OpenSSH's (10.3; their wording has been the same
    /// since 7.x): sshconnect.c's host key checks, and the client's
    /// "Permission denied (…)." and connect errors.
    public static func classify(_ result: HostStepResult, hostKeyNames: Set<String>) -> SSHSignInOutcome {
        let stderr = result.stderrText
        let message = summary(stderr)
        if result.status == 0, !result.timedOut, let probe = SSHProbe.parse(result.stdoutText) {
            return .signedIn(probe)
        }
        // Tailscale SSH's check mode, for one, writes the address to visit
        // and then waits for it to be visited — past the deadline.
        if result.timedOut {
            return firstURL(in: stderr).map(SSHSignInOutcome.authenticationURL) ?? .timedOut
        }
        if stderr.contains("REVOKED HOST KEY") || stderr.contains("is marked as revoked") || stderr.contains("was revoked") {
            return .revokedHostKey(message)
        }
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || stderr.contains("has changed and you have requested strict checking") {
            return .changedHostKey(message)
        }
        if let host = unknownKeyHost(in: stderr) {
            return hostKeyNames.contains(host.lowercased()) ? .unknownHostKey(host: host) : .jumpHostKey(message)
        }
        if stderr.contains("can't be established") {
            return .jumpHostKey(message)
        }
        if stderr.contains("Host key verification failed") {
            return .otherHostKey(message)
        }
        if stderr.contains("Permission denied") || stderr.contains("Too many authentication failures") {
            return .permissionDenied(message)
        }
        if stderr.contains("Cannot execute command-line and remote command") {
            return .remoteCommand(message)
        }
        let networkSigns = ["Could not resolve hostname", "connect to host", "Connection refused", "Connection timed out",
                            "Operation timed out", "No route to host", "Network is unreachable", "Connection closed by",
                            "Connection reset", "kex_exchange_identification", "banner exchange", "Broken pipe",
                            "Stdio forwarding failed", "open failed"]
        if networkSigns.contains(where: stderr.contains) {
            return .network(message)
        }
        // Last of all, as a server's login banner may carry an address too.
        if let url = firstURL(in: stderr) {
            return .authenticationURL(url)
        }
        if result.status == 0 {
            return .failed(String(localized: "Signed in, but the target didn't run the check that reads where herdr is.", bundle: .shepherdKit))
        }
        return .failed(message.isEmpty ? String(localized: "ssh exited with status \(result.status).", bundle: .shepherdKit) : message)
    }

    /// The host in "No ED25519 host key is known for <host> and you have
    /// requested strict checking."
    static func unknownKeyHost(in stderr: String) -> String? {
        for line in stderr.split(whereSeparator: \.isNewline) {
            guard let known = line.range(of: " host key is known for "),
                  let strict = line.range(of: " and you have requested strict checking", range: known.upperBound..<line.endIndex),
                  line.hasPrefix("No ") else { continue }
            return String(line[known.upperBound..<strict.lowerBound])
        }
        return nil
    }

    static func firstURL(in text: String) -> String? {
        guard let start = text.range(of: "https://") else { return nil }
        let rest = text[start.lowerBound...]
        let end = rest.firstIndex(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) ?? rest.endIndex
        return String(rest[..<end])
    }

    /// What ssh said, without the banner lines of its key warnings.
    static func summary(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "@" } }
            .filter { !$0.hasPrefix("@") || !$0.hasSuffix("@") }
        return lines.suffix(6).joined(separator: "\n")
    }
}

/// A host key as OpenSSH writes it into known_hosts.
public nonisolated struct KnownHostLine: Sendable, Equatable {
    /// The whole line, as it goes into the file.
    public let line: String
    /// The host field: names, or a hashed `|1|…` entry.
    public let hosts: String
    /// The key's type as written: `ssh-ed25519`, `ecdsa-sha2-nistp256`, ….
    public let keyType: String
    public let keyBlob: Data

    /// The first key line in a known_hosts file's text: comments, blank
    /// lines and `@cert-authority` or `@revoked` lines are passed over.
    public static func first(in text: String) -> KnownHostLine? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("@") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3, let blob = Data(base64Encoded: fields[2]), !blob.isEmpty,
                  blobKeyType(blob) == fields[1] else { continue }
            return KnownHostLine(line: line, hosts: fields[0], keyType: fields[1], keyBlob: blob)
        }
        return nil
    }

    /// The type the key blob names itself: its first SSH string.
    static func blobKeyType(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count >= 4 else { return nil }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, 4 + length <= bytes.count else { return nil }
        return String(bytes: bytes[4..<(4 + length)], encoding: .utf8)
    }

    /// The fingerprint as OpenSSH shows it: `SHA256:` and the base64 of the
    /// blob's SHA-256, without padding — 43 characters.
    public var fingerprint: String {
        "SHA256:" + Data(SHA256Digest.hash(keyBlob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// The key's type as `ssh-keygen -l` names it: ED25519, ECDSA, RSA, ….
    public var displayType: String {
        switch keyType {
        case "ssh-ed25519": "ED25519"
        case "sk-ssh-ed25519@openssh.com": "ED25519-SK"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA-SK"
        default: keyType.hasPrefix("ecdsa-sha2-") ? "ECDSA" : keyType
        }
    }
}

/// What the person is asked to trust: the target's host key, as fetched.
public nonisolated struct HostKeyApproval: Sendable, Equatable {
    /// The machine's label, as the person named it.
    public let label: String
    public let destination: String
    public let key: KnownHostLine
    /// The known_hosts file on the host the key goes into, as the person
    /// would write it.
    public let file: String
    /// The host's name: "This Mac" or the SSH host's.
    public let hostName: String
}

/// The `HostStep`s of adding a herdr machine, and of checking one again.
public nonisolated enum SSHSteps {
    /// The options herdr gives `ssh` for a saved machine
    /// (`apply_noninteractive_ssh_options`, herdr 0.9.1): signing in with
    /// these is signing in the way herdr will.
    public static let herdrOptions = [
        "-o", "BatchMode=yes",
        "-o", "NumberOfPasswordPrompts=0",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ConnectionAttempts=1",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=4",
    ]

    /// 1: what OpenSSH resolves the target to (10 s).
    public static func resolve(_ target: String) -> HostStep {
        HostStep(command: "exec ssh -G \(shellQuoted(target))", deadline: 10)
    }

    /// 2: signs in the way herdr will, and runs `SSHProbe.script` (25 s).
    public static func signIn(_ target: String) -> HostStep {
        let remote = "sh -c \(shellQuoted(SSHProbe.script))"
        let words = ["ssh", "-T"] + herdrOptions + [target, remote]
        return HostStep(command: "exec " + words.map(shellQuoted).joined(separator: " "), deadline: 25)
    }

    /// 2b: has OpenSSH take the target's host key into a known_hosts file
    /// of the step's own — `StrictHostKeyChecking=accept-new` — and prints
    /// it (25 s). Every way of logging in is switched off: the key comes
    /// before any of them, and nothing is logged in to. Unlike `ssh-keyscan`,
    /// this goes where the person's own configuration says — HostName, Port,
    /// ProxyJump — and writes the line the way it would: under the
    /// HostKeyAlias, hashed if HashKnownHosts says so. One key, the one
    /// agreed on, and no IP address line or other keys of the host's
    /// (`CheckHostIP=no`, `UpdateHostKeys=no`); a new connection rather than
    /// one already open (`ControlPath=none`).
    public static func fetchHostKey(_ target: String) -> HostStep {
        let options = [
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "CheckHostIP=no",
            "-o", "UpdateHostKeys=no",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "HostbasedAuthentication=no",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
        ]
        let words = (["ssh", "-T"] + options).map(shellQuoted).joined(separator: " ")
        return HostStep(command: """
            kh="$step_dir/known_hosts"
            : > "$kh"
            \(words) -o "UserKnownHostsFile=\\"$kh\\"" \(shellQuoted(target)) exit
            s=$?
            cat "$kh"
            exit $s
            """, deadline: 25)
    }

    /// 2c: adds `line` to the known_hosts file `file` (as `ssh -G` printed
    /// it) the way OpenSSH adds one (10 s): appended — the file is opened
    /// for appending and never replaced, so a symbolic link stays one and
    /// the owner and mode stay as they are — after a newline if the file
    /// doesn't end with one, unless the line is there already. A missing
    /// ~/.ssh is made, private; a file that can't be written to is left
    /// alone and said so. Nil for a path that isn't the home folder's or
    /// absolute — one with tokens of OpenSSH's own in it, say.
    public static func appendKnownHost(_ line: String, to file: String) -> HostStep? {
        guard let path = shellPath(file) else { return nil }
        return HostStep(command: """
            f=\(path)
            line=\(shellQuoted(line))
            d=${f%/*}
            [ -n "$d" ] || d=/
            if [ ! -d "$d" ]; then
              if [ "$d" = "$HOME/.ssh" ]; then
                mkdir -m 700 "$d" || exit 3
              else
                printf '%s\\n' "$d doesn't exist." >&2
                exit 4
              fi
            fi
            if [ -e "$f" ]; then
              if grep -qxF -- "$line" "$f" 2>/dev/null; then
                printf 'present\\n'
                exit 0
              fi
              if [ ! -w "$f" ]; then
                printf '%s\\n' "$f can't be written to." >&2
                exit 5
              fi
              if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then
                printf '\\n' >> "$f" || exit 6
              fi
            elif [ ! -w "$d" ]; then
              printf '%s\\n' "$d can't be written to." >&2
              exit 5
            fi
            printf '%s\\n' "$line" >> "$f" || exit 6
            printf 'added\\n'
            """, deadline: 10)
    }

    /// `file` for the shell: a path in the home folder as `"$HOME"/'…'`,
    /// an absolute one quoted. Nil for anything else, and for a path with
    /// OpenSSH's own tokens (`%h`, …) in it.
    static func shellPath(_ file: String) -> String? {
        guard !file.isEmpty, !file.contains("%"), !file.contains("\n") else { return nil }
        if file == "~" { return "\"$HOME\"" }
        if file.hasPrefix("~/") { return "\"$HOME\"/" + shellQuoted(String(file.dropFirst(2))) }
        if file.hasPrefix("/") { return shellQuoted(file) }
        return nil
    }

    /// Reads the files `patterns` name — each relative to the home folder or
    /// absolute, globs and all — and prints each as `@@FILE <path base64>`
    /// and its content in base64 on the next line, up to 256 KiB (10 s).
    public static func readFiles(_ patterns: [String]) -> HostStep {
        let words = patterns.compactMap { pattern -> String? in
            guard !pattern.contains("\n") else { return nil }
            if pattern.hasPrefix("~/") { return "\"$HOME\"/" + shellQuoted(String(pattern.dropFirst(2))) }
            if pattern.hasPrefix("/") { return shellQuoted(pattern) }
            return "\"$HOME\"/.ssh/" + shellQuoted(pattern)
        }
        // A pattern is expanded unquoted, for its globs, with only a newline
        // to split words on, so that a space in a path stays in it.
        return HostStep(command: """
            IFS='
            '
            for p in \(words.joined(separator: " ")); do
              for f in $p; do
                [ -f "$f" ] && [ -r "$f" ] || continue
                printf '@@FILE %s\\n' "$(printf '%s' "$f" | base64 | tr -d '\\r\\n')"
                head -c 262144 "$f" | base64 | tr -d '\\r\\n'
                printf '\\n'
              done
            done
            exit 0
            """, deadline: 10, stdoutLimit: 2 * 1024 * 1024)
    }

    /// The files `readFiles` printed, by path.
    public static func parseFiles(_ output: String) -> [(path: String, content: String)] {
        var files: [(path: String, content: String)] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("@@FILE "), index + 1 < lines.count,
               let path = Data(base64Encoded: String(line.dropFirst(7))),
               let content = Data(base64Encoded: lines[index + 1]) {
                files.append((String(decoding: path, as: UTF8.self), String(decoding: content, as: UTF8.self)))
                index += 2
            } else {
                index += 1
            }
        }
        return files
    }
}

/// The Host aliases in an OpenSSH client configuration, and the files it
/// includes.
public nonisolated enum SSHConfigHosts {
    /// The aliases `Host` lines name in `text` — patterns (`*`, `?`) and
    /// negations (`!`) left out — and the paths its `Include` lines name.
    public static func parse(_ text: String) -> (hosts: [String], includes: [String]) {
        var hosts: [String] = []
        var includes: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            guard !line.isEmpty else { continue }
            let words = arguments(line)
            guard let keyword = words.first?.lowercased() else { continue }
            let values = Array(words.dropFirst())
            switch keyword {
            case "host":
                for value in values where !value.contains("*") && !value.contains("?") && !value.hasPrefix("!") {
                    if !hosts.contains(value) { hosts.append(value) }
                }
            case "include":
                includes += values
            default:
                continue
            }
        }
        return (hosts, includes)
    }

    /// A line's words, as OpenSSH splits them: on whitespace, and on the
    /// first `=` after the keyword; double quotes keep a word together.
    static func arguments(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var hasWord = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                hasWord = true
            } else if !quoted && (character == " " || character == "\t" || (character == "=" && words.isEmpty)) {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        return words
    }
}

/// SHA-256, from CryptoKit, which both platforms have.
nonisolated enum SHA256Digest {
    static func hash(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}
