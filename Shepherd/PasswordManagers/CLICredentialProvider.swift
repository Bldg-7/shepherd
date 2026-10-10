import Foundation

/// Official op desktop integration / bw CLI prerequisites. No installation,
/// login, automatic unlock, config discovery, HTTP server or browser wiring.
/// Explicit connection-only BW unlock may use the selected vendor-owned context.
/// `ready` proves only current account authentication, not item access, remote
/// revocation freshness or a successful browser fill. Selection is independent.
actor CLICredentialProvider: PasswordManagerConnection, TrustedPasswordResolving {
    nonisolated let providerID: PasswordManagerProviderID
    private let configuration: PasswordManagerCLIConfiguration?
    private let executor: any PasswordManagerCommandExecuting
    private let onInvalidation: @Sendable (PasswordManagerConnectionState) -> Void
    private var session: BitwardenMemorySession?
    private var serviceAccountToken: OnePasswordServiceAccountToken?
    private var serviceAccountAccess: OnePasswordServiceAccountAccess?
    private var state: PasswordManagerConnectionState = .notConfigured
    private var generation: UInt64 = 0
    private var inFlight: [UUID: Task<Data, Error>] = [:]
    private var unlockTask: Task<BitwardenMemorySession, Error>?

    // Deliberately exact allowlist; newer/older binaries fail closed until reviewed.
    nonisolated static let supportedOPVersion = "2.32.0"
    nonisolated static let supportedBWVersion = "2025.11.0"

    init(providerID: PasswordManagerProviderID, configuration: PasswordManagerCLIConfiguration?,
         executor: any PasswordManagerCommandExecuting,
         serviceAccountToken: OnePasswordServiceAccountToken? = nil,
         onInvalidation: @escaping @Sendable (PasswordManagerConnectionState) -> Void = { _ in }) throws {
        guard providerID != .none else { throw PasswordManagerFailure.notConfigured }
        if let configuration {
            switch providerID {
            case .onePassword:
                guard ApprovedPasswordReference.isOPID(configuration.accountID) else { throw PasswordManagerFailure.notConfigured }
                guard (configuration.onePasswordAuthentication == .serviceAccount) == (serviceAccountToken != nil) else {
                    throw PasswordManagerFailure.invalidServiceAccountToken
                }
            case .bitwarden:
                guard configuration.onePasswordAuthentication == .desktopApp, serviceAccountToken == nil,
                      UUID(uuidString: configuration.accountID) != nil,
                      let server = configuration.bitwardenServerURL, let url = URL(string: server),
                      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil else { throw PasswordManagerFailure.notConfigured }
            case .none: break
            }
        }
        guard configuration != nil || serviceAccountToken == nil else { throw PasswordManagerFailure.notConfigured }
        self.providerID = providerID; self.configuration = configuration; self.executor = executor
        self.serviceAccountToken = serviceAccountToken
        self.onInvalidation = onInvalidation
        state = configuration == nil ? .notConfigured : .disconnected
    }

    func availability() async -> PasswordManagerAvailability {
        guard let configuration else { return .notConfigured }
        return await executor.isExecutable(configuration.executable) ? .available : .unavailable
    }

    func connectionState() -> PasswordManagerConnectionState { state }

    func serviceAccountAccessSnapshot() -> OnePasswordServiceAccountAccess? {
        state == .ready ? serviceAccountAccess : nil
    }

    /// Replacing a session invalidates every outstanding authentication/read.
    /// The integration must call lock/disconnect on external lifecycle revocation.
    func supplyBitwardenSession(_ newSession: BitwardenMemorySession) throws {
        guard providerID == .bitwarden, configuration != nil else { throw PasswordManagerFailure.notConfigured }
        invalidate(); session = newSession; state = .disconnected
    }

    func disconnect() {
        invalidate(); session = nil; serviceAccountToken = nil
        state = configuration == nil ? .notConfigured : .disconnected
        onInvalidation(state)
    }
    /// Local capability lock, NOT a `bw lock` command nor a claim to lock vendor UI.
    func lock() {
        invalidate(); session = nil; serviceAccountToken = nil
        state = configuration == nil ? .notConfigured : .locked
        onInvalidation(state)
    }

    func connect() async -> PasswordManagerConnectionState {
        invalidate()
        let epoch = generation
        state = .connecting
        do {
            try await authenticate(epoch)
            try check(epoch)
            state = .ready
        } catch {
            if generation == epoch {
                invalidate(); serviceAccountToken = nil; state = failureState(error); onInvalidation(state)
            }
        }
        return state
    }

    /// Explicit human unlock, never login/SSO/2FA or a public session-return API.
    func unlockBitwarden(masterPassword: String) async -> PasswordManagerConnectionState {
        invalidate()
        let epoch = generation
        state = .connecting
        do {
            guard providerID == .bitwarden, let configuration else { throw PasswordManagerFailure.notConfigured }
            session = nil
            try await verifyVersion(epoch)
            // Prove the selected vendor-owned authenticated context before sending a password.
            let status = try await bitwardenStatus(epoch)
            try validateBitwardenIdentity(status)
            guard status.status == "locked" || status.status == "unlocked" else {
                throw PasswordManagerFailure.malformedResponse
            }
            let executor = executor
            let task = Task { try await executor.unlockBitwarden(.init(configuration: configuration, masterPassword: masterPassword)) }
            unlockTask = task
            defer { if generation == epoch { unlockTask = nil } }
            let newSession = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try check(epoch)
            session = newSession
            try await authenticate(epoch)
            try check(epoch)
            state = .ready
        } catch {
            if generation == epoch { invalidate(); session = nil; state = failureState(error); onInvalidation(state) }
        }
        return state
    }

    func resolveApprovedPassword(_ reference: ApprovedPasswordReference) async throws -> TrustedPasswordBytes {
        guard let configuration else { throw PasswordManagerFailure.notConfigured }
        guard reference.provider == providerID, reference.accountID == configuration.accountID else {
            throw PasswordManagerFailure.accountMismatch
        }
        guard state == .ready else {
            throw state == .locked ? PasswordManagerFailure.locked : PasswordManagerFailure.disconnected
        }
        let epoch = generation
        do {
            try await authenticate(epoch)
            let arguments: [String]
            switch providerID {
            case .onePassword:
                guard let vault = reference.vaultID else { throw PasswordManagerFailure.invalidReference }
                if configuration.onePasswordAuthentication == .serviceAccount {
                    guard serviceAccountAccess?.vaultIDs.contains(vault) == true else {
                        throw PasswordManagerFailure.invalidReference
                    }
                    // The token, not --account or a local filter, is the authority.
                    arguments = ["read", "op://\(vault)/\(reference.itemID)/password", "--no-newline", "--cache=false"]
                } else {
                    arguments = ["read", "op://\(vault)/\(reference.itemID)/password", "--no-newline",
                                 "--account", configuration.accountID, "--cache=false"]
                }
            case .bitwarden:
                arguments = ["get", "password", reference.itemID, "--raw", "--nointeraction"]
            case .none: throw PasswordManagerFailure.notConfigured
            }
            let bytes = try await run(arguments, epoch: epoch, limit: 16 * 1024)
            // Do not strip newlines: --no-newline/--raw define the stdout contract.
            try await authenticate(epoch)
            try check(epoch)
            return TrustedPasswordBytes(bytes: bytes)
        } catch {
            let failure = sanitized(error)
            if generation == epoch {
                invalidate(); serviceAccountToken = nil; state = failureState(failure); onInvalidation(state)
            }
            throw failure
        }
    }

    private func invalidate() {
        serviceAccountAccess = nil
        generation &+= 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        unlockTask?.cancel()
        unlockTask = nil
    }

    private func check(_ epoch: UInt64) throws {
        guard generation == epoch else { throw PasswordManagerFailure.staleOperation }
        if Task.isCancelled { throw PasswordManagerFailure.cancelled }
    }

    private func verifyVersion(_ epoch: UInt64) async throws {
        guard let configuration else { throw PasswordManagerFailure.notConfigured }
        try check(epoch)
        guard await executor.isExecutable(configuration.executable) else { throw PasswordManagerFailure.unavailable }
        try check(epoch)
        let versionData = try await run(["--version"], epoch: epoch, limit: 1024)
        guard let version = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              version == (providerID == .onePassword ? Self.supportedOPVersion : Self.supportedBWVersion)
        else { throw PasswordManagerFailure.unsupportedVersion }
    }

    private struct BitwardenStatus: Decodable { let serverUrl: String?; let userId: String?; let status: String }

    private func bitwardenStatus(_ epoch: UInt64) async throws -> BitwardenStatus {
        let data = try await run(["status", "--nointeraction"], epoch: epoch, limit: 8192)
        guard let status = try? JSONDecoder().decode(BitwardenStatus.self, from: data) else {
            throw PasswordManagerFailure.malformedResponse
        }
        return status
    }

    private func validateBitwardenIdentity(_ status: BitwardenStatus) throws {
        guard let configuration else { throw PasswordManagerFailure.notConfigured }
        if status.status == "unauthenticated" { throw PasswordManagerFailure.disconnected }
        guard status.userId?.lowercased() == configuration.accountID.lowercased(),
              status.serverUrl == configuration.bitwardenServerURL else { throw PasswordManagerFailure.accountMismatch }
    }

    private func authenticate(_ epoch: UInt64) async throws {
        guard let configuration else { throw PasswordManagerFailure.notConfigured }
        try await verifyVersion(epoch)
        if providerID == .onePassword {
            if configuration.onePasswordAuthentication == .serviceAccount {
                try await authenticateServiceAccount(epoch)
            } else {
                // Official --account explicitly selects this ID. whoami exits
                // nonzero if not authenticated; no output is exposed to UI.
                _ = try await run(["whoami", "--account", configuration.accountID], epoch: epoch, limit: 4096)
            }
        } else {
            guard session != nil else { throw PasswordManagerFailure.locked }
            let status = try await bitwardenStatus(epoch)
            try validateBitwardenIdentity(status)
            if status.status == "locked" { throw PasswordManagerFailure.locked }
            guard status.status == "unlocked" else { throw PasswordManagerFailure.malformedResponse }
        }
        try check(epoch)
    }

    private struct ServiceAccountIdentity: Decodable {
        let id: String
        let type: String
        let state: String
    }
    private struct AccountIdentity: Decodable { let account_uuid: String }

    private func authenticateServiceAccount(_ epoch: UInt64) async throws {
        guard let configuration, serviceAccountToken != nil else { throw PasswordManagerFailure.invalidServiceAccountToken }
        let accountData = try await run(["whoami", "--format=json", "--cache=false"], epoch: epoch, limit: 8192)
        let userData = try await run(["user", "get", "--me", "--format=json", "--cache=false"], epoch: epoch, limit: 16384)
        guard let account = try? JSONDecoder().decode(AccountIdentity.self, from: accountData),
              let user = try? JSONDecoder().decode(ServiceAccountIdentity.self, from: userData),
              ApprovedPasswordReference.isOPID(user.id) else { throw PasswordManagerFailure.malformedResponse }
        guard account.account_uuid == configuration.accountID else { throw PasswordManagerFailure.accountMismatch }
        guard user.type == "SERVICE_ACCOUNT", user.state == "ACTIVE" else { throw PasswordManagerFailure.serviceAccountRequired }
        let vaultData = try await run(["vault", "list", "--format=json", "--cache=false"], epoch: epoch, limit: 256 * 1024)
        guard let vaults = try? JSONDecoder().decode([OnePasswordServiceAccountAccess.Vault].self, from: vaultData),
              !vaults.isEmpty, vaults.count <= 512,
              Set(vaults.map(\.id)).count == vaults.count,
              vaults.allSatisfy({ ApprovedPasswordReference.isOPID($0.id) && !$0.name.isEmpty &&
                  $0.name.utf8.count <= 1024 && !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) })
        else { throw PasswordManagerFailure.serviceAccountScopeUnavailable }
        let access = OnePasswordServiceAccountAccess(accountID: account.account_uuid, serviceAccountID: user.id,
                                                      vaults: vaults.sorted { $0.id < $1.id })
        if let previous = serviceAccountAccess {
            guard previous.accountID == access.accountID, previous.serviceAccountID == access.serviceAccountID,
                  previous.vaultIDs == access.vaultIDs else { throw PasswordManagerFailure.serviceAccountScopeChanged }
        }
        try check(epoch)
        serviceAccountAccess = access
    }

    private func run(_ arguments: [String], epoch: UInt64, limit: Int) async throws -> Data {
        guard let configuration else { throw PasswordManagerFailure.notConfigured }
        try check(epoch)
        var environment = ["HOME": configuration.homeDirectory.path, "PATH": configuration.runtimeSearchPath,
                           "LANG": "en_US.UTF-8"]
        if providerID == .onePassword {
            environment["OP_CONFIG_DIR"] = configuration.configurationDirectory.path
            if configuration.onePasswordAuthentication == .serviceAccount {
                guard let serviceAccountToken else { throw PasswordManagerFailure.invalidServiceAccountToken }
                environment["OP_SERVICE_ACCOUNT_TOKEN"] = serviceAccountToken.childEnvironmentValue()
                environment["OP_BIOMETRIC_UNLOCK_ENABLED"] = "false"
                environment["OP_CACHE"] = "false"
            } else {
                environment["OP_BIOMETRIC_UNLOCK_ENABLED"] = "true"
            }
            // Environment is constructed from scratch: never inherit OP_SESSION,
            // OP_CONNECT_*, OP_ACCOUNT, debug logging, or another auth method.
        } else {
            environment["BITWARDENCLI_APPDATA_DIR"] = configuration.configurationDirectory.path
            if let session { environment["BW_SESSION"] = session.childEnvironmentValue() }
        }
        let command = PasswordManagerCommand(executable: configuration.executable, arguments: arguments,
                                             environment: environment, timeout: 15, maximumOutputBytes: limit)
        let id = UUID()
        let executor = executor
        let task = Task { try await executor.execute(command) }
        inFlight[id] = task
        defer { inFlight.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try check(epoch)
            guard result.count <= limit else { throw PasswordManagerFailure.outputLimitExceeded }
            return result
        } catch {
            try check(epoch)
            throw sanitized(error)
        }
    }

    private func sanitized(_ error: any Error) -> PasswordManagerFailure {
        if error is CancellationError { return .cancelled }
        return (error as? PasswordManagerFailure) ?? .commandFailed
    }

    private func failureState(_ error: any Error) -> PasswordManagerConnectionState {
        switch sanitized(error) {
        case .notConfigured: .notConfigured
        case .unavailable: .unavailable
        case .locked: .locked
        case .disconnected: .disconnected
        default: .error(sanitized(error))
        }
    }
}
