import Foundation

nonisolated private struct SyntheticExit: Error { let status: Int }
nonisolated private func expect(_ value: Bool) { precondition(value) }

@main struct AgentHostExecutablesTests {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--probe" {
            // Read executable metadata only. No user config or CLI invocation.
            let result = try AgentHostExecutables.resolve(home: CommandLine.arguments[2], environment: ["PATH":"/usr/bin:/bin"])
            let data = try JSONSerialization.data(withJSONObject: ["node":result.node,"searchPath":result.searchPath], options: .sortedKeys)
            print(String(decoding: data, as: UTF8.self)); return
        }
        let home = "/owned/home"
        let gui = ["PATH":"/usr/bin:/bin"]
        func resolves(_ node: String, environment: [String:String] = ["PATH":"/usr/bin:/bin"]) throws -> AgentHostExecutables.Resolution {
            try AgentHostExecutables.resolve(home: home, environment: environment,
                isExecutable: { $0 == node }, canonicalPath: { $0 })
        }
        expect(try resolves("/opt/homebrew/bin/node").node == "/opt/homebrew/bin/node")
        expect(try resolves("/usr/local/bin/node").node == "/usr/local/bin/node")
        expect(try resolves(home + "/.volta/bin/node").node == home + "/.volta/bin/node")
        expect(try resolves(home + "/.local/share/fnm/aliases/default/bin/node").node.hasSuffix("/bin/node"))
        expect(try resolves(home + "/Library/Application Support/fnm/aliases/default/bin/node").node.contains("Application Support"))
        expect(try resolves("/custom/fnm/aliases/default/bin/node", environment: ["FNM_DIR":"/custom/fnm"]).node.hasPrefix("/custom/fnm"))
        expect(try resolves("/custom/nvm/bin/node", environment: ["NVM_BIN":"/custom/nvm/bin"]).node.hasPrefix("/custom/nvm"))
        let ordered = try AgentHostExecutables.resolve(home: home, environment: ["PATH":"/preferred:/usr/bin:/preferred::.:relative"],
            isExecutable: { ["/preferred/node", "/opt/homebrew/bin/node"].contains($0) }, canonicalPath: { $0 })
        precondition(ordered.node == "/preferred/node")
        let dirs = ordered.searchPath.split(separator: ":").map(String.init)
        precondition(dirs.first == "/preferred" && Set(dirs).count == dirs.count)
        precondition(dirs.allSatisfy { $0.hasPrefix("/") })
        do {
            _ = try AgentHostExecutables.resolve(home: home, environment: gui, isExecutable: { _ in false })
            preconditionFailure("missing Node accepted")
        } catch AgentRuntimeError.nodeUnavailable {}

        // Real filesystem/shell test with only synthetic executables. No shell
        // rc files, actual agent CLIs or vendor accounts are accessed.
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("home with 'quotes'")
        let nodeRoot = root.appendingPathComponent(".local/share/fnm/node-versions/v26.1.0/installation")
        let node = nodeRoot.appendingPathComponent("bin/node")
        let alias = root.appendingPathComponent(".local/share/fnm/aliases/default")
        let agents = root.appendingPathComponent(".local/bin")
        let empty = root.appendingPathComponent("empty-path")
        for dir in [node.deletingLastPathComponent(), alias.deletingLastPathComponent(), agents, empty] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nodeRoot)
        func executable(_ url: URL, _ text: String) throws {
            try Data(("#!/bin/sh\n" + text).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try executable(node, "IFS= read -r request || true\n[ \"$(claude --version)\" = 'synthetic-claude' ] || exit 31\n[ \"$(codex --version)\" = 'synthetic-codex' ] || exit 32\nprintf '%s\\n' '{\"ok\":true,\"result\":{\"installation\":null}}'\n")
        try executable(agents.appendingPathComponent("claude"), "printf 'synthetic-claude'\n")
        try executable(agents.appendingPathComponent("codex"), "printf 'synthetic-codex'\n")
        let restricted = ["HOME":root.path, "PATH":empty.path]
        let before = ProcessInfo.processInfo.environment["PATH"]
        let resolution = try AgentHostExecutables.resolve(home: root.path, environment: restricted,
            isExecutable: { $0.hasPrefix(root.path + "/") && FileManager.default.isExecutableFile(atPath: $0) })
        precondition(resolution.node == node.path, "use stable installation, not transient/default symlink")
        precondition(resolution.searchPath.contains(agents.path))
        let run: @Sendable (String) async throws -> Data = { script in
            try await LocalCommand.run(.init(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c",script], environment: restricted), timeout: 10) { status, _ in SyntheticExit(status: status) }
        }
        let broken = AgentRuntime(root: root.path, resourceDirectory: root.path, scriptRunner: run)
        do { _ = try await broken.installation(on: .thisMac); preconditionFailure("bare node unexpectedly found") }
        catch let failure as SyntheticExit { precondition(failure.status == 127) }
        let fixed = AgentRuntime(root: root.path, resourceDirectory: root.path, nodeExecutable: resolution.node,
                                 executionSearchPath: resolution.searchPath, scriptRunner: run)
        let status = try await fixed.installation(on: .thisMac)
        precondition(status == nil)
        precondition(ProcessInfo.processInfo.environment["PATH"] == before, "parent PATH changed")
        let invalid = AgentRuntime(root: root.path, resourceDirectory: root.path, executionSearchPath: "/bad\0path",
                                   scriptRunner: { _ in preconditionFailure("invalid PATH reached shell") })
        do { _ = try await invalid.installation(on: .thisMac); preconditionFailure("NUL accepted") }
        catch AgentRuntimeError.rejected(let code) { precondition(code == "invalid-executable-search-path") }
        print("PASS GUI executable discovery: PATH precedence, Homebrew/fnm/Volta/explicit managers, missing Node, canonical alias, quoted paths, baseline command-not-found, private child PATH for Node/Claude/Codex, unchanged parent environment")
    }
}
