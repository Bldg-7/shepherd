import Foundation

/// One step of adding, checking or removing a herdr machine: a command run
/// on the host with `sh`, under a deadline the host keeps itself, its output
/// brought back whole however it ends.
///
/// The command runs in a subshell of a wrapper script (`script(token:)`)
/// that:
/// - takes away what could have `ssh` ask anyone anything — `DISPLAY`, and
///   `SSH_ASKPASS_REQUIRE=never` — so that a step that would need a person
///   fails instead of waiting for one;
/// - gives the command `deadline` seconds, after which it is sent TERM, and
///   KILL two seconds later, its children with it;
/// - keeps what it writes to stdout and stderr in files, and reports them
///   between marker lines, base64-encoded and cut off at a limit, with the
///   exit status — a login shell may write lines of its own around them;
/// - for `herdr machine add`, ends what herdr leaves behind when it is killed
///   (`herdrCleanupTarget`).
///
/// The wrapper always exits 0 once it has reported; whether the step
/// succeeded is in `HostStepResult`.
public nonisolated struct HostStep: Sendable, Equatable {
    /// Shell text, run with `sh` in a subshell of its own. `$step_dir` is a
    /// private folder for it, removed when the step ends.
    public var command: String
    /// Seconds the command has before it is stopped.
    public var deadline: Int
    public var stdoutLimit: Int
    public var stderrLimit: Int
    /// A path (shell text, expanded by the wrapper) to write the command's
    /// process ID to while it runs, for `HostStep.stop(pidFile:)`. Removed
    /// when the step ends.
    public var pidFile: String?
    /// The SSH target of a `herdr machine add` this step runs: when the
    /// command was killed, herdr had no chance to close the SSH connection it
    /// shares between its commands (a ControlPersist master) or to remove the
    /// `herdr-ssh-<pid>-*` folder it keeps it in, and the wrapper does.
    public var herdrCleanupTarget: String?

    public init(command: String, deadline: Int, stdoutLimit: Int = 256 * 1024, stderrLimit: Int = 64 * 1024,
                pidFile: String? = nil, herdrCleanupTarget: String? = nil) {
        self.command = command
        self.deadline = deadline
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
        self.pidFile = pidFile
        self.herdrCleanupTarget = herdrCleanupTarget
    }

    /// How long the app waits for the wrapper before giving up on the host:
    /// the deadline and fifteen seconds more, for stopping the command,
    /// cleaning up and reporting.
    public var timeout: TimeInterval {
        TimeInterval(deadline + 15)
    }

    /// The wrapper script. `token` goes into its marker lines, so that no
    /// line a login shell writes can pass for one.
    public func script(token: String) -> String {
        var lines: [String] = [
            "unset DISPLAY",
            "SSH_ASKPASS_REQUIRE=never; export SSH_ASKPASS_REQUIRE",
            "umask 077",
            "step_dir=$(mktemp -d \"${TMPDIR:-/tmp}/shepherd-step.XXXXXXXX\") || { echo 'shepherd: could not make a temporary folder' >&2; exit 70; }",
        ]
        if let pidFile {
            lines.append("step_pid_file=\(pidFile)")
            lines.append("trap 'rm -rf \"$step_dir\" \"$step_pid_file\"' EXIT")
        } else {
            lines.append("trap 'rm -rf \"$step_dir\"' EXIT")
        }
        lines += [
            // Ended from outside — the app cancelling the step on this Mac
            // signals the whole session — the EXIT trap still runs.
            "trap 'exit 143' TERM INT HUP",
            "step_signal() { pkill -\"$1\" -P \"$2\" 2>/dev/null; kill -\"$1\" \"$2\" 2>/dev/null; }",
            "(",
            command,
            ") </dev/null >\"$step_dir/out\" 2>\"$step_dir/err\" &",
            "step_pid=$!",
        ]
        if pidFile != nil {
            lines.append("printf '%s\\n' \"$step_pid\" > \"$step_pid_file\"")
        }
        lines += [
            // The watchdog. Its sleeps are ended once the command has, and a
            // sleep that ends lets it go on: so before each signal it makes
            // sure the command hasn't ended — whose process ID, reaped, may
            // be another process's by then.
            "( sleep \(deadline); [ -e \"$step_dir/done\" ] && exit 0; : > \"$step_dir/timedout\"; step_signal TERM \"$step_pid\"; sleep 2; [ -e \"$step_dir/done\" ] && exit 0; step_signal KILL \"$step_pid\" ) </dev/null >/dev/null 2>&1 &",
            "step_watchdog=$!",
            "wait \"$step_pid\"",
            "step_status=$?",
            ": > \"$step_dir/done\"",
            "pkill -P \"$step_watchdog\" 2>/dev/null; kill \"$step_watchdog\" 2>/dev/null",
        ]
        if let herdrCleanupTarget {
            lines += [
                "if [ \"$step_status\" -ge 128 ] || [ -e \"$step_dir/timedout\" ]; then",
                Self.herdrCleanup(pid: "$step_pid", target: herdrCleanupTarget),
                "fi",
            ]
        }
        lines += [
            "if command -v base64 >/dev/null 2>&1; then step_encoding=base64; step_encode() { base64 | tr -d '\\r\\n '; }",
            "else step_encoding=hex; step_encode() { od -An -v -tx1 | tr -d ' \\n'; }; fi",
            "printf '\\n%s\\n' '\(Self.beginMarker(token))'",
            "printf 'status %s\\n' \"$step_status\"",
            "if [ -e \"$step_dir/timedout\" ]; then printf 'timedout\\n'; fi",
            "printf 'stdout-size %s\\n' \"$(wc -c < \"$step_dir/out\" | tr -d ' ')\"",
            "printf 'stdout %s ' \"$step_encoding\"; head -c \(stdoutLimit) \"$step_dir/out\" | step_encode; printf '\\n'",
            "printf 'stderr-size %s\\n' \"$(wc -c < \"$step_dir/err\" | tr -d ' ')\"",
            "printf 'stderr %s ' \"$step_encoding\"; head -c \(stderrLimit) \"$step_dir/err\" | step_encode; printf '\\n'",
            "printf '%s\\n' '\(Self.endMarker(token))'",
            "exit 0",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Ends the SSH connection herdr's process `pid` (shell text) kept open
    /// to `target` and removes the folder it kept it in. herdr makes that
    /// folder `herdr-ssh-<pid>-<n>` in its temporary folder, falling back to
    /// /tmp when the path there is too long for a socket, with the socket
    /// in it called `ctl` and the SSH configuration it used, `config`
    /// (herdr 0.9.1, src/platform/unix_common.rs and src/remote/attach.rs).
    static func herdrCleanup(pid: String, target: String) -> String {
        """
        for step_base in "${TMPDIR:-/tmp}" /tmp; do
          step_base=${step_base%/}
          for step_ssh_dir in "$step_base"/herdr-ssh-\(pid)-*; do
            [ -d "$step_ssh_dir" ] || continue
            if [ -S "$step_ssh_dir/ctl" ]; then
              ssh -F "$step_ssh_dir/config" -S "$step_ssh_dir/ctl" -O exit -o BatchMode=yes \(shellQuoted(target)) </dev/null >/dev/null 2>&1
            fi
            rm -rf "$step_ssh_dir"
          done
        done
        """
    }

    /// Stops the command of a step still running with `pidFile`: TERM to it
    /// and its children, KILL two seconds later if it is still there. Does
    /// nothing once that step has ended, which removes the file — so a
    /// process ID handed on to something else since is never signalled.
    public static func stop(pidFile: String) -> HostStep {
        HostStep(command: """
            pid=$(cat \(pidFile) 2>/dev/null) || exit 0
            case $pid in ''|*[!0-9]*) exit 0 ;; esac
            pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
            for i in 1 2; do kill -0 "$pid" 2>/dev/null || exit 0; sleep 1; done
            pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
            exit 0
            """, deadline: 10)
    }

    static func beginMarker(_ token: String) -> String { "@@SHEPHERD-STEP-\(token)@@" }
    static func endMarker(_ token: String) -> String { "@@SHEPHERD-STEP-END-\(token)@@" }

    /// A token for `script(token:)`: letters and digits only.
    public static func newToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// How a `HostStep` ended, as its wrapper reported it.
public nonisolated struct HostStepResult: Sendable, Equatable {
    /// The command's exit status; 128 and up for one ended by a signal.
    public var status: Int
    /// Whether the deadline ran out, and the command was stopped for it.
    public var timedOut: Bool
    public var stdout: Data
    public var stderr: Data
    /// Whether more was written than is kept here.
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(status: Int, timedOut: Bool = false, stdout: Data = Data(), stderr: Data = Data(),
                stdoutTruncated: Bool = false, stderrTruncated: Bool = false) {
        self.status = status
        self.timedOut = timedOut
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// stderr as text, with OpenSSH's carriage returns taken out.
    public var stderrText: String { String(decoding: stderr, as: UTF8.self).replacingOccurrences(of: "\r", with: "") }

    /// The report between the markers `token` names in what the wrapper
    /// wrote, or `HostStepReportError` when there is none to be read.
    public static func parse(_ output: Data, token: String) throws -> HostStepResult {
        let text = String(decoding: output, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard let begin = lines.lastIndex(of: HostStep.beginMarker(token)),
              let end = lines[begin...].firstIndex(of: HostStep.endMarker(token)) else {
            throw HostStepReportError()
        }
        var status: Int?
        var result = HostStepResult(status: 0)
        var stdoutSize = 0
        var stderrSize = 0
        for line in lines[(begin + 1)..<end] {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch parts.first {
            case "status": status = parts.count > 1 ? Int(parts[1]) : nil
            case "timedout": result.timedOut = true
            case "stdout-size": stdoutSize = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            case "stderr-size": stderrSize = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            case "stdout": result.stdout = try decode(parts)
            case "stderr": result.stderr = try decode(parts)
            default: continue
            }
        }
        guard let status else { throw HostStepReportError() }
        result.status = status
        result.stdoutTruncated = stdoutSize > result.stdout.count
        result.stderrTruncated = stderrSize > result.stderr.count
        return result
    }

    private static func decode(_ parts: [String]) throws -> Data {
        guard parts.count >= 2 else { throw HostStepReportError() }
        let payload = parts.count > 2 ? parts[2] : ""
        switch parts[1] {
        case "base64":
            guard let data = Data(base64Encoded: payload) else { throw HostStepReportError() }
            return data
        case "hex":
            var bytes: [UInt8] = []
            bytes.reserveCapacity(payload.count / 2)
            var index = payload.startIndex
            while index < payload.endIndex {
                let next = payload.index(index, offsetBy: 2, limitedBy: payload.endIndex) ?? payload.endIndex
                guard let byte = UInt8(payload[index..<next], radix: 16) else { throw HostStepReportError() }
                bytes.append(byte)
                index = next
            }
            return Data(bytes)
        default:
            throw HostStepReportError()
        }
    }
}

/// The host ran a step's script but didn't report how it went — a login
/// shell that never ran it, say.
public nonisolated struct HostStepReportError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? {
        String(localized: "The host didn't report how the step went.", bundle: .shepherdKit)
    }
}

/// What runs `HostStep`s on a host.
public protocol HostStepRunning {
    func run(_ step: HostStep) async throws -> HostStepResult
}

/// Runs `HostStep`s with a `HerdrClient`'s `runScript`, on the host it
/// talks to.
public final class HerdrClientStepRunner: HostStepRunning {
    public let client: HerdrClient
    private let connectsFirst: Bool
    private var connecting: Task<Void, any Error>?

    /// With `connectsFirst`, the client is connected before the first step,
    /// once — again after a connection that failed — and is this runner's
    /// to `disconnect`. Without, it is the caller's, connected already.
    public init(client: HerdrClient, connectsFirst: Bool = false) {
        self.client = client
        self.connectsFirst = connectsFirst
    }

    public func run(_ step: HostStep) async throws -> HostStepResult {
        try await connect()
        let token = HostStep.newToken()
        let output = try await client.runScript(step.script(token: token), timeout: step.timeout)
        return try HostStepResult.parse(output, token: token)
    }

    /// Connects the client, for a runner that `connectsFirst`, unless it is
    /// connected already; for one that doesn't, does nothing.
    public func connect() async throws {
        guard connectsFirst else { return }
        let connecting = self.connecting ?? Task { [client] in try await client.connect() }
        self.connecting = connecting
        do {
            try await connecting.value
        } catch {
            if self.connecting == connecting { self.connecting = nil }
            throw error
        }
    }

    /// Closes the connection `run` made.
    public func disconnect() async {
        guard connectsFirst, connecting != nil else { return }
        connecting = nil
        await client.disconnect()
    }
}
