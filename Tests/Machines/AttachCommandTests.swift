import Foundation
import Darwin

/// How Shepherd starts `herdr terminal attach` (SHPHRD-93): with
/// `HERDR_CONFIG_PATH` pointing at a file of Shepherd's own that turns mouse
/// capture off, for its attaches only. The remote command is run for real in
/// the login shells this Mac has, with a HOME of the test's own and a fake
/// herdr standing first in herdr's usual locations; nothing else runs. No
/// SSH, no real herdr, no user files.
@main enum AttachCommandTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: @autoclosure () -> String) { precondition(condition, why()); checks += 1 }

    /// `HerdrExecutable.execScript` as it was before SHPHRD-93.
    static func oldExecScript(arguments: String) -> String {
        let candidates = HerdrExecutable.usualLocations
            .map { $0.hasPrefix("/") ? shellQuoted($0) : "\"$HOME\"/\(shellQuoted($0))" }
            .joined(separator: " ")
        return "for h in \(candidates); do if [ -x \"$h\" ]; then exec \"$h\" \(arguments); fi; done; exec zsh -ic \(shellQuoted("herdr \(arguments)"))"
    }

    /// `TerminalSession`'s command for a host's own herdr as it was before.
    static func oldHostCommand(sessionName: String, terminalID: String) -> String {
        var arguments: [String] = []
        if !sessionName.isEmpty { arguments += ["--session", shellQuoted(sessionName)] }
        arguments += HerdrExecutable.attachArguments(terminalID: terminalID).map(shellQuoted)
        return "sh -c \(shellQuoted(oldExecScript(arguments: arguments.joined(separator: " "))))"
    }

    static func attributes(_ path: String) -> (inode: UInt64, modified: timespec, mode: mode_t)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (UInt64(info.st_ino), info.st_mtimespec, info.st_mode & 0o7777)
    }

    static func main() throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        let configuration = "[ui]\nmouse_capture = false\n"
        check(HerdrExecutable.attachConfiguration == configuration, "the attach configuration turns mouse capture off and nothing else")
        check(HerdrExecutable.configurationPathVariable == "HERDR_CONFIG_PATH", "herdr's variable")
        check(HerdrExecutable.remoteAttachConfigurationPath == ".cache/3rdr/herdr-attach.toml", "beside the drops on the far side")

        // Off, every command is what it was: the iOS app's and the Mac's
        // one-shot requests, and machine setup, don't pass the flag.
        let sample = "'status' 'client' '--json'"
        check(HerdrExecutable.execScript(arguments: sample) == oldExecScript(arguments: sample), "execScript unchanged by default")
        check(HerdrExecutable.remoteCommand(arguments: sample) == "sh -c \(shellQuoted(oldExecScript(arguments: sample)))", "remoteCommand unchanged by default")
        let machine = HerdrMachine(id: "m1", label: "GPU box", target: "dev@gpu.example", session: "work s'ession", enabled: true)
        let oldMachineAttach = (["--session", machine.session] + HerdrExecutable.attachArguments(terminalID: "w1:p2")).map(shellQuoted).joined(separator: " ")
        check(HerdrExecutable.sshAttachArguments(to: machine, terminalID: "w1:p2") == ["-tt"] + HerdrExecutable.sshOptions + [machine.target, "sh -c \(shellQuoted(oldExecScript(arguments: oldMachineAttach)))"], "sshAttachArguments unchanged by default")
        for session in ["", "main", "a b'c"] {
            check(HerdrExecutable.remoteAttachCommand(sessionName: session, terminalID: "w1:p2", herdrMachine: nil) == oldHostCommand(sessionName: session, terminalID: "w1:p2"), "TerminalSession's command unchanged by default (session \(session))")
        }
        check(HerdrExecutable.remoteAttachCommand(sessionName: "main", terminalID: "w1:p2", herdrMachine: machine)
              == (["ssh"] + HerdrExecutable.sshAttachArguments(to: machine, terminalID: "w1:p2")).map(shellQuoted).joined(separator: " "), "TerminalSession's machine command unchanged by default")

        // On: the configuration script, then the same lookup.
        let script = HerdrExecutable.execScript(arguments: sample, withoutMouseCapture: true)
        check(script.hasSuffix("; " + oldExecScript(arguments: sample)), "the lookup is unchanged after the configuration script")
        for needle in ["umask 077", "mkdir -p", "export HERDR_CONFIG_PATH=", "'.cache/3rdr/herdr-attach.toml'", "printf '%s\\n' '[ui]' 'mouse_capture = false'", "mv -f"] {
            check(script.contains(needle), "the configuration script has \(needle)")
        }
        // The same in every login shell (see TerminalDropPaste.receiveScript).
        let remote = HerdrExecutable.remoteCommand(arguments: sample, withoutMouseCapture: true)
        check(!remote.contains("\n") && !remote.contains("!") && !script.contains("\\\\") && !script.contains("XDG_CONFIG_HOME"), "one line, no !, no backslash pairs, no XDG_CONFIG_HOME")
        check(remote == "sh -c \(shellQuoted(script))", "remoteCommand wraps it in sh -c")
        let machineArguments = HerdrExecutable.sshAttachArguments(to: machine, terminalID: "w1:p2", withoutMouseCapture: true)
        check(machineArguments == ["-tt"] + HerdrExecutable.sshOptions + [machine.target, HerdrExecutable.remoteCommand(arguments: oldMachineAttach, withoutMouseCapture: true)], "a herdr machine makes its own copy")
        check(HerdrExecutable.remoteAttachCommand(sessionName: "main", terminalID: "w1:p2", herdrMachine: machine, withoutMouseCapture: true)
              == (["ssh"] + machineArguments).map(shellQuoted).joined(separator: " "), "through the host's ssh, the machine makes the copy")

        // The remote command, run by each login shell this Mac has, as sshd
        // runs it: `$SHELL -c <command>`.
        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"].filter { fm.isExecutableFile(atPath: $0) }
        check(shells.contains("/bin/sh") && shells.contains("/bin/zsh"), "shells to run it in")
        let fakeHerdr = "#!/bin/sh\n# TEST ONLY: stands in for herdr and records how it was started.\n{ printf 'config=%s\\n' \"${HERDR_CONFIG_PATH-unset}\"; for a in \"$@\"; do printf 'arg=%s\\n' \"$a\"; done; } > \"$HOME/started\"\n"
        var homes = 0
        func freshHome() throws -> URL {
            homes += 1
            let home = work.appending(path: "home\(homes)", directoryHint: .isDirectory)
            try fm.createDirectory(at: home.appending(path: ".local/bin"), withIntermediateDirectories: true)
            let herdr = home.appending(path: ".local/bin/herdr").path
            try fakeHerdr.write(toFile: herdr, atomically: true, encoding: .utf8)
            chmod(herdr, 0o755)
            return home
        }
        func run(_ shell: String, _ command: String, home: URL) throws -> [String] {
            // The fake is the first of herdr's usual locations, so the
            // lookup stops there and no real herdr can be started.
            precondition(fm.isExecutableFile(atPath: home.appending(path: ".local/bin/herdr").path))
            try? fm.removeItem(at: home.appending(path: "started"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "SHELL": shell]
            process.currentDirectoryURL = home
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            check(process.terminationStatus == 0, "\(shell) ran the command")
            return try String(contentsOf: home.appending(path: "started"), encoding: .utf8).split(separator: "\n").map(String.init)
        }
        let attach = (["--session", shellQuoted("a b'c")] + HerdrExecutable.attachArguments(terminalID: "w1:p2").map(shellQuoted)).joined(separator: " ")
        let attachArgs = ["arg=--session", "arg=a b'c", "arg=terminal", "arg=attach", "arg=w1:p2", "arg=--takeover"]
        for shell in shells {
            // Made where there was none, readable by the account only.
            var home = try freshHome()
            let file = home.appending(path: ".cache/3rdr/herdr-attach.toml").path
            let command = HerdrExecutable.remoteAttachCommand(sessionName: "a b'c", terminalID: "w1:p2", herdrMachine: nil, withoutMouseCapture: true)
            check(command == HerdrExecutable.remoteCommand(arguments: attach, withoutMouseCapture: true), "the host's command")
            var started = try run(shell, command, home: home)
            check(started == ["config=\(file)"] + attachArgs, "\(shell): herdr started with the configuration and its arguments, got \(started)")
            check((try? String(contentsOfFile: file, encoding: .utf8)) == configuration, "\(shell): the configuration file")
            check(attributes(file)?.mode == 0o600 && attributes(home.appending(path: ".cache/3rdr").path)?.mode == 0o700 && attributes(home.appending(path: ".cache").path)?.mode == 0o700, "\(shell): only the account's")
            let beside = try fm.contentsOfDirectory(atPath: home.appending(path: ".cache/3rdr").path)
            check(beside == ["herdr-attach.toml"], "\(shell): nothing left beside it, got \(beside)")
            // Left alone when it is already right.
            let before = attributes(file)
            usleep(20_000)
            started = try run(shell, command, home: home)
            let after = attributes(file)
            check(started == ["config=\(file)"] + attachArgs && before?.inode == after?.inode && before?.modified.tv_sec == after?.modified.tv_sec && before?.modified.tv_nsec == after?.modified.tv_nsec, "\(shell): an existing file is not written again")
            // Written again when it says something else.
            try "[ui]\nmouse_capture = true\n".write(toFile: file, atomically: false, encoding: .utf8)
            started = try run(shell, command, home: home)
            check(started == ["config=\(file)"] + attachArgs && (try? String(contentsOfFile: file, encoding: .utf8)) == configuration, "\(shell): a file that says otherwise is replaced")
            // Can't be written: the attach goes on, without it.
            home = try freshHome()
            try "not a folder".write(to: home.appending(path: ".cache"), atomically: false, encoding: .utf8)
            started = try run(shell, command, home: home)
            check(started == ["config=unset"] + attachArgs, "\(shell): with no place for the file herdr still starts, without the variable, got \(started)")
            // On a herdr machine, the same through the host's ssh.
            home = try freshHome()
            started = try run(shell, machineArguments.last!, home: home)
            check(started == ["config=\(home.appending(path: ".cache/3rdr/herdr-attach.toml").path)", "arg=--session", "arg=work s'ession", "arg=terminal", "arg=attach", "arg=w1:p2", "arg=--takeover"], "\(shell): the machine's command, got \(started)")
            // Off: nothing written, nothing exported.
            home = try freshHome()
            started = try run(shell, HerdrExecutable.remoteAttachCommand(sessionName: "a b'c", terminalID: "w1:p2", herdrMachine: nil), home: home)
            check(started == ["config=unset"] + attachArgs && !fm.fileExists(atPath: home.appending(path: ".cache").path), "\(shell): without the flag, as before")
            started = try run(shell, HerdrExecutable.remoteCommand(arguments: sample), home: home)
            check(started == ["config=unset", "arg=status", "arg=client", "arg=--json"] && !fm.fileExists(atPath: home.appending(path: ".cache").path), "\(shell): a one-shot request, as before")
        }

        // This Mac's copy, in the app's caches.
        let folder = work.appending(path: "Caches/com.bldg-7.shepherd", directoryHint: .isDirectory)
        let local = HerdrExecutable.localAttachConfiguration(in: folder)
        let localFile = folder.appending(path: "herdr-attach.toml").path
        check(local == localFile && (try? String(contentsOfFile: localFile, encoding: .utf8)) == configuration, "this Mac's copy is written")
        check(attributes(localFile)?.mode == 0o600 && attributes(folder.path)?.mode == 0o700, "only the account's")
        let first = attributes(localFile)
        usleep(20_000)
        check(HerdrExecutable.localAttachConfiguration(in: folder) == localFile, "found again")
        let second = attributes(localFile)
        check(first?.inode == second?.inode && first?.modified.tv_sec == second?.modified.tv_sec && first?.modified.tv_nsec == second?.modified.tv_nsec, "and not written again")
        try "[ui]\nmouse_capture = true\n".write(toFile: localFile, atomically: false, encoding: .utf8)
        check(HerdrExecutable.localAttachConfiguration(in: folder) == localFile && (try? String(contentsOfFile: localFile, encoding: .utf8)) == configuration, "replaced when it says otherwise")
        try "not a folder".write(to: work.appending(path: "Blocked"), atomically: false, encoding: .utf8)
        check(HerdrExecutable.localAttachConfiguration(in: work.appending(path: "Blocked/com.bldg-7.shepherd")) == nil, "nil when it can't be written")
        check(LocalAttachLaunch.configurationFolder.path.hasSuffix("/Library/Caches/com.bldg-7.shepherd"), "the app's caches folder, got \(LocalAttachLaunch.configurationFolder.path)")

        // The three ways LocalTerminalSession starts an attach.
        let base = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8", "HOME=/Users/someone"]
        let inherited = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "SSH_AUTH_SOCK": "/private/tmp/agent.sock", "OTHER": "kept out"]
        let config = "/Users/someone/Library/Caches/com.bldg-7.shepherd/herdr-attach.toml"
        let overSSH = LocalAttachLaunch.make(terminalID: "w1:p2", herdrMachine: machine, herdrPath: nil, configurationPath: config, baseEnvironment: base, inherited: inherited)
        check(overSSH == LocalAttachLaunch(executable: "/usr/bin/env", arguments: ["ssh"] + machineArguments,
              environment: base + ["PATH=/opt/homebrew/bin:/usr/bin:/bin", "SSH_AUTH_SOCK=/private/tmp/agent.sock"]), "a herdr machine: this Mac's ssh, the machine's own copy, no HERDR_CONFIG_PATH of this Mac's")
        let direct = LocalAttachLaunch.make(terminalID: "w1:p2", herdrMachine: nil, herdrPath: "/opt/homebrew/bin/herdr", configurationPath: config, baseEnvironment: base, inherited: inherited)
        check(direct == LocalAttachLaunch(executable: "/opt/homebrew/bin/herdr", arguments: ["terminal", "attach", "w1:p2", "--takeover"],
              environment: base + ["HERDR_CONFIG_PATH=\(config)"]), "herdr started directly, with this Mac's copy")
        let throughZsh = LocalAttachLaunch.make(terminalID: "w1:p2", herdrMachine: nil, herdrPath: nil, configurationPath: config, baseEnvironment: base, inherited: inherited)
        check(throughZsh == LocalAttachLaunch(executable: "/bin/zsh", arguments: ["-ic", "herdr 'terminal' 'attach' 'w1:p2' '--takeover'"],
              environment: base + ["HERDR_CONFIG_PATH=\(config)"]), "herdr through zsh, with this Mac's copy")
        for herdrPath in ["/opt/homebrew/bin/herdr", nil] {
            check(LocalAttachLaunch.make(terminalID: "w1:p2", herdrMachine: nil, herdrPath: herdrPath, configurationPath: nil, baseEnvironment: base, inherited: inherited).environment == base,
                  "without a copy, the environment it always had")
        }
        print("PASS \(checks) attach command checks: unchanged commands without the flag; the configuration file made, kept, replaced and done without by \(shells.joined(separator: ", ")) with a fake herdr; this Mac's copy; the three local launches; no SSH, no real herdr")
    }
}
