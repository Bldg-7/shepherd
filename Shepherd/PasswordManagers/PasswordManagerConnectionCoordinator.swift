#if os(macOS)
import Foundation
import Observation

/// Explicitly entered private metadata only. No password or session fields.
nonisolated struct PasswordManagerConnectionMetadata: Codable, Equatable, Sendable {
    var executable = ""
    var homeDirectory = ""
    var configurationDirectory = ""
    var runtimeSearchPath = ""
    var accountID = ""
    var serverURL = ""
    // Optional for backward-compatible decoding of existing private metadata.
    // Missing means desktop app; unknown values fail decoding, never downgrade.
    var onePasswordAuthentication: OnePasswordAuthenticationMethod? = nil

    func configuration() throws -> PasswordManagerCLIConfiguration {
        guard [executable, homeDirectory, configurationDirectory].allSatisfy({
            $0.hasPrefix("/") && !$0.utf8.contains(0)
        }) else { throw PasswordManagerFailure.notConfigured }
        return try .init(executable: URL(fileURLWithPath: executable),
                         homeDirectory: URL(fileURLWithPath: homeDirectory),
                         configurationDirectory: URL(fileURLWithPath: configurationDirectory),
                         runtimeSearchPath: runtimeSearchPath, accountID: accountID,
                         bitwardenServerURL: serverURL.isEmpty ? nil : serverURL,
                         onePasswordAuthentication: onePasswordAuthentication ?? .desktopApp)
    }
}

/// App-owned single operation/presentation lease across all Settings windows.
/// Restart restores metadata only, never a connection or authorization.
@MainActor @Observable
final class PasswordManagerConnectionCoordinator {
    private(set) var owner: UUID?
    private(set) var providerID: PasswordManagerProviderID = .none
    private(set) var state: PasswordManagerConnectionState = .notConfigured
    private(set) var generation: UInt64 = 0
    private(set) var serviceAccountAccess: OnePasswordServiceAccountAccess?
    @ObservationIgnored private var connectedAccountID: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let executor: any PasswordManagerCommandExecuting
    @ObservationIgnored private var provider: CLICredentialProvider?
    @ObservationIgnored private var operation: Task<Void, Never>?
    private(set) var isRevoking = false
    @ObservationIgnored private var providerRevocation = CredentialRevocationLease()
    @ObservationIgnored private var credentialRevocation: Task<Void, Never>?
    /// Integration attaches the actor; connection Ready alone never enables it.
    @ObservationIgnored var credentialBroker: CredentialBroker?
    var credentialGrantController: CredentialGrantController?

    func trustedCredentialLease() -> TrustedCredentialProviderLease? {
        guard !isRevoking, providerRevocation.isValid, state == .ready, let provider, let connectedAccountID else { return nil }
        return TrustedCredentialProviderLease(epoch: generation, providerID: providerID,
            accountID: connectedAccountID, resolver: provider, revocation: providerRevocation)
    }

    init(defaults: UserDefaults, executor: any PasswordManagerCommandExecuting = LocalPasswordManagerCommandExecutor()) {
        self.defaults = defaults; self.executor = executor
    }

    static func metadataKey(_ id: PasswordManagerProviderID) -> String { "shepherdPasswordManagerConnection." + id.rawValue }

    func metadata(for id: PasswordManagerProviderID) -> PasswordManagerConnectionMetadata {
        guard let data = defaults.data(forKey: Self.metadataKey(id)),
              let record = try? JSONDecoder().decode(PasswordManagerConnectionMetadata.self, from: data) else { return .init() }
        return record
    }

    @discardableResult
    func begin(owner: UUID, manager: PasswordManagerProviderID) -> Bool {
        guard manager != .none, self.owner == nil || self.owner == owner else { return false }
        if providerID != manager { cancel() }
        self.owner = owner; providerID = manager
        return true
    }

    func close(owner: UUID) {
        guard self.owner == owner else { return }
        cancel()
    }

    func configurationChanged(owner: UUID) {
        guard self.owner == owner else { return }
        let id = providerID
        cancel()
        _ = begin(owner: owner, manager: id)
    }

    /// Revokes Shepherd's local capability, not vendor-global signout/vault lock.
    func cancel() {
        providerRevocation.revoke()
        serviceAccountAccess = nil; connectedAccountID = nil
        generation &+= 1
        let epoch = generation
        isRevoking = true
        operation?.cancel(); operation = nil
        let old = provider; provider = nil
        let broker = credentialBroker
        let previous = credentialRevocation
        credentialRevocation = Task {
            await previous?.value
            await broker?.setAvailability(browserEnabled: false, provider: nil)
            if let old { await old.disconnect() }
            if self.generation == epoch { self.isRevoking = false }
        }
        owner = nil; state = .disconnected
    }

    /// Integration must await this barrier before reporting broker OFF or
    /// replacing/reenabling its provider lease. Existing synchronous callers
    /// alone do not satisfy the broker lifecycle security gate.
    func cancelAndAwaitCredentialRevocation() async {
        cancel()
        await awaitCredentialRevocation()
    }

    func awaitCredentialRevocation() async {
        // Another window may cancel/switch while this await yields MainActor.
        // Observe the latest barrier, not just the task present on entry.
        while true {
            let epoch = generation
            await credentialRevocation?.value
            if generation == epoch { return }
        }
    }

    func submit(owner: UUID, metadata: PasswordManagerConnectionMetadata, masterPassword: String,
                serviceAccountToken: String = "") {
        guard self.owner == owner, operation == nil else { return }
        let id = providerID
        // Even invalid replacement metadata must retire the old capability.
        // Preserve this window's presentation lease, not its connected provider.
        cancel()
        self.owner = owner
        let epoch = generation
        do {
            let configuration = try metadata.configuration()
            let token: OnePasswordServiceAccountToken?
            if id == .onePassword && configuration.onePasswordAuthentication == .serviceAccount {
                token = try OnePasswordServiceAccountToken(serviceAccountToken)
            } else {
                guard serviceAccountToken.isEmpty else { throw PasswordManagerFailure.invalidServiceAccountToken }
                token = nil
            }
            let newRevocation = CredentialRevocationLease()
            let newProvider = try CLICredentialProvider(providerID: id, configuration: configuration, executor: executor,
                serviceAccountToken: token, onInvalidation: { [weak self] result in
                    // Synchronous lease revocation also blocks already queued proxy
                    // writes. MainActor UI reporting is secondary, never the gate.
                    newRevocation.revoke()
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == epoch else { return }
                        self.state = result; self.serviceAccountAccess = nil
                    }
                })
            // Explicit Connect is also consent to save this metadata in private defaults.
            defaults.set(try JSONEncoder().encode(metadata), forKey: Self.metadataKey(id))
            state = .connecting
            let revocation = credentialRevocation
            operation = Task { [weak self] in
                await revocation?.value
                guard let self, self.generation == epoch, self.owner == owner, !Task.isCancelled else {
                    await newProvider.disconnect(); return
                }
                self.providerRevocation = newRevocation
                self.provider = newProvider
                let result: PasswordManagerConnectionState
                if id == .bitwarden { result = await newProvider.unlockBitwarden(masterPassword: masterPassword) }
                else { result = await newProvider.connect() }
                let access = await newProvider.serviceAccountAccessSnapshot()
                guard self.generation == epoch, self.owner == owner, !Task.isCancelled else {
                    await newProvider.disconnect(); return
                }
                self.connectedAccountID = result == .ready ? metadata.accountID : nil
                self.serviceAccountAccess = access
                self.state = result; self.operation = nil
            }
        } catch {
            state = .error((error as? PasswordManagerFailure) ?? .notConfigured)
        }
    }
}
#endif
