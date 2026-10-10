import Foundation
import NIOCore
import NIOFoundationCompat

// Needs Citadel (for SSHAuthenticationMethod) + Crypto. Guarded the same way
// as SSHHerdrTransport.swift so the rest of the app builds before packages are added.
#if canImport(Citadel)
import Citadel
import Crypto

enum OpenSSHKeyError: Error, LocalizedError {
    case notPEM
    case encrypted
    case multipleKeysUnsupported
    case malformed
    case unsupportedKeyType(String)

    var errorDescription: String? {
        switch self {
        case .notPEM: String(localized: "Not an OpenSSH PEM private key (expected -----BEGIN OPENSSH PRIVATE KEY-----)")
        case .encrypted: String(localized: "Passphrase-encrypted keys aren't supported yet — use an unencrypted key")
        case .multipleKeysUnsupported: String(localized: "Key files with more than one key aren't supported")
        case .malformed: String(localized: "The key data is malformed")
        case .unsupportedKeyType(let type): String(localized: "Unsupported key type '\(type)'")
        }
    }
}

/// Parses the subset of the OpenSSH private key format (see
/// https://dnaeon.github.io/openssh-private-key-binary-format/) needed for
/// unencrypted ed25519 and ECDSA (P-256/P-384/P-521) keys, and builds the
/// matching `SSHAuthenticationMethod`. Citadel has this same parsing logic
/// internally (OpenSSHKey.swift) but doesn't expose a public entry point for
/// it, so this is a from-scratch reimplementation.
///
/// RSA is deliberately not supported: Citadel's `Insecure.RSA.PrivateKey`
/// only signs with SHA-1 (the legacy `ssh-rsa` algorithm), which modern
/// OpenSSH servers (8.8+) disable signature verification for by default —
/// so even a correctly-parsed RSA key would likely be rejected server-side.
/// Supporting it properly would mean Citadel adding `rsa-sha2-256/512`
/// signing, which is out of scope here.
enum OpenSSHPrivateKey {
    nonisolated static func authenticationMethod(username: String, pem: String) throws -> SSHAuthenticationMethod {
        let parsed = try openPrivateSection(pem: pem)
        let keyType = parsed.keyType
        var privateSection = parsed.privateSection

        switch keyType {
        case "ssh-ed25519":
            let signingKey = try parseEd25519(from: &privateSection)
            return .ed25519(username: username, privateKey: signingKey)
        case "ecdsa-sha2-nistp256":
            let signingKey = try P256.Signing.PrivateKey(rawRepresentation: parseECDSAScalar(from: &privateSection, scalarByteCount: 32))
            return .p256(username: username, privateKey: signingKey)
        case "ecdsa-sha2-nistp384":
            let signingKey = try P384.Signing.PrivateKey(rawRepresentation: parseECDSAScalar(from: &privateSection, scalarByteCount: 48))
            return .p384(username: username, privateKey: signingKey)
        case "ecdsa-sha2-nistp521":
            let signingKey = try P521.Signing.PrivateKey(rawRepresentation: parseECDSAScalar(from: &privateSection, scalarByteCount: 66))
            return .p521(username: username, privateKey: signingKey)
        case "ssh-rsa":
            throw OpenSSHKeyError.unsupportedKeyType("RSA (legacy ssh-rsa/SHA-1 signing isn't supported by modern SSH servers — see comment above)")
        default:
            throw OpenSSHKeyError.unsupportedKeyType(keyType)
        }
    }

    /// Decodes the PEM, skips past the shared header (magic/cipher/kdf/pubkey
    /// blob) and the checkint pair, and returns the key type string plus a
    /// buffer positioned right after it — ready for the type-specific fields.
    private nonisolated static func openPrivateSection(pem: String) throws -> (keyType: String, privateSection: ByteBuffer) {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let footer = "-----END OPENSSH PRIVATE KEY-----"
        guard trimmed.hasPrefix(header), trimmed.hasSuffix(footer) else {
            throw OpenSSHKeyError.notPEM
        }
        let base64 = trimmed
            .dropFirst(header.count)
            .dropLast(footer.count)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let raw = Data(base64Encoded: base64) else {
            throw OpenSSHKeyError.malformed
        }

        var buffer = ByteBuffer(data: raw)

        let magic: [UInt8] = Array("openssh-key-v1".utf8) + [0]
        guard buffer.readBytes(length: magic.count) == magic else {
            throw OpenSSHKeyError.malformed
        }

        guard let cipherName = buffer.readOpenSSHString() else { throw OpenSSHKeyError.malformed }
        guard cipherName == "none" else { throw OpenSSHKeyError.encrypted }
        _ = buffer.readOpenSSHString() // kdfname, unused for cipher "none"
        _ = buffer.readOpenSSHString() // kdfoptions, unused for cipher "none"

        guard let keyCount: UInt32 = buffer.readInteger(), keyCount == 1 else {
            throw OpenSSHKeyError.multipleKeysUnsupported
        }

        // One public-key wire blob we don't need beyond skipping it.
        guard
            let publicBlobLength: UInt32 = buffer.readInteger(),
            buffer.readBytes(length: Int(publicBlobLength)) != nil
        else {
            throw OpenSSHKeyError.malformed
        }

        // The "encrypted" (here: plaintext, since cipher is "none") private section.
        guard
            let privateSectionLength: UInt32 = buffer.readInteger(),
            var privateSection = buffer.readSlice(length: Int(privateSectionLength))
        else {
            throw OpenSSHKeyError.malformed
        }

        guard
            let check1: UInt32 = privateSection.readInteger(),
            let check2: UInt32 = privateSection.readInteger(),
            check1 == check2
        else {
            throw OpenSSHKeyError.malformed
        }

        guard let keyType = privateSection.readOpenSSHString() else { throw OpenSSHKeyError.malformed }
        return (keyType, privateSection)
    }

    private nonisolated static func parseEd25519(from privateSection: inout ByteBuffer) throws -> Curve25519.Signing.PrivateKey {
        // 32-byte public key half — skip, we don't need it.
        guard
            let publicKeyLength: UInt32 = privateSection.readInteger(),
            privateSection.readBytes(length: Int(publicKeyLength)) != nil
        else {
            throw OpenSSHKeyError.malformed
        }

        // 64 bytes: 32-byte private seed followed by the 32-byte public key.
        guard
            let privatePlusPublicLength: UInt32 = privateSection.readInteger(),
            privatePlusPublicLength == 64,
            let privatePlusPublic = privateSection.readBytes(length: 64)
        else {
            throw OpenSSHKeyError.malformed
        }

        let seed = Array(privatePlusPublic.prefix(32))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// ECDSA private section layout: string curve_name, string Q (public
    /// point, skipped), mpint d (the private scalar we need).
    private nonisolated static func parseECDSAScalar(from privateSection: inout ByteBuffer, scalarByteCount: Int) throws -> [UInt8] {
        guard
            privateSection.readOpenSSHString() != nil, // curve_name, e.g. "nistp256" — implied by key type, not needed
            let publicPointLength: UInt32 = privateSection.readInteger(),
            privateSection.readBytes(length: Int(publicPointLength)) != nil // Q, the public point — skip
        else {
            throw OpenSSHKeyError.malformed
        }

        guard let scalar = privateSection.readOpenSSHMPInt(expectedByteCount: scalarByteCount) else {
            throw OpenSSHKeyError.malformed
        }
        return scalar
    }
}

private extension ByteBuffer {
    nonisolated mutating func readOpenSSHString() -> String? {
        guard let length: UInt32 = self.readInteger(), let bytes = self.readBytes(length: Int(length)) else {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads an SSH mpint (length-prefixed big-endian integer, possibly with
    /// a leading zero byte to disambiguate sign) and normalizes it to exactly
    /// `expectedByteCount` bytes, as needed for a fixed-width EC private scalar.
    nonisolated mutating func readOpenSSHMPInt(expectedByteCount: Int) -> [UInt8]? {
        guard let length: UInt32 = self.readInteger(), let bytes = self.readBytes(length: Int(length)) else {
            return nil
        }
        let trimmed = bytes.drop(while: { $0 == 0 })
        guard trimmed.count <= expectedByteCount else { return nil }
        return [UInt8](repeating: 0, count: expectedByteCount - trimmed.count) + Array(trimmed)
    }
}
#endif
