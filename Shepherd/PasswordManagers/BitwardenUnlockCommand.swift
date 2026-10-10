import Foundation

/// Connection-only trusted request. Never Codable, described, or sent to an agent.
nonisolated struct BitwardenUnlockCommand: Sendable {
    let configuration: PasswordManagerCLIConfiguration
    let masterPassword: String
}

extension PasswordManagerCommandExecuting {
    func unlockBitwarden(_ request: BitwardenUnlockCommand) async throws -> BitwardenMemorySession {
        throw PasswordManagerFailure.unavailable
    }
}

#if os(macOS)
extension LocalPasswordManagerCommandExecutor {
    func unlockBitwarden(_ request: BitwardenUnlockCommand) async throws -> BitwardenMemorySession {
        guard !request.masterPassword.isEmpty, !request.masterPassword.utf8.contains(0) else {
            throw PasswordManagerFailure.locked
        }
        let config = request.configuration
        // Exact narrow environment; no inherited credentials and no password argv/file.
        let command = PasswordManagerCommand(
            executable: config.executable,
            arguments: ["unlock", "--passwordenv", "SHEPHERD_BW_UNLOCK_PASSWORD", "--raw", "--nointeraction"],
            environment: ["HOME": config.homeDirectory.path, "PATH": config.runtimeSearchPath,
                          "LANG": "en_US.UTF-8", "BITWARDENCLI_APPDATA_DIR": config.configurationDirectory.path,
                          "SHEPHERD_BW_UNLOCK_PASSWORD": request.masterPassword],
            timeout: 15, maximumOutputBytes: 8192)
        let bytes = try await execute(command)
        // --raw may terminate the key with a newline. Never trim password bytes.
        guard let value = String(data: bytes, encoding: .utf8) else { throw PasswordManagerFailure.malformedResponse }
        return try BitwardenMemorySession(bytes: Data(value.trimmingCharacters(in: .newlines).utf8))
    }
}
#endif
