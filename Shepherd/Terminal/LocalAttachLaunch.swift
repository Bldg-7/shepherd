import Foundation

#if os(macOS)
/// What `LocalTerminalSession` starts to attach to a pane from this Mac, in
/// one of three ways: over this Mac's `ssh` for a pane on one of its herdr
/// machines, herdr started directly where it is normally installed, or herdr
/// looked up through an interactive zsh otherwise (see `HerdrExecutable`).
///
/// Every one of them attaches with mouse capture off (see
/// `HerdrExecutable.attachConfiguration`). The two that run herdr here are
/// given this Mac's copy of the configuration through `HERDR_CONFIG_PATH`
/// when there is one; the `ssh` one makes and uses a copy on the machine,
/// and gets no `HERDR_CONFIG_PATH` of this Mac's to pass on.
nonisolated struct LocalAttachLaunch: Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String]

    /// - Parameters:
    ///   - herdrPath: herdr's usual location on this Mac, if it is in one
    ///     (`HerdrExecutable.localPath()`).
    ///   - configurationPath: this Mac's copy of the attach configuration,
    ///     or nil when it couldn't be written.
    ///   - baseEnvironment: SwiftTerm's default environment for a child.
    ///   - inherited: this app's own environment.
    static func make(terminalID: String, herdrMachine: HerdrMachine?, herdrPath: String?, configurationPath: String?,
                     baseEnvironment: [String], inherited: [String: String]) -> LocalAttachLaunch {
        if let herdrMachine {
            // A pane on one of this Mac's herdr machines is attached to over
            // this Mac's own `ssh`, the one herdr uses to reach that machine
            // (looked up on PATH, as herdr does). SwiftTerm's default
            // environment for a child has the terminal basics and who the
            // user is, but no PATH — `env` would then look only in
            // /usr/bin:/bin — and no SSH_AUTH_SOCK, without which ssh can't
            // use the agent holding the keys herdr's own requests go out
            // with. Both are passed on from the app's environment.
            var environment = baseEnvironment
            for name in ["PATH", "SSH_AUTH_SOCK"] {
                if let value = inherited[name] {
                    environment.append("\(name)=\(value)")
                }
            }
            return LocalAttachLaunch(executable: "/usr/bin/env",
                                     arguments: ["ssh"] + HerdrExecutable.sshAttachArguments(to: herdrMachine, terminalID: terminalID, withoutMouseCapture: true),
                                     environment: environment)
        }
        var environment = baseEnvironment
        if let configurationPath {
            environment.append("\(HerdrExecutable.configurationPathVariable)=\(configurationPath)")
        }
        if let herdrPath {
            return LocalAttachLaunch(executable: herdrPath, arguments: HerdrExecutable.attachArguments(terminalID: terminalID), environment: environment)
        }
        // Started directly, the arguments go straight to execvp with no
        // shell to quote for; the fallback's `-c` string is parsed by that
        // one zsh, so they are quoted for it.
        let attach = (["herdr"] + HerdrExecutable.attachArguments(terminalID: terminalID).map(shellQuoted)).joined(separator: " ")
        return LocalAttachLaunch(executable: "/bin/zsh", arguments: ["-ic", attach], environment: environment)
    }

    /// The folder in this app's caches that holds this Mac's copy of the
    /// attach configuration.
    static var configurationFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "com.bldg-7.shepherd", directoryHint: .isDirectory)
    }
}
#endif
