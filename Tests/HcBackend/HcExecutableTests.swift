import Foundation

private nonisolated struct Status: Decodable, Sendable { let pid: UInt32; let live: Int }
private nonisolated struct Stopped: Decodable, Sendable { let stopped: Bool }
private enum TestFailure: Error { case assertion(String) }

@main @MainActor private struct HcExecutableTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw TestFailure.assertion(label) }; checks += 1
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, ["0.1.17"].contains(args[5]) else { throw TestFailure.assertion("missing pinned version") }
        let binary = URL(fileURLWithPath: args[1]), scopeRoot = URL(fileURLWithPath: args[2])
        let installDir = URL(fileURLWithPath: args[3]), report = URL(fileURLWithPath: args[4])
        // --- Detection: positive + negative controls against inert fixtures ---
        let staged = installDir.appendingPathComponent("hc")
        try check(FileManager.default.isExecutableFile(atPath: staged.path), "staged hc is executable")
        try check(HcExecutable.resolve(candidates: [staged]) == staged, "resolves a real staged hc")
        let missing = installDir.appendingPathComponent("hc-missing-\(UUID().uuidString)")
        try check(HcExecutable.resolve(candidates: [missing]) == nil, "missing candidate is nil")
        let directory = installDir.appendingPathComponent("dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try check(HcExecutable.resolve(candidates: [directory]) == nil, "directory is not executable")
        let inert = installDir.appendingPathComponent("hc-inert-\(UUID().uuidString)")
        try Data("not a binary".utf8).write(to: inert)
        try check(HcExecutable.resolve(candidates: [inert]) == nil, "non-executable file is not a candidate")
        // Usual-location lookup resolves a home-relative `.local/bin/hc`.
        let home = installDir.appendingPathComponent("home", isDirectory: true)
        let binDir = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let relCopy = binDir.appendingPathComponent("hc")
        try FileManager.default.copyItem(at: binary, to: relCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relCopy.path)
        let resolved = HcExecutable.candidates(home: home.path, environment: ["PATH": "/usr/bin:/bin"])
        try check(resolved.first == relCopy, "usual-location lookup resolves .local/bin/hc")
        let symlink = installDir.appendingPathComponent("hc-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: staged)
        try check(HcExecutable.resolve(candidates: [symlink]) == symlink, "package-manager symlink accepted")
        let broken = installDir.appendingPathComponent("hc-broken")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missing)
        try check(HcExecutable.resolve(candidates: [broken]) == nil, "dangling symlink rejected")
        try check(!HcExecutable.candidates(home: home.path, environment: ["PATH": ".:relative"]).contains { $0.path.contains("relative") }, "relative GUI PATH entries ignored")
        let environment = try HcConnectionPolicy.localEnvironment(home: home.path, session: "named", source: ["PATH":".:/custom/bin:/custom/bin", "HC_SOCKET":"parent", "HC_TERMINAL_ID":"parent", "SHEPHERD_BROWSER_TOKEN":"secret", "CLAUDE_CODE_OAUTH_TOKEN":"secret", "SHELL":"/bin/zsh", "SSH_AUTH_SOCK":"/owned/agent"])
        try check(environment["HC_SOCKET"] == nil && environment["HC_TERMINAL_ID"] == nil && environment["SHEPHERD_BROWSER_TOKEN"] == nil && environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil, "no parent socket or injected authority")
        try check(environment["PATH"]?.hasPrefix("/custom/bin:") == true && environment["PATH"]?.contains("/opt/homebrew/bin") == true && environment["PATH"]?.contains(":.:") == false, "GUI CLI discovery without relative PATH")
        try check(environment["HOME"] == home.path && environment["HC_SESSION"] == "named" && environment["SSH_AUTH_SOCK"] == "/owned/agent", "normal user scope and SSH agent retained")
        for invalid in ["../other", "bad/name", "-option", "a;touch x", "a\u{0000}b"] {
            do { _ = try HcConnectionPolicy.remoteCommand(session: invalid); throw TestFailure.assertion("accepted unsafe session") }
            catch HcConnectionPolicy.Failure.invalidSession { checks += 1 }
        }
        let remote = try HcConnectionPolicy.remoteCommand(session: "owned")
        try check(remote.hasPrefix("exec /bin/sh -c ") && remote.contains(".local/bin/herdr-core") && !remote.contains("zsh -ic"), "remote POSIX lookup, no interactive rc or legacy fallback")
        try Data("#!/bin/sh\nprintf '%s|%s|%s' \"$1\" \"$HC_SESSION\" \"${HC_SOCKET-unset}\"\n".utf8).write(to: relCopy)
        let probe = Process(), output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh"); probe.arguments = ["-c", remote]
        probe.environment = ["HOME":home.path, "PATH":"/usr/bin:/bin", "HC_SOCKET":"parent-should-not-be-used", "SSH_CONNECTION":"owned-fixture-no-launchd"]
        probe.standardOutput = output
        try probe.run()
        let response = output.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
        try check(probe.terminationStatus == 0 && String(decoding: response, as: UTF8.self) == "connect|owned|unset", "actual production discovery script executes hc with selected scope, never parent socket")
        // --- Bootstrap: start + connect + verify hello ---
        let scope = try HcCoreBootstrap.Scope(root: scopeRoot)
        try check(scope.socket.path.utf8.count < 104, "private socket path is bounded")
        var corePID: UInt32?
        var reaped = false
        var failure: (any Error)?
        do {
            let (transport, connection, hello) = try await HcCoreBootstrap.connect(binary: binary, scope: scope)
            try check(hello.version == "0.1.17", "hello reports the pinned version")
            try check(hello.generation == CoreWire.generation, "hello generation matches the client")
            for method in ["terminal.list", "terminal.attach", "terminal.run", "events.subscribe", "server.stop"] {
                try check(hello.methods.contains(method), "advertises \(method)")
            }
            let status: Status = try await connection.call("server.status").result()
            corePID = status.pid
            try check(status.live == 0, "fresh private core")
            let stopped: Stopped = try await connection.call("server.stop").result()
            try check(stopped.stopped, "owned core stop acknowledged")
            try await connection.close()
            let snapshot = await transport.snapshot()
            reaped = snapshot.reaped
            try check(snapshot.closed && snapshot.reaped, "bootstrap transport retired")
        } catch { failure = error }
        var result: [String: Any] = ["passed": failure == nil && reaped, "checks": checks, "coreStopped": reaped]
        if let corePID { result["corePID"] = corePID }
        if let failure { result["failure"] = String(describing: failure) }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: .atomic)
        guard failure == nil && reaped else { throw failure ?? TestFailure.assertion("cleanup unconfirmed") }
        print("PASS hc detect/bootstrap: \(checks) checks")
    }
}
