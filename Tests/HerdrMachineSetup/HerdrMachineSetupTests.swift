import Foundation

// Adding, checking again and removing herdr machines (SHPHRD-83), without
// the app, a network or anyone's real ~/.ssh or herdr: OpenSSH's and herdr
// 0.9.1's messages read from fixtures; the step wrapper, the known_hosts
// append and the stop and cleanup run with /bin/sh; the whole flow run with
// a fake `ssh` on PATH and a fake `herdr` in the test HOME, through the
// real `LocalHerdrTransport`.
//
// Arguments: <fake dir> <fingerprints file>. The environment's HOME, TMPDIR
// and PATH are the runner's: a HOME and TMPDIR of the test's own, and PATH
// with the fake ssh first.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func waitUntil(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

let fakeDir = URL(fileURLWithPath: CommandLine.arguments[1])
let fingerprintsFile = URL(fileURLWithPath: CommandLine.arguments[2])
let home = ProcessInfo.processInfo.environment["HOME"]!
let tmp = ProcessInfo.processInfo.environment["TMPDIR"]!
let hostKey = try! String(contentsOf: fakeDir.appendingPathComponent("hostkey.pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

func write(_ name: String, _ text: String) {
    try! text.write(to: fakeDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

func fake(_ name: String) -> String {
    read(fakeDir.appendingPathComponent(name).path) ?? ""
}

/// The invocations a fake logged: each one's arguments.
func invocations(_ log: String) -> [[String]] {
    fake(log).components(separatedBy: "----\n").filter { !$0.isEmpty }.map {
        $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }
}

/// A scenario of its own: the fakes' settings, logs and catalog, and the
/// test HOME's ~/.ssh, as given.
func reset(scenario: String = "ok", add: String = "ok", status: String = "ok", knownHosts: String? = nil) {
    for name in ["ssh-arguments.log", "herdr-arguments.log", "control.log", "catalog", "herdr-ssh-dir", "herdr-remove", "ssh-G"] {
        try? FileManager.default.removeItem(at: fakeDir.appendingPathComponent(name))
    }
    write("scenario", scenario)
    write("herdr-add", add)
    write("herdr-status", status)
    write("hostname", "workbox.example")
    try? FileManager.default.removeItem(atPath: home + "/.ssh")
    if let knownHosts {
        try! FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try! knownHosts.write(toFile: home + "/.ssh/known_hosts", atomically: true, encoding: .utf8)
    }
}

/// The fake herdr's catalog, as `machine list --json` would give it.
func catalog() -> [HerdrMachine] {
    fake("catalog").split(separator: "\n").compactMap { line in
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 else { return nil }
        let json = "{\"id\":\"\(fields[0])\",\"label\":\"\(fields[1])\",\"target\":\"\(fields[2])\",\"session\":\"\(fields[3])\",\"enabled\":\(fields[4])}"
        return try? JSONDecoder().decode(HerdrMachine.self, from: Data(json.utf8))
    }
}

func result(_ status: Int, _ stderr: String = "", stdout: String = "", timedOut: Bool = false) -> HostStepResult {
    HostStepResult(status: status, timedOut: timedOut, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

let client = HerdrClient(transport: LocalHerdrTransport(socketPath: tmp + "/no-herdr.sock"))
let runner = HerdrClientStepRunner(client: client)

/// Records what a setup asked of the app.
@MainActor final class Recorder {
    var handoffs: [HerdrMachineSetup.TerminalHandoff] = []
    var closes = 0
    var ends = 0
    var changes = 0
}

func makeSetup(_ mode: HerdrMachineSetup.Mode = .add) -> (HerdrMachineSetup, Recorder) {
    let recorder = Recorder()
    let setup = HerdrMachineSetup(
        mode: mode, hostName: "This Mac", runner: runner,
        savedMachines: { catalog() },
        listMachines: {
            let listed = try await runner.run(HostStep(command: HerdrExecutable.execScript(arguments: "'machine' 'list' '--json'"), deadline: 10))
            return try JSONDecoder().decode([HerdrMachine].self, from: listed.stdout)
        })
    setup.onTerminal = { recorder.handoffs.append($0) }
    setup.onClose = { recorder.closes += 1 }
    setup.onEnded = { recorder.ends += 1 }
    setup.onMachinesChanged = { recorder.changes += 1 }
    return (setup, recorder)
}

/// Picks `workbox`, names it after itself, and waits for the checks to stop.
func runAdd(_ setup: HerdrMachineSetup) async {
    expect(setup.chooseTarget("workbox"), "target taken")
    expect(setup.stage == .name && setup.suggestedLabel == "workbox", "name asked for, suggested \(setup.suggestedLabel)")
    expect(setup.chooseName(""), "name taken")
    let stopped = await waitUntil(40) { setup.prompt != nil || setup.stage != .checks }
    expect(stopped, "checks stopped")
}

func states(_ setup: HerdrMachineSetup) -> [HerdrMachineSetup.CheckState] {
    setup.checks.map(\.state)
}

func problem(_ setup: HerdrMachineSetup) -> (String, [HerdrMachineSetup.Action])? {
    if case .problem(let message, let actions) = setup.prompt { return (message, actions) }
    return nil
}

// MARK: - Fixtures: OpenSSH 10.3 and herdr 0.9.1

func signInFixtures() {
    let names: Set<String> = ["workbox.example"]
    func classify(_ r: HostStepResult, _ hostKeyNames: Set<String> = names) -> SSHSignInOutcome {
        SSHSignInOutcome.classify(r, hostKeyNames: hostKeyNames)
    }
    expect(classify(result(255, "No ED25519 host key is known for workbox.example and you have requested strict checking.\r\nHost key verification failed.\r\n")) == .unknownHostKey(host: "workbox.example"), "unknown key")
    let ported = SSHResolvedConfig(hostname: "workbox.example", user: "dev", port: 2222, proxyJump: nil, proxyCommand: nil, hostKeyAlias: nil, userKnownHostsFiles: ["~/.ssh/known_hosts"], remoteCommand: nil)
    expect(classify(result(255, "No ECDSA host key is known for [workbox.example]:2222 and you have requested strict checking.\nHost key verification failed.\n"), ported.hostKeyNames) == .unknownHostKey(host: "[workbox.example]:2222"), "unknown key on another port")
    let aliased = SSHResolvedConfig(hostname: "10.0.0.5", user: nil, port: 22, proxyJump: nil, proxyCommand: nil, hostKeyAlias: "wb-key", userKnownHostsFiles: ["~/.ssh/known_hosts"], remoteCommand: nil)
    expect(classify(result(255, "No ED25519 host key is known for wb-key and you have requested strict checking.\nHost key verification failed.\n"), aliased.hostKeyNames) == .unknownHostKey(host: "wb-key"), "unknown key under a HostKeyAlias")
    if case .jumpHostKey = classify(result(255, "No ED25519 host key is known for jump.example and you have requested strict checking.\r\nHost key verification failed.\r\n")) {} else { expect(false, "strict jump host key") }
    if case .jumpHostKey = classify(result(255, "The authenticity of host 'jump.example (10.0.0.1)' can't be established.\r\nED25519 key fingerprint is SHA256:Q1zkmgAizV6Dpvk6Ou3ae2T6MSs5nN9iu9vjbg3zrUQ.\r\nHost key verification failed.\r\n")) {} else { expect(false, "asking jump host key") }
    let changed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\r
        Offending ED25519 key in /home/dev/.ssh/known_hosts:3\r
        Host key for workbox.example has changed and you have requested strict checking.\r
        Host key verification failed.\r

        """
    if case .changedHostKey(let message) = classify(result(255, changed)) {
        expect(!message.contains("@@@") && message.contains("Host key verification failed."), "changed key message without its banner: \(message)")
    } else { expect(false, "changed key") }
    if case .revokedHostKey = classify(result(255, "@@@@@@@\n@       WARNING: REVOKED HOST KEY DETECTED!               @\nThe ED25519 host key for workbox.example is marked as revoked.\nHost key verification failed.\n")) {} else { expect(false, "revoked key") }
    if case .otherHostKey = classify(result(255, "Host key verification failed.\r\n")) {} else { expect(false, "other host key failure") }
    if case .permissionDenied = classify(result(255, "dev@workbox.example: Permission denied (publickey,password,keyboard-interactive).\r\n")) {} else { expect(false, "permission denied") }
    if case .permissionDenied = classify(result(255, "Received disconnect from 10.0.0.5 port 22:2: Too many authentication failures\r\nDisconnected from 10.0.0.5 port 22\r\n")) {} else { expect(false, "too many failures") }
    if case .permissionDenied = classify(result(255, "Visit https://intranet.example/ssh for help\ndev@workbox.example: Permission denied (publickey).\n")) {} else { expect(false, "a banner's address is not a login") }
    for message in ["ssh: Could not resolve hostname nowhere.example: nodename nor servname provided, or not known\r\n",
                    "ssh: connect to host workbox.example port 22: Operation timed out\r\n",
                    "ssh: connect to host workbox.example port 22: Connection refused\r\n",
                    "kex_exchange_identification: read: Connection reset by peer\r\nConnection reset by 10.0.0.5 port 22\r\n",
                    "Connection closed by 10.0.0.5 port 22\r\n"] {
        if case .network = classify(result(255, message)) {} else { expect(false, "network: \(message)") }
    }
    expect(classify(result(143, "# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/l1b2c3d4\n", timedOut: true)) == .authenticationURL("https://login.tailscale.com/a/l1b2c3d4"), "Tailscale check")
    expect(classify(result(143, "", timedOut: true)) == .timedOut, "timed out")
    if case .remoteCommand = classify(result(255, "Cannot execute command-line and remote command.\r\n")) {} else { expect(false, "remote command") }
    let probe = "Welcome to workbox\n@@SHEPHERD-PROBE@@\nsystem Linux\narchitecture x86_64\nherdr /home/dev/.local/bin/herdr\nclient {\"version\":\"0.9.1\",\"channel\":\"stable\"}\n@@SHEPHERD-PROBE-END@@\n"
    expect(classify(result(0, stdout: probe)) == .signedIn(SSHProbe(system: "Linux", architecture: "x86_64", herdrPath: "/home/dev/.local/bin/herdr", herdrVersion: "0.9.1")), "signed in")
    let bare = SSHProbe.parse("@@SHEPHERD-PROBE@@\nsystem Darwin\narchitecture arm64\nherdr \n@@SHEPHERD-PROBE-END@@\n")
    expect(bare?.herdrPath == nil && bare?.summary == "herdr isn't installed there yet · Darwin arm64", "no herdr there: \(String(describing: bare?.summary))")
    if case .failed = classify(result(0, stdout: "no probe here")) {} else { expect(false, "signed in without the probe") }
}

func herdrFixtures() {
    expect(HerdrMachineAddOutcome.classify(result(0, stdout: "Saved SSH machine 0123456789abcdef0123456789abcdef. Remote server is ready.\nOpen Herdr clients connect automatically.\n")) == .saved(id: "0123456789abcdef0123456789abcdef"), "saved")
    expect(HerdrMachineAddOutcome.classify(result(2, "error: SSH endpoint label must be at most 128 bytes and contain no control characters\n")) == .invalid("SSH endpoint label must be at most 128 bytes and contain no control characters"), "invalid")
    for message in ["error: matching remote herdr 0.9.1 is not installed at ~/.local/bin/herdr; run from an interactive terminal to approve installation; machine was not saved\n",
                    "error: remote herdr server on workbox is running v0.8.2; run from an interactive terminal to approve stopping it for the update; machine was not saved\n",
                    "error: remote server is not ready for saved machines; machine was not saved\n",
                    "error: remote platform detection failed: Host key verification failed.; machine was not saved\nhint: saved machines use strict host-key checking; add the host key to the configured known_hosts file, then retry.\n"] {
        if case .needsTerminal = HerdrMachineAddOutcome.classify(result(1, message)) {} else { expect(false, "needs a terminal: \(message)") }
    }
    if case .permissionDenied = HerdrMachineAddOutcome.classify(result(1, "error: remote platform detection failed: dev@workbox: Permission denied (publickey).; machine was not saved\nhint: verify SSH access first with `ssh workbox`.\n")) {} else { expect(false, "add permission denied") }
    if case .failed(let message) = HerdrMachineAddOutcome.classify(result(1, "error: remote install preparation failed: disk full; machine was not saved\n")) {
        expect(message == "remote install preparation failed: disk full; machine was not saved", "add failure message: \(message)")
    } else { expect(false, "add failed") }
    expect(HerdrMachineAddOutcome.classify(result(143, timedOut: true)) == .stopped(timedOut: true), "add timed out")
    expect(HerdrMachineAddOutcome.classify(result(143)) == .stopped(timedOut: false), "add stopped")
    expect(HerdrMachineRemoveOutcome.classify(result(0, stdout: "Removed SSH machine x.\n")) == .removed, "removed")
    expect(HerdrMachineRemoveOutcome.classify(result(1, "machine profile 0123456789abcdef0123456789abcdef was not found\n")) == .removed, "already gone")
    if case .failed = HerdrMachineRemoveOutcome.classify(result(2, "error: invalid SSH endpoint profile id\n")) {} else { expect(false, "remove failed") }
    expect(HerdrMachineStatusOutcome.classify(result(0, stdout: "status: running\n")) == .reachable, "reachable")
    if case .needsTerminal = HerdrMachineStatusOutcome.classify(result(1, "error: machine 'wb' (session default): remote server is not ready for saved machines\n")) {} else { expect(false, "status not ready") }
    if case .failed = HerdrMachineStatusOutcome.classify(result(1, "error: machine 'wb' (session default): ssh: connect to host wb port 22: Connection refused\n")) {} else { expect(false, "status unreachable") }
}

func resolveFixtures() {
    // `ssh -G` from OpenSSH 10.3p1, for a Host block with HostName, User,
    // Port and ProxyJump (abridged; the lines read are all there).
    let output = """
        user dev
        hostname 10.0.0.5
        port 2222
        addressfamily any
        batchmode no
        checkhostip no
        controlmaster false
        hashknownhosts no
        stricthostkeychecking ask
        updatehostkeys true
        globalknownhostsfile /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2
        userknownhostsfile /Users/someone/.ssh/known_hosts /Users/someone/.ssh/known_hosts2
        controlpersist no
        proxyjump jump.example

        """
    let config = SSHResolvedConfig.parse(output)
    expect(config?.hostname == "10.0.0.5" && config?.user == "dev" && config?.port == 2222 && config?.proxyJump == "jump.example", "resolved: \(String(describing: config))")
    expect(config?.knownHostsFile == "/Users/someone/.ssh/known_hosts", "known_hosts file")
    expect(config?.hostKeyNames == ["[10.0.0.5]:2222", "10.0.0.5"], "host key names")
    expect(config?.destination == "dev@10.0.0.5:2222 via jump.example", "destination: \(config?.destination ?? "")")
    expect(config?.blocker == nil, "no blocker")
    expect(SSHResolvedConfig.parse(output + "remotecommand tmux attach\n")?.blocker != nil, "a RemoteCommand blocks")
    expect(SSHResolvedConfig.parse(output.replacingOccurrences(of: "userknownhostsfile /Users/someone/.ssh/known_hosts /Users/someone/.ssh/known_hosts2", with: "userknownhostsfile /dev/null"))?.blocker != nil, "no known hosts blocks")
    expect(SSHResolvedConfig.parse("port 22\n") == nil, "no hostname, nothing resolved")
    expect(SSHSteps.shellPath("~/.ssh/known_hosts") == "\"$HOME\"/'.ssh/known_hosts'", "a ~ path for the shell")
    expect(SSHSteps.shellPath("/Users/some one/.ssh/known_hosts") == "'/Users/some one/.ssh/known_hosts'", "an absolute path for the shell")
    expect(SSHSteps.shellPath("%d/.ssh/known_hosts") == nil && SSHSteps.shellPath("known_hosts") == nil, "token and relative paths refused")
}

func fingerprintFixtures() {
    // Lines of "<known_hosts line>\t<ssh-keygen -lf fingerprint>\t<type>",
    // made by the runner with ssh-keygen.
    let lines = (read(fingerprintsFile.path) ?? "").split(separator: "\n")
    expect(lines.count >= 3, "fingerprint fixtures: \(lines.count)")
    for line in lines {
        let fields = line.split(separator: "\t").map(String.init)
        guard fields.count == 3, let key = KnownHostLine.first(in: "# a comment\n\n" + fields[0] + "\n") else {
            expect(false, "known_hosts line read: \(line)")
            continue
        }
        expect(key.fingerprint == fields[1], "\(fields[2]) fingerprint \(key.fingerprint) is ssh-keygen's \(fields[1])")
        expect(key.fingerprint.count == 7 + 43, "43 characters after SHA256:")
        expect(key.displayType == fields[2], "type \(key.displayType) is \(fields[2])")
        expect(key.line == fields[0], "the line as written")
    }
    expect(KnownHostLine.first(in: "@revoked * ssh-ed25519 AAAA\nhost ssh-rsa bm90IGEga2V5\n") == nil, "revoked lines and blobs that don't name their type are passed over")
}

// MARK: - The step wrapper

func wrapperTests() async {
    // A command past its deadline: TERM, and the deadline said.
    var started = Date()
    if let r = try? await runner.run(HostStep(command: "sleep 30", deadline: 1)) {
        expect(r.timedOut && r.status == 143, "timed out with TERM: \(r)")
        expect(Date().timeIntervalSince(started) < 6, "ended soon after its deadline")
    } else { expect(false, "deadline step ran") }

    // One that ignores TERM: KILL two seconds later.
    started = Date()
    if let r = try? await runner.run(HostStep(command: "trap '' TERM; sleep 30", deadline: 1)) {
        let elapsed = Date().timeIntervalSince(started)
        expect(r.timedOut && r.status == 137, "killed: \(r)")
        expect(elapsed >= 2.5 && elapsed < 8, "KILL two seconds after TERM: \(elapsed)")
    } else { expect(false, "KILL step ran") }

    // Output kept up to its limit, the rest said to be cut; stderr apart.
    if let r = try? await runner.run(HostStep(command: "head -c 300000 /dev/zero | tr '\\000' a; printf 'oops\\n' >&2; exit 3", deadline: 10, stdoutLimit: 1000)) {
        expect(r.status == 3 && r.stdout.count == 1000 && r.stdoutTruncated && r.stderrText == "oops\n" && !r.stderrTruncated, "limits: \(r.status) \(r.stdout.count) \(r.stdoutTruncated)")
    } else { expect(false, "limit step ran") }

    // What a login shell writes around the report — even a line made to
    // look like one — is passed over.
    let token = HostStep.newToken()
    if let raw = try? await client.runScript(HostStep(command: "printf 'out\\n'", deadline: 5).script(token: token), timeout: 20) {
        var noisy = Data("Last login: yesterday\n@@SHEPHERD-STEP-\(HostStep.newToken())@@\nstatus 9\n".utf8)
        noisy.append(raw)
        noisy.append(Data("logout\n".utf8))
        let parsed = try? HostStepResult.parse(noisy, token: token)
        expect(parsed?.status == 0 && parsed?.stdoutText == "out\n", "report found among other lines: \(String(describing: parsed))")
        expect((try? HostStepResult.parse(Data("no report\n".utf8), token: token)) == nil, "no report, an error")
    } else { expect(false, "noisy step ran") }

    // Nothing to ask with: no DISPLAY, and askpass never.
    if let r = try? await runner.run(HostStep(command: "printf '%s|%s' \"${DISPLAY-unset}\" \"$SSH_ASKPASS_REQUIRE\"", deadline: 5)) {
        expect(r.stdoutText == "unset|never", "environment: \(r.stdoutText)")
    }

    // The app's own backstop: a transport without one of its own gives up
    // after the time given.
    started = Date()
    do {
        _ = try await SlowTransport().runScript("anything", timeout: 0.5)
        expect(false, "slow transport answered")
    } catch is HostScriptTimedOut {
        expect(Date().timeIntervalSince(started) < 3, "gave up in time")
    } catch {
        expect(false, "unexpected \(error)")
    }
    // This Mac's: LocalCommand ends the session.
    started = Date()
    do {
        _ = try await client.runScript("sleep 30", timeout: 1)
        expect(false, "local script outlived its timeout")
    } catch {
        expect(Date().timeIntervalSince(started) < 6, "local timeout ended it: \(error)")
    }
}

/// A host that never answers.
actor SlowTransport: HerdrTransport {
    func connect() async throws {}
    func disconnect() async {}
    func send(method: String, params: JSONValue) async throws -> JSONValue { .null }
    func runHerdr(_ arguments: [String]) async throws -> Data { Data() }
    func runScript(_ script: String) async throws -> Data {
        try await Task.sleep(for: .seconds(10))
        return Data()
    }
}

func pidPath(_ token: String) -> String { tmp + (tmp.hasSuffix("/") ? "" : "/") + "shepherd-herdr-add-\(token).pid" }

func herdrCleanupTests() async {
    // herdr killed at the deadline: its shared SSH connection is ended and
    // its folder removed.
    reset(add: "hang")
    var token = HostStep.newToken()
    var step = HerdrMachineSteps.add(target: "workbox", label: "wb", pidFile: HerdrMachineSteps.pidFile(token: token))
    step.deadline = 2
    if let r = try? await runner.run(step) {
        let dir = fake("herdr-ssh-dir").trimmingCharacters(in: .whitespacesAndNewlines)
        expect(r.timedOut, "add timed out: \(r)")
        expect(!dir.isEmpty && !FileManager.default.fileExists(atPath: dir), "herdr's folder removed: \(dir)")
        expect(fake("control.log") == "exit workbox\n", "ControlPersist master told to exit: \(fake("control.log"))")
        expect(!FileManager.default.fileExists(atPath: pidPath(token)), "pid file removed")
    } else { expect(false, "add step ran") }
    expect(invocations("herdr-arguments.log").first == ["machine", "add", "workbox", "--label", "wb"], "herdr's arguments: \(invocations("herdr-arguments.log"))")

    // Stopped by the person: the same, at once.
    reset(add: "hang")
    token = HostStep.newToken()
    let pidFile = HerdrMachineSteps.pidFile(token: token)
    let started = Date()
    let adding = Task { try await runner.run(HerdrMachineSteps.add(target: "workbox", label: "wb", pidFile: pidFile)) }
    expect(await waitUntil { FileManager.default.fileExists(atPath: pidPath(token)) && !fake("herdr-ssh-dir").isEmpty }, "add running")
    if let stop = try? await runner.run(HostStep.stop(pidFile: pidFile)) {
        expect(stop.status == 0, "stop ran: \(stop)")
    }
    if let r = try? await adding.value {
        expect(r.status == 143 && !r.timedOut, "stopped, not timed out: \(r)")
        expect(fake("control.log") == "exit workbox\n", "master ended after Stop")
        expect(Date().timeIntervalSince(started) < 20, "stopped promptly")
    } else { expect(false, "stopped add reported") }
    // A Stop for a step that has ended does nothing.
    if let late = try? await runner.run(HostStep.stop(pidFile: pidFile)) {
        expect(late.status == 0, "late stop harmless")
    }
}

// MARK: - known_hosts

func knownHostsTests() async {
    let file = home + "/.ssh/known_hosts"
    let line = "workbox.example " + hostKey
    func append(_ path: String) async -> HostStepResult? {
        guard let step = SSHSteps.appendKnownHost(line, to: path) else { return nil }
        return try? await runner.run(step)
    }

    // No ~/.ssh yet: made, private, and the line in a new file.
    reset()
    var r = await append(file)
    var attributes = try? FileManager.default.attributesOfItem(atPath: home + "/.ssh")
    expect(r?.status == 0 && r?.stdoutText == "added\n", "added: \(String(describing: r))")
    expect((attributes?[.posixPermissions] as? Int) == 0o700, "~/.ssh is 0700")
    expect(read(file) == line + "\n", "new file holds the line")

    // A last line without its newline gets one first.
    reset(knownHosts: "other.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther")
    r = await append(file)
    expect(read(file) == "other.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther\n" + line + "\n", "newline added before the line: \(read(file) ?? "")")

    // The same line again: left as it is.
    r = await append(file)
    expect(r?.stdoutText == "present\n", "present")
    expect(read(file)?.components(separatedBy: line).count == 2, "line once")

    // A symbolic link stays one; the file it points to gets the line.
    reset(knownHosts: "")
    try? FileManager.default.removeItem(atPath: file)
    try! "kept\n".write(toFile: home + "/real_known_hosts", atomically: true, encoding: .utf8)
    try! FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: home + "/real_known_hosts")
    r = await append("~/.ssh/known_hosts")
    attributes = try? FileManager.default.attributesOfItem(atPath: file)
    expect((attributes?[.type] as? FileAttributeType) == .typeSymbolicLink, "still a symbolic link")
    expect(read(home + "/real_known_hosts") == "kept\n" + line + "\n", "written through the link")
    try? FileManager.default.removeItem(atPath: home + "/real_known_hosts")

    // A read-only file is left alone, and said so.
    reset(knownHosts: "kept\n")
    try! FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file)
    r = await append(file)
    expect(r?.status == 5 && r?.stderrText.contains("can't be written to") == true, "read-only refused: \(String(describing: r))")
    expect(read(file) == "kept\n", "read-only file unchanged")
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)

    // A folder that isn't ~/.ssh isn't made.
    r = await append(home + "/missing/known_hosts")
    expect(r?.status == 4 && !FileManager.default.fileExists(atPath: home + "/missing"), "other folders not made")
    expect(SSHSteps.appendKnownHost(line, to: "%d/.ssh/known_hosts") == nil, "token path refused")
}

// MARK: - The whole flow, with fake ssh and herdr

func flowTests() async {
    let known = "workbox.example " + hostKey + "\n"

    // A target whose key is known: every check passes and herdr saves it.
    reset(knownHosts: known)
    var (setup, recorder) = makeSetup()
    await runAdd(setup)
    expect(setup.savedMachineID == "0123456789abcdef0123456789abcdef", "saved id: \(String(describing: setup.savedMachineID))")
    expect(states(setup) == [.passed, .passed, .passed, .passed], "all passed: \(states(setup))")
    expect(setup.checks.first(where: { $0.kind == .herdr })?.detail == "herdr 0.9.1 · \(platformName())", "herdr found: \(String(describing: setup.checks.first(where: { $0.kind == .herdr })?.detail))")
    expect(setup.checks.first?.detail == "dev@workbox.example", "destination: \(String(describing: setup.checks.first?.detail))")
    if case .finished(_, let actions) = setup.prompt { expect(actions == [.done], "Done offered") } else { expect(false, "finished: \(String(describing: setup.prompt))") }
    expect(recorder.changes == 1, "board told to read again")
    expect(catalog().map(\.label) == ["workbox"], "in herdr's list")
    let ssh = invocations("ssh-arguments.log")
    expect(ssh.count == 2 && ssh[0] == ["-G", "workbox"], "resolve: \(ssh.first ?? [])")
    if ssh.count > 1 {
        let signIn = ssh[1]
        for option in ["BatchMode=yes", "NumberOfPasswordPrompts=0", "StrictHostKeyChecking=yes", "ConnectTimeout=10", "ConnectionAttempts=1", "ServerAliveInterval=15", "ServerAliveCountMax=4"] {
            expect(signIn.contains(option), "sign in with \(option): \(signIn)")
        }
        // The probe is one argument of several lines, which the log splits.
        let target = signIn.firstIndex(of: "workbox")
        expect(signIn.first == "-T" && target != nil && signIn[target! + 1].hasPrefix("sh -c ") && signIn.last == "exit 0'", "sign in shape: \(signIn)")
    }
    expect(invocations("herdr-arguments.log") == [["machine", "add", "workbox", "--label", "workbox"]], "herdr add: \(invocations("herdr-arguments.log"))")
    setup.perform(.done)
    expect(recorder.closes == 1 && recorder.ends == 1 && setup.isClosed, "Done closes")

    // A new host key: fetched, shown, trusted, written, and signed in with.
    reset()
    (setup, recorder) = makeSetup()
    await runAdd(setup)
    guard case .trust(let approval) = setup.prompt else {
        expect(false, "trust asked: \(String(describing: setup.prompt))")
        return
    }
    let expected = (read(fingerprintsFile.path) ?? "").split(separator: "\n").first { $0.hasPrefix(String(hostKey.prefix(30))) || $0.contains(hostKey) }
    expect(approval.key.line == "workbox.example " + hostKey, "the line OpenSSH wrote: \(approval.key.line)")
    expect(expected.map { $0.split(separator: "\t").map(String.init)[1] } == approval.key.fingerprint, "fingerprint shown: \(approval.key.fingerprint)")
    expect(approval.file == home + "/.ssh/known_hosts" && approval.label == "workbox" && approval.hostName == "This Mac", "approval: \(approval)")
    expect(states(setup) == [.passed, .waiting, .pending, .pending], "waiting at sign in: \(states(setup))")
    expect(!FileManager.default.fileExists(atPath: home + "/.ssh/known_hosts"), "nothing written before trusting")
    let fetch = invocations("ssh-arguments.log").last ?? []
    for option in ["StrictHostKeyChecking=accept-new", "ControlPath=none", "PubkeyAuthentication=no", "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "UpdateHostKeys=no", "CheckHostIP=no", "GlobalKnownHostsFile=/dev/null"] {
        expect(fetch.contains(option), "fetch with \(option): \(fetch)")
    }
    expect(fetch.contains { $0.hasPrefix("UserKnownHostsFile=\"") && $0.contains("shepherd-step.") }, "fetch into the step's own file")
    setup.perform(.trust)
    expect(await waitUntil(40) { if case .finished = setup.prompt { true } else { false } }, "saved after trusting: \(String(describing: setup.prompt))")
    expect(read(home + "/.ssh/known_hosts") == "workbox.example " + hostKey + "\n", "key in known_hosts")
    expect((try? FileManager.default.attributesOfItem(atPath: home + "/.ssh"))?[.posixPermissions] as? Int == 0o700, "~/.ssh made private")

    // Not trusting it: nothing is written, and the panel closes.
    reset()
    (setup, recorder) = makeSetup()
    await runAdd(setup)
    setup.perform(.cancel)
    expect(setup.isClosed && recorder.closes == 1 && !FileManager.default.fileExists(atPath: home + "/.ssh/known_hosts"), "cancelled, nothing written")

    // A key that changed, or was revoked: never written over.
    for scenario in ["changed", "revoked"] {
        reset(scenario: scenario, knownHosts: "workbox.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldKey\n")
        (setup, recorder) = makeSetup()
        await runAdd(setup)
        let stopped = problem(setup)
        expect(stopped?.1 == [.tryAgain], "\(scenario): only Try Again: \(String(describing: stopped))")
        expect(stopped?.0.contains("ssh-keygen -R workbox.example") == true, "\(scenario): ssh-keygen -R named")
        expect(read(home + "/.ssh/known_hosts") == "workbox.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldKey\n", "\(scenario): known_hosts untouched")
        expect(!invocations("ssh-arguments.log").contains { $0.contains("StrictHostKeyChecking=accept-new") }, "\(scenario): no key fetched")
        expect(invocations("herdr-arguments.log").isEmpty, "\(scenario): herdr not run")
    }

    // Password or MFA only: no saving, the way to a key, and a terminal.
    reset(scenario: "password-only", knownHosts: known)
    (setup, recorder) = makeSetup()
    await runAdd(setup)
    expect(problem(setup)?.1 == [.tryAgain, .openTerminal] && problem(setup)?.0.contains("ssh-add") == true, "password only: \(String(describing: problem(setup)))")
    setup.perform(.openTerminal)
    expect(await waitUntil { recorder.closes == 1 }, "closed after the hand-off")
    expect(recorder.handoffs == [.init(tabName: "workbox", argv: nil)], "a shell tab: \(recorder.handoffs)")
    expect(invocations("herdr-arguments.log").isEmpty, "herdr not run")

    // Unreachable: Try Again only.
    reset(scenario: "network", knownHosts: known)
    (setup, recorder) = makeSetup()
    await runAdd(setup)
    expect(problem(setup)?.1 == [.tryAgain] && problem(setup)?.0.contains("Connection refused") == true, "network: \(String(describing: problem(setup)))")

    // A jump host whose key isn't known: to a terminal, adding it there.
    reset(scenario: "jump-unknown", knownHosts: known)
    (setup, recorder) = makeSetup()
    await runAdd(setup)
    expect(problem(setup)?.1 == [.continueInTerminal, .tryAgain], "jump host: \(String(describing: problem(setup)))")
    setup.perform(.continueInTerminal)
    expect(await waitUntil { recorder.closes == 1 }, "closed after the hand-off")
    expect(recorder.handoffs == [.init(tabName: "Add workbox", argv: ["herdr", "machine", "add", "workbox", "--label", "workbox"])], "herdr machine add in a tab: \(recorder.handoffs)")

    // herdr wants approval to install itself there: to a terminal.
    for add in ["approval", "not-ready"] {
        reset(add: add, knownHosts: known)
        (setup, recorder) = makeSetup()
        await runAdd(setup)
        expect(problem(setup)?.1 == [.continueInTerminal, .tryAgain], "\(add): \(String(describing: problem(setup)))")
        expect(states(setup) == [.passed, .passed, .passed, .failed], "\(add): save failed: \(states(setup))")
        expect(catalog().isEmpty, "\(add): nothing saved")
    }

    // herdr turns the name down: back to the name, with herdr's reason.
    reset(add: "invalid", knownHosts: known)
    (setup, recorder) = makeSetup()
    await runAdd(setup)
    expect(setup.stage == .name && setup.inputError?.contains("128 bytes") == true, "back to the name: \(setup.stage) \(String(describing: setup.inputError))")

    // Stopped while saving: herdr ended and cleaned up after, and the list
    // read for a late save.
    reset(add: "hang", knownHosts: known)
    (setup, recorder) = makeSetup()
    _ = setup.chooseTarget("workbox")
    _ = setup.chooseName("wb")
    expect(await waitUntil(30) { setup.isSaving && !fake("herdr-ssh-dir").isEmpty }, "saving")
    setup.stop()
    expect(await waitUntil(30) { setup.prompt != nil }, "stopped")
    expect(problem(setup)?.0.contains("Stopped") == true && problem(setup)?.1 == [.tryAgain, .continueInTerminal], "stopped: \(String(describing: problem(setup)))")
    expect(states(setup).last == .stopped, "save stopped: \(states(setup))")
    expect(fake("control.log") == "exit workbox\n", "master ended")
    expect(invocations("herdr-arguments.log").last == ["machine", "list", "--json"], "list read again")

    // Saved just before the Stop: found in the list, and taken as saved.
    reset(add: "save-then-hang", knownHosts: known)
    (setup, recorder) = makeSetup()
    _ = setup.chooseTarget("workbox")
    _ = setup.chooseName("wb")
    expect(await waitUntil(30) { setup.isSaving && !fake("herdr-ssh-dir").isEmpty }, "saving")
    setup.close()
    expect(recorder.closes == 1 && recorder.ends == 0, "closed, still ending")
    expect(await waitUntil(30) { recorder.ends == 1 }, "ended once the save had")
    expect(setup.savedMachineID == "0123456789abcdef0123456789abcdef" && recorder.changes == 1, "late save found")

    // Checking a failing machine again.
    reset(knownHosts: known)
    write("catalog", "0123456789abcdef0123456789abcdef|wb|workbox|default|true\n")
    let machine = catalog()[0]
    (setup, recorder) = makeSetup(.reconnect(machine))
    setup.begin()
    expect(setup.stage == .checks && setup.target == "workbox" && setup.label == "wb", "checks straight away")
    expect(await waitUntil(30) { setup.prompt != nil }, "reconnect finished")
    if case .finished = setup.prompt {} else { expect(false, "reconnected: \(String(describing: setup.prompt))") }
    expect(states(setup) == [.passed, .passed, .passed, .passed] && setup.checks.last?.kind == .reconnect, "reconnect checks: \(states(setup))")
    expect(invocations("herdr-arguments.log") == [["--machine", machine.id, "status", "server"]], "status asked: \(invocations("herdr-arguments.log"))")
    expect(recorder.changes == 1, "board told")
    setup.stepBack()
    expect(setup.stage == .checks, "nothing before a reconnect's checks")

    reset(status: "not-ready", knownHosts: known)
    write("catalog", "0123456789abcdef0123456789abcdef|wb|workbox|default|true\n")
    (setup, recorder) = makeSetup(.reconnect(machine))
    setup.begin()
    expect(await waitUntil(30) { setup.prompt != nil }, "reconnect stopped")
    expect(problem(setup)?.1 == [.continueInTerminal, .tryAgain], "not ready: \(String(describing: problem(setup)))")
    setup.perform(.continueInTerminal)
    expect(await waitUntil { recorder.closes == 1 }, "closed after the hand-off")
    expect(recorder.handoffs == [.init(tabName: "Reconnect wb", argv: ["herdr", "--remote", "workbox", "--session", "default"])], "herdr's own command: \(recorder.handoffs)")

    // Backspace from the checks goes back to the name, and from there to
    // the target.
    reset(scenario: "network", knownHosts: known)
    (setup, recorder) = makeSetup()
    await runAdd(setup)
    setup.stepBack()
    expect(setup.stage == .name && setup.checks.isEmpty && setup.prompt == nil, "back to the name")
    setup.stepBack()
    expect(setup.stage == .target, "back to the target")
}

func platformName() -> String {
    var info = utsname()
    uname(&info)
    func text<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    return "\(text(info.sysname)) \(text(info.machine))"
}

// MARK: - Rules, aliases, removal, the launcher, the monitor

func ruleTests() {
    let saved = [
        HerdrMachine(id: "0123456789abcdef0123456789abcdef", label: "workbox", target: "workbox", session: "default", enabled: false),
        HerdrMachine(id: "fedcba9876543210fedcba9876543210", label: "gpu", target: "gpu", session: "agents", enabled: true),
    ]
    expect(HerdrMachineSetup.targetProblem("", saved: saved) != nil, "empty target")
    expect(HerdrMachineSetup.targetProblem("-oProxyCommand=x", saved: saved) != nil, "option-like target")
    expect(HerdrMachineSetup.targetProblem("dev@work box", saved: saved) != nil, "space in target")
    expect(HerdrMachineSetup.targetProblem("dev:secret@workbox", saved: saved) != nil, "password in target")
    expect(HerdrMachineSetup.targetProblem("ssh://dev:secret@workbox:22", saved: saved) != nil, "password in URI")
    expect(HerdrMachineSetup.targetProblem("workbox", saved: saved)?.contains("workbox") == true, "same target and session, even off")
    expect(HerdrMachineSetup.targetProblem("gpu", saved: saved) == nil, "same target, another session")
    expect(HerdrMachineSetup.targetProblem("ssh://dev@[fe80::1]:2222", saved: saved) == nil, "URI target")
    expect(HerdrMachineSetup.labelProblem("workbox", saved: saved) != nil, "label of a disabled machine")
    expect(HerdrMachineSetup.labelProblem("fedcba9876543210fedcba9876543210", saved: saved) != nil, "label that is an ID")
    expect(HerdrMachineSetup.labelProblem(String(repeating: "가", count: 43), saved: saved) != nil, "label over 128 bytes")
    expect(HerdrMachineSetup.labelProblem("a\tb", saved: saved) != nil, "label with a control character")
    expect(HerdrMachineSetup.labelProblem("Workbox", saved: saved) == nil, "labels are told apart by case, as herdr does")
    expect(HerdrMachineSetup.suggestedLabel(for: "workbox", saved: saved) == "workbox 2", "made unique")
    expect(HerdrMachineSetup.suggestedLabel(for: "dev@10.0.0.5", saved: saved) == "10.0.0.5", "host of user@host")
    expect(HerdrMachineSetup.suggestedLabel(for: "ssh://dev@[fe80::1]:2222", saved: saved) == "fe80::1", "host of a URI")
    expect(HerdrMachineSetup.suggestedLabel(for: "build:2222", saved: saved) == "build", "host without its port")
}

func aliasTests() async {
    reset()
    let ssh = home + "/.ssh"
    try! FileManager.default.createDirectory(atPath: ssh + "/config.d", withIntermediateDirectories: true)
    try! """
        # Machines
        Host workbox gpu-* !bad other?
          HostName 10.0.0.5
        Host="quoted alias"
        Include config.d/*
        Match host jump
          User admin
        """.write(toFile: ssh + "/config", atomically: true, encoding: .utf8)
    try! "Host one\nInclude ~/.ssh/second\n".write(toFile: ssh + "/config.d/a file", atomically: true, encoding: .utf8)
    try! "host second\ninclude \(ssh)/third\n".write(toFile: ssh + "/second", atomically: true, encoding: .utf8)
    try! "Host third\nInclude fourth\n".write(toFile: ssh + "/third", atomically: true, encoding: .utf8)
    try! "Host fourth\n".write(toFile: ssh + "/fourth", atomically: true, encoding: .utf8)
    let (setup, _) = makeSetup()
    setup.begin()
    expect(await waitUntil { !setup.hostAliases.isEmpty && setup.hostAliases.contains("third") }, "aliases read: \(setup.hostAliases)")
    try? await Task.sleep(for: .milliseconds(300))
    expect(setup.hostAliases == ["workbox", "quoted alias", "one", "second", "third"], "aliases, three includes deep: \(setup.hostAliases)")
    expect(SSHConfigHosts.parse("Host a\n  Include x y\n").includes == ["x", "y"], "includes")
    setup.close()
}

func removalTests() async {
    reset()
    write("catalog", "0123456789abcdef0123456789abcdef|wb|workbox|default|true\n")
    let machine = catalog()[0]
    do {
        try await HerdrMachineRemoval.remove(machine, using: runner)
        expect(catalog().isEmpty, "removed from herdr's list")
        try await HerdrMachineRemoval.remove(machine, using: runner)
    } catch {
        expect(false, "remove, and remove again: \(error)")
    }
    expect(invocations("herdr-arguments.log") == [["machine", "remove", machine.id], ["machine", "remove", machine.id]], "remove arguments")
    write("herdr-remove", "fail")
    do {
        try await HerdrMachineRemoval.remove(machine, using: runner)
        expect(false, "a failed remove throws")
    } catch let error as HerdrCommandError {
        expect(error.status == 2 && error.message == "unsupported endpoint catalog version 9; expected 1", "herdr's reason: \(error.message)")
    } catch {
        expect(false, "unexpected \(error)")
    }
}

func launcherTests() {
    let host = LaunchTarget(herdrMachine: nil, label: "This Mac", workspaces: [], unavailableReason: nil)
    let gpu = LaunchTarget(herdrMachine: HerdrMachine(id: "fedcba9876543210fedcba9876543210", label: "gpu", target: "gpu", session: "default", enabled: true),
                           label: "gpu", workspaces: [], unavailableReason: "Loading…")
    let alone = LauncherMachineStep(targets: [host], addHerdrMachine: nil)
    expect(!alone.canGoBack && alone.entries(matching: "").count == 1, "no herdr machines offered: nothing to go back to")
    let offered = LauncherMachineStep(targets: [host], addHerdrMachine: AddHerdrMachineOffer(unavailableReason: nil))
    expect(offered.canGoBack, "Backspace goes back to the Add row with no herdr machine saved")
    expect(offered.entries(matching: "").map(\.id) == ["target/host", "add-herdr-machine"], "Add row last: \(offered.entries(matching: "").map(\.id))")
    expect(offered.entries(matching: "zzz").map(\.id) == ["add-herdr-machine"], "Add row whatever is typed")
    expect(offered.entries(matching: "").allSatisfy(\.isEnabled), "Add row usable")
    let blocked = LauncherMachineStep(targets: [host, gpu], addHerdrMachine: AddHerdrMachineOffer(unavailableReason: "too old"))
    expect(blocked.entries(matching: "g").map(\.isEnabled) == [false, false], "a target loading and the Add row blocked")
    expect(LauncherMachineStep(targets: [host, gpu], addHerdrMachine: nil).canGoBack, "two targets: Backspace goes back")
}

/// A host for `MachineMonitor` whose herdr is first too old to list herdr
/// machines and then lists one enabled and one disabled.
actor ListingHerdr: HerdrTransport {
    var old = true
    func update() { old = false }
    func connect() async throws {}
    func disconnect() async {}
    func send(method: String, params: JSONValue) async throws -> JSONValue {
        .object(["snapshot": .object(["panes": .array([]), "tabs": .array([]), "layouts": .array([]), "workspaces": .array([])])])
    }
    func runHerdr(_ arguments: [String]) async throws -> Data {
        if arguments == ["machine", "list", "--json"] {
            if old { throw HerdrCommandError(status: 2, message: "unknown command: machine\nrun 'herdr --help' for usage\n") }
            return Data("""
                [{"id":"0123456789abcdef0123456789abcdef","label":"on","target":"on","session":"default","enabled":true,"selected":false},
                 {"id":"fedcba9876543210fedcba9876543210","label":"off","target":"off","session":"default","enabled":false,"selected":false}]
                """.utf8)
        }
        return Data(#"{"result":{"snapshot":{"panes":[],"tabs":[],"layouts":[],"workspaces":[]}}}"#.utf8)
    }
    func runScript(_ script: String) async throws -> Data { Data() }
}

func monitorTests() async {
    let herdr = ListingHerdr()
    var timing = MachineMonitor.Timing()
    timing.herdrMachineInterval = .milliseconds(100)
    timing.stopDelay = .milliseconds(10)
    let monitor = MachineMonitor(makeClient: { HerdrClient(transport: herdr) }, pinHostKey: { _ in }, pollInterval: .milliseconds(200), listener: nil, timing: timing)
    expect(!monitor.canManageHerdrMachines && monitor.herdrMachineManagementBlocker != nil, "nothing known yet")
    monitor.isWatched = true
    expect(await waitUntil { monitor.herdrMachineListError != nil }, "list failure kept")
    expect(monitor.herdrMachineListError?.contains("0.9.0") == true && !monitor.canManageHerdrMachines, "too old said: \(String(describing: monitor.herdrMachineListError))")
    expect(monitor.herdrMachineManagementBlocker == monitor.herdrMachineListError, "the menus' reason")
    await herdr.update()
    monitor.refreshNow()
    expect(await waitUntil { monitor.canManageHerdrMachines }, "listed after the update")
    expect(monitor.savedHerdrMachines?.map(\.label) == ["on", "off"] && monitor.herdrMachineGroups.map(\.machine.label) == ["on"], "disabled kept for names, not grouped")
    expect(monitor.herdrMachineListError == nil && monitor.herdrMachineManagementBlocker == nil, "failure cleared")
    monitor.isWatched = false
}

@main
struct HerdrMachineSetupTests {
    static func main() async {
        signInFixtures()
        herdrFixtures()
        resolveFixtures()
        fingerprintFixtures()
        ruleTests()
        launcherTests()
        await wrapperTests()
        await herdrCleanupTests()
        await knownHostsTests()
        await removalTests()
        await aliasTests()
        await flowTests()
        await monitorTests()
        print("\(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
