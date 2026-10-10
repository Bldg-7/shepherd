import Foundation

// Needs Citadel for `SSHAuthenticationMethod`. Guarded the same way as the
// rest of HerdrKit's Citadel-backed pieces.
#if canImport(Citadel)
import Citadel

/// The secret used to authenticate to a Machine over SSH — either a private
/// key (parsed by `OpenSSHPrivateKey`) or a plain password. `MachineStore`
/// stores both as opaque bytes under one Keychain tag; `Machine.authMethod`
/// says which this is.
enum HostCredential: Sendable {
    case privateKey(String)
    case password(String)

    init(authMethod: Machine.AuthMethod, secretData: Data) {
        let text = String(decoding: secretData, as: UTF8.self)
        switch authMethod {
        case .key: self = .privateKey(text)
        case .password: self = .password(text)
        }
    }

    nonisolated func authenticationMethod(username: String) throws -> SSHAuthenticationMethod {
        switch self {
        case .privateKey(let pem):
            return try OpenSSHPrivateKey.authenticationMethod(username: username, pem: pem)
        case .password(let password):
            return .passwordBased(username: username, password: password)
        }
    }
}
#endif
