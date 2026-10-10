import Foundation
import Security

/// Thin wrapper around a generic-password Keychain item per machine, used to
/// store that machine's SSH credential — a private key or a password,
/// depending on `Machine.authMethod`.
protocol MachineSecretStore {
    func saveSecret(_ data: Data, tag: String) throws
    func loadSecret(tag: String) throws -> Data?
    func deleteSecret(tag: String) throws
}

struct KeychainStore: MachineSecretStore {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        /// This error is shown to the person as it is (see `AddMachineView`),
        /// and the description Swift would otherwise supply for it —
        /// "…KeychainError error 0." — is the same whatever the status. The
        /// number is kept next to the system's own wording because it is
        /// what can be looked up, and for a status the system has no text
        /// for it is all there is.
        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                guard let message = SecCopyErrorMessageString(status, nil) as String? else {
                    return String(localized: "Keychain error \(status)")
                }
                return String(localized: "Keychain error \(status): \(message)")
            }
        }
    }

    func saveSecret(_ data: Data, tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
        SecItemDelete(query as CFDictionary) // replace any existing value for this tag

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func loadSecret(tag: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return result as? Data
    }

    func deleteSecret(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
