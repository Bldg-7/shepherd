import Foundation
#if os(macOS)
import Darwin

/// Read-only evidence, not a session-ID lookup fallback or a CLI/account probe.
/// Startup IDs are insufficient: a matching saved user/assistant conversation
/// must exist in the actual foreground CLI's local configuration and cwd.
nonisolated enum AgentSavedSession {
    enum VerificationError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            String(localized: "This session has no verified saved conversation in its current CLI configuration and folder. Send a message and wait for it to finish, then try Resume again. The original agent was not stopped.")
        }
    }

    static func verify(kind: AgentKind, sessionID: String, cwd: String?, configurationDirectory: String,
                       process: PaneProcessInfo) throws {
        guard kind.supportsLegacySessionInspection, let cwd, cwd.hasPrefix("/"), let argv = process.agentArguments(for: kind),
              !argv.contains("--no-session-persistence"), !argv.contains("--ephemeral"),
              let foreground = process.foregroundProcesses.first(where: { $0.argv == argv }),
              let environment = processEnvironment(pid: foreground.pid, expectedArguments: argv),
              let home = environment["HOME"], home.hasPrefix("/") else { throw VerificationError.unavailable }
        let actualDirectory: String
        switch kind {
        case .claude: actualDirectory = environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
        case .codex: actualDirectory = environment["CODEX_HOME"] ?? home + "/.codex"
        case .pi: throw VerificationError.unavailable
        }
        guard actualDirectory.hasPrefix("/"), canonical(actualDirectory) == canonical(configurationDirectory),
              hasSavedConversation(kind: kind, sessionID: sessionID, cwd: cwd, configurationDirectory: configurationDirectory) else {
            throw VerificationError.unavailable
        }
    }

    static func hasSavedConversation(kind: AgentKind, sessionID: String, cwd: String, configurationDirectory: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard kind.supportsLegacySessionInspection, !sessionID.isEmpty, sessionID.count <= 128, sessionID.unicodeScalars.allSatisfy(allowed.contains),
              cwd.hasPrefix("/"), configurationDirectory.hasPrefix("/") else { return false }
        let subdirectory: String
        switch kind { case .claude: subdirectory = "projects"; case .codex: subdirectory = "sessions"; case .pi: return false }
        let root = URL(fileURLWithPath: configurationDirectory).appendingPathComponent(subdirectory)
        guard owned(root, directory: true), let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
            guard file.pathExtension == "jsonl", file.lastPathComponent.contains(sessionID), owned(file, directory: false),
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            // Only metadata/roles are inspected; conversation text is never returned
            // or logged. Large/uninspectable transcripts remain fail-closed.
            guard let data = try? handle.read(upToCount: 16 * 1024 * 1024), let text = String(data: data, encoding: .utf8) else { continue }
            let rows = text.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let bytes = String(line).data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            }
            if matches(kind: kind, sessionID: sessionID, cwd: cwd, rows: rows) { return true }
        }
        return false
    }

    static func matches(kind: AgentKind, sessionID: String, cwd: String, rows: [[String: Any]]) -> Bool {
        switch kind {
        case .pi:
            // Pi JSONL active-branch + exact-file resume is a separate contract.
            return false
        case .claude:
            let matching = rows.filter { ($0["sessionId"] as? String) == sessionID && ($0["cwd"] as? String).map(canonical) == canonical(cwd) && $0["isSidechain"] as? Bool != true }
            return matching.contains { $0["type"] as? String == "user" } && matching.contains { $0["type"] as? String == "assistant" }
        case .codex:
            guard rows.contains(where: { row in
                guard row["type"] as? String == "session_meta", let payload = row["payload"] as? [String: Any] else { return false }
                return payload["id"] as? String == sessionID && (payload["cwd"] as? String).map(canonical) == canonical(cwd)
            }) else { return false }
            let messages = rows.compactMap { $0["type"] as? String == "response_item" ? $0["payload"] as? [String: Any] : nil }.filter { $0["type"] as? String == "message" }
            return messages.contains { $0["role"] as? String == "user" } && messages.contains { $0["role"] as? String == "assistant" }
        }
    }

    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    private static func owned(_ url: URL, directory: Bool) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return false }
        return true
    }

    /// Match the live kernel argv to herdr's foreground argv before using HOME
    /// or CLI-specific config overrides. No environment bytes leave this helper.
    private static func processEnvironment(pid: UInt32, expectedArguments: [String]) -> [String: String]? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        func string() -> String? {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size else { return nil }
            let value = String(bytes: bytes[start..<index], encoding: .utf8); index += 1; return value
        }
        guard string() != nil else { return nil }
        while index < size && bytes[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<argc { guard let value = string() else { return nil }; argv.append(value) }
        guard argv == expectedArguments else { return nil }
        var environment: [String: String] = [:]
        while index < size, bytes[index] != 0 {
            guard let value = string() else { return nil }
            let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { environment[String(parts[0])] = String(parts[1]) }
        }
        var current = proc_bsdinfo()
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &current, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              current.pbi_start_tvsec == info.pbi_start_tvsec, current.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
        return environment
    }
}
#endif
