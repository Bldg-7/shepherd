import Foundation

// Needs Citadel for `SSHAuthenticationMethod`. Guarded the same way as the
// rest of HerdrKit's Citadel-backed pieces.
#if canImport(Citadel)
import Citadel

/// The secret used to authenticate to a Machine over SSH — a private key
/// (parsed by `OpenSSHPrivateKey`), a plain password, or the stored form of
/// a key the iOS app made for a paired Mac (`SecureEnclaveSSHKey`).
/// `MachineStore` stores each as opaque bytes under one Keychain tag;
/// `Machine.authMethod` says which this is.
public nonisolated enum HostCredential: Sendable {
    case privateKey(String)
    case password(String)
    /// `SecureEnclaveSSHKey.storedRepresentation`.
    case secureEnclaveKey(Data)

    public init(authMethod: Machine.AuthMethod, secretData: Data) {
        switch authMethod {
        case .key: self = .privateKey(String(decoding: secretData, as: UTF8.self))
        case .password: self = .password(String(decoding: secretData, as: UTF8.self))
        case .secureEnclaveKey: self = .secureEnclaveKey(secretData)
        }
    }

    public nonisolated func authenticationMethod(username: String) throws -> SSHAuthenticationMethod {
        try authenticationFactory(username: username)()
    }

    /// Citadel's authentication delegate is mutable and not Sendable. Its
    /// factory crosses executors, never a shared, already-used delegate.
    public nonisolated func authenticationFactory(username: String) throws -> @Sendable () -> SSHAuthenticationMethod {
        switch self {
        case .privateKey(let pem):
            return try OpenSSHPrivateKey.authenticationFactory(username: username, pem: pem)
        case .password(let password):
            return { .passwordBased(username: username, password: password) }
        case .secureEnclaveKey(let stored):
            let key = try SecureEnclaveSSHKey(storedRepresentation: stored)
            return { key.authenticationMethod(username: username) }
        }
    }
}
#endif
