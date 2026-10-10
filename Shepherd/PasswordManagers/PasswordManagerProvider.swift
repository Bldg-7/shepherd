import Foundation

// Internal app types, not an agent/MCP/UI credential endpoint.
nonisolated enum PasswordManagerFailure: String, Error, Sendable {
    case notConfigured, unavailable, unsupportedVersion, disconnected, locked
    case invalidReference, accountMismatch, malformedResponse, commandFailed
    case invalidServiceAccountToken, serviceAccountRequired, serviceAccountScopeUnavailable, serviceAccountScopeChanged
    case cancelled, deadlineExceeded, outputLimitExceeded, supervisionLost, staleOperation
}

nonisolated enum PasswordManagerConnectionState: Equatable, Sendable {
    case notConfigured, unavailable, disconnected, connecting, locked, ready
    case error(PasswordManagerFailure)
}

nonisolated enum PasswordManagerAvailability: Equatable, Sendable {
    case notConfigured, unavailable, available
}

/// Trusted caller's explicit item approval, NOT a vendor item-scoped permission.
/// Never serialize this into UI preferences or expose it to an agent.
nonisolated struct ApprovedPasswordReference: Sendable {
    let provider: PasswordManagerProviderID
    let accountID: String
    let vaultID: String?
    let itemID: String
    let field: String

    init(provider: PasswordManagerProviderID, accountID: String, vaultID: String? = nil,
         itemID: String, field: String = "password") throws {
        guard field == "password" else { throw PasswordManagerFailure.invalidReference }
        switch provider {
        case .onePassword:
            guard Self.isOPID(accountID), Self.isOPID(itemID),
                  vaultID.map(Self.isOPID) == true else { throw PasswordManagerFailure.invalidReference }
        case .bitwarden:
            guard UUID(uuidString: accountID) != nil, UUID(uuidString: itemID) != nil,
                  vaultID == nil else { throw PasswordManagerFailure.invalidReference }
        case .none: throw PasswordManagerFailure.invalidReference
        }
        self.provider = provider; self.accountID = accountID; self.vaultID = vaultID
        self.itemID = itemID; self.field = field
    }

    static func isOPID(_ value: String) -> Bool {
        value.utf8.count == 26 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }
}

/// Only the trusted integration consumes bytes. No String/description/Codable API.
/// Foundation/CLI buffers are not guaranteed to be zeroized.
nonisolated struct TrustedPasswordBytes: Sendable {
    let bytes: Data
}

nonisolated protocol PasswordManagerConnection: Sendable {
    var providerID: PasswordManagerProviderID { get }
    func availability() async -> PasswordManagerAvailability
    func connectionState() async -> PasswordManagerConnectionState
    func connect() async -> PasswordManagerConnectionState
    func disconnect() async
    func lock() async
}

// Kept separate from connection/UI interfaces. No generic agent resolve service.
nonisolated protocol TrustedPasswordResolving: Sendable {
    func resolveApprovedPassword(_ reference: ApprovedPasswordReference) async throws -> TrustedPasswordBytes
}

/// Explicit prerequisite supplied by trusted integration, never auto-discovered from
/// default vendor config. Paths must refer to a user-approved CLI/config context.
nonisolated struct PasswordManagerCLIConfiguration: Sendable {
    let executable: URL
    let homeDirectory: URL
    let configurationDirectory: URL
    let runtimeSearchPath: String
    let accountID: String
    let bitwardenServerURL: String?
    let onePasswordAuthentication: OnePasswordAuthenticationMethod

    init(executable: URL, homeDirectory: URL, configurationDirectory: URL,
         runtimeSearchPath: String, accountID: String, bitwardenServerURL: String? = nil,
         onePasswordAuthentication: OnePasswordAuthenticationMethod = .desktopApp) throws {
        guard [executable, homeDirectory, configurationDirectory].allSatisfy({
            $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.utf8.contains(0)
        }), !runtimeSearchPath.isEmpty,
        runtimeSearchPath.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) })
        else { throw PasswordManagerFailure.notConfigured }
        self.executable = executable; self.homeDirectory = homeDirectory
        self.configurationDirectory = configurationDirectory; self.runtimeSearchPath = runtimeSearchPath
        self.accountID = accountID; self.bitwardenServerURL = bitwardenServerURL
        self.onePasswordAuthentication = onePasswordAuthentication
    }
}

nonisolated enum OnePasswordAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case desktopApp, serviceAccount
}

/// Only the child op process receives this value. Not Codable, argv, defaults,
/// agent instructions, or UI output. Foundation buffers cannot promise zeroization.
nonisolated struct OnePasswordServiceAccountToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String
    init(_ input: String) throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("ops_"), value.utf8.count > 4, value.utf8.count <= 32768,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw PasswordManagerFailure.invalidServiceAccountToken
        }
        self.value = value
    }
    func childEnvironmentValue() -> String { value }
    var description: String { "<Service Account token>" }
    var debugDescription: String { description }
}

/// Authenticated provider metadata, not a user-selected filter or a claim that
/// the token is read-only. `vault list` proves readable vaults, not absence of
/// write/share/create permissions. No item listing or secret material here.
nonisolated struct OnePasswordServiceAccountAccess: Equatable, Sendable {
    nonisolated struct Vault: Decodable, Equatable, Sendable {
        let id: String
        let name: String
    }
    let accountID: String
    let serviceAccountID: String
    let vaults: [Vault]
    var vaultIDs: Set<String> { Set(vaults.map(\.id)) }
}

/// Session is supplied in memory by trusted connection-only human unlock.
/// Never pass this through UI, preferences, argv or logs.
nonisolated struct BitwardenMemorySession: Sendable {
    fileprivate let value: String
    init(bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 8192,
              let value = String(data: bytes, encoding: .utf8), !value.utf8.contains(0)
        else { throw PasswordManagerFailure.locked }
        self.value = value
    }
    func childEnvironmentValue() -> String { value }
}
