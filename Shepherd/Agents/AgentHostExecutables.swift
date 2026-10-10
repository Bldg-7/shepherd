import Foundation

/// GUI apps do not inherit an interactive shell's PATH. Discover only explicit
/// PATH entries and conventional executable/default-alias locations. Never run
/// shell startup files, scan arbitrary installed versions, or change user config.
nonisolated enum AgentHostExecutables {
    struct Resolution: Equatable, Sendable {
        let node: String
        let searchPath: String
    }

    static func resolve(home: String, environment: [String: String],
                        isExecutable: (String) -> Bool = executableFile,
                        canonicalPath: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) throws -> Resolution {
        let directories = searchDirectories(home: home, environment: environment)
        guard let candidate = directories.map({ $0 + "/node" }).first(where: isExecutable) else {
            throw AgentRuntimeError.nodeUnavailable
        }
        // fnm's multishell path can disappear when its terminal closes. Resolve
        // that alias once so generated MCP commands retain the installed binary.
        let node = canonicalPath(candidate)
        guard node.hasPrefix("/"), !node.utf8.contains(0), isExecutable(node) else {
            throw AgentRuntimeError.nodeUnavailable
        }
        let nodeDirectory = URL(fileURLWithPath: node).deletingLastPathComponent().path
        let paths = uniqueAbsoluteDirectories(directories + [nodeDirectory])
        return Resolution(node: node, searchPath: paths.joined(separator: ":"))
    }

    static func searchDirectories(home: String, environment: [String: String]) -> [String] {
        var paths = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        if let active = environment["FNM_MULTISHELL_PATH"] { paths.append(active + "/bin") }
        if let selected = environment["NVM_BIN"] { paths.append(selected) }
        if let fnm = environment["FNM_DIR"] { paths.append(fnm + "/aliases/default/bin") }
        if let volta = environment["VOLTA_HOME"] { paths.append(volta + "/bin") }
        if let data = environment["XDG_DATA_HOME"] { paths.append(data + "/fnm/aliases/default/bin") }
        if home.hasPrefix("/") {
            paths += [home + "/.local/bin", home + "/.bun/bin", home + "/.npm-global/bin",
                      home + "/.volta/bin", home + "/.nvm/current/bin"]
        }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if home.hasPrefix("/") {
            paths += [home + "/.local/share/fnm/aliases/default/bin",
                      home + "/Library/Application Support/fnm/aliases/default/bin",
                      home + "/.fnm/aliases/default/bin"]
        }
        return uniqueAbsoluteDirectories(paths)
    }

    private static func uniqueAbsoluteDirectories(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && !$0.contains(":") && !$0.utf8.contains(0) && seen.insert($0).inserted }
    }

    private static func executableFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
