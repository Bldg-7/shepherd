import Foundation

nonisolated struct PasswordManagerCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let maximumOutputBytes: Int
}

nonisolated protocol PasswordManagerCommandExecuting: Sendable {
    func isExecutable(_ url: URL) async -> Bool
    /// Must enforce the requested deadline/output cap and own cancellation.
    func execute(_ command: PasswordManagerCommand) async throws -> Data
    /// Trusted connection-only API; session must never be returned to UI or agents.
    func unlockBitwarden(_ request: BitwardenUnlockCommand) async throws -> BitwardenMemorySession
}

#if os(macOS)
nonisolated struct LocalPasswordManagerCommandExecutor: PasswordManagerCommandExecuting {
    func isExecutable(_ url: URL) async -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func execute(_ command: PasswordManagerCommand) async throws -> Data {
        do {
            return try await LocalCommand.run(
                .init(executable: command.executable, arguments: command.arguments,
                      environment: command.environment),
                timeout: command.timeout, maxOutputBytes: command.maximumOutputBytes,
                failure: { _, _ in PasswordManagerFailure.commandFailed })
        } catch is CancellationError { throw PasswordManagerFailure.cancelled }
        catch LocalCommand.CommandError.deadlineExceeded { throw PasswordManagerFailure.deadlineExceeded }
        catch LocalCommand.CommandError.outputLimitExceeded { throw PasswordManagerFailure.outputLimitExceeded }
        catch LocalCommand.CommandError.supervisionLost { throw PasswordManagerFailure.supervisionLost }
        catch let failure as PasswordManagerFailure { throw failure }
        catch { throw PasswordManagerFailure.unavailable }
    }
}
#endif
