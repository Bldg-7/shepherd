import Foundation

/// Product connection policy, distinct from the private direct-start bootstrap.
/// Never selects a parent terminal/socket or writes core configuration. A normal
/// hc connect may start hc's service; disconnect closes only our connect child.
public nonisolated enum HcConnectionPolicy {
    private static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static let requiredMethods: Set<String> = ["terminal.list", "terminal.get", "terminal.run", "terminal.attach", "terminal.kill", "terminal.read", "terminal.send", "terminal.keys", "events.subscribe", "doc.get", "doc.set"]
    public enum Failure: Error, Equatable, Sendable { case invalidSession, invalidHome, noExecutable, sshUnavailable, localUnavailable }

    public static func session(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "default" }
        let bytes = Array(value.utf8)
        func alnum(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) }
        guard bytes.count <= 64, let first = bytes.first, alnum(first), bytes.allSatisfy({ alnum($0) || [45,46,95].contains($0) }) else { throw Failure.invalidSession }
        return value
    }

    /// Do not propagate a parent Shepherd/browser/agent launch's authority or
    /// injected config into a service. User CLI credentials remain in their
    /// normal user-owned config, not copied into argv or this environment.
    public static func localEnvironment(home: String, session: String, source: [String: String]) throws -> [String: String] {
        guard home.hasPrefix("/"), !home.utf8.contains(0) else { throw Failure.invalidHome }
        let allowed = Set(["USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "SSH_AUTH_SOCK"])
        var result = source.filter { allowed.contains($0.key) && !$0.value.utf8.contains(0) }
        result["HOME"] = home; result["HC_SESSION"] = try self.session(session)
        var paths = (source["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += [home + "/.local/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        result["PATH"] = paths.filter { $0.hasPrefix("/") && !$0.utf8.contains(0) && seen.insert($0).inserted }.joined(separator: ":")
        return result
    }

    #if os(macOS)
    public static func localTransport(session: String = "") throws -> CoreProcessTransport {
        let home = HcExecutable.homeDirectory()
        let environment = try localEnvironment(home: home, session: session, source: ProcessInfo.processInfo.environment)
        guard let binary = HcExecutable.resolve(candidates: HcExecutable.candidates(home: home, environment: environment)) else { throw Failure.noExecutable }
        return try CoreProcessTransport(configuration: .init(executable: binary, environment: environment, directory: URL(fileURLWithPath: home)))
    }
    #endif

    /// Lookup runs in a POSIX shell, even when the SSH account uses fish. No
    /// interactive rc, eval, install or fallback to legacy herdr. All dynamic
    /// values remain shell arguments. Session/socket context is cleared before
    /// normal core discovery on the remote account.
    public static func remoteCommand(session: String) throws -> String {
        let scope = try self.session(session)
        let clear = ["HC_TERMINAL_ID", "HC_TERMINAL_SOCKET", "HC_SCOPE", "HC_SOCKET", "HERDR_CONFIG_PATH"].flatMap { ["-u", $0] }.map(shellQuoted).joined(separator: " ")
        let candidates = ["\"$HOME\"/.local/bin/hc", "\"$HOME\"/.local/bin/herdr-core", "'/opt/homebrew/bin/hc'", "'/opt/homebrew/bin/herdr-core'", "'/usr/local/bin/hc'", "'/usr/local/bin/herdr-core'"]
        let script = "for h in " + candidates.joined(separator: " ") + "; do if [ -f \"$h\" ] && [ -x \"$h\" ]; then exec env \(clear) \(shellQuoted("HC_SESSION=" + scope)) \"$h\" connect; fi; done; for n in hc herdr-core; do h=$(command -v \"$n\") || continue; if [ -f \"$h\" ] && [ -x \"$h\" ]; then exec env \(clear) \(shellQuoted("HC_SESSION=" + scope)) \"$h\" connect; fi; done; printf '%s\\n' 'Shepherd: hc is not installed' >&2; exit 127"
        return "exec /bin/sh -c " + shellQuoted(script)
    }
}
