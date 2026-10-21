import CryptoKit
import Foundation
import Security

// Signing with the key over SSH needs Citadel and swift-nio-ssh, guarded
// with `canImport` like the rest of HerdrKit's Citadel-backed pieces; the
// key itself, its public form and what is stored of it don't.
#if canImport(Citadel)
import Citadel
import NIOCore
@preconcurrency import NIOSSH
#endif

/// The SSH identity the iOS app makes for a Mac it pairs with by QR code
/// (SHPHRD-77, "기기 자격 증명"): a P-256 key in the device's Secure Enclave,
/// which can sign but can't be read out, so it can't be copied off the device
/// or restored onto another. The Mac's `authorized_keys` gets its public half
/// as an `ecdsa-sha2-nistp256` key.
///
/// Where there is no Secure Enclave — the Simulator, and the test runners —
/// the same kind of key is made in software instead. Nothing else changes.
///
/// What the app keeps of a key is `storedRepresentation`, under the
/// machine's `keychainTag` like any other machine's secret, with
/// `Machine.authMethod` `.secureEnclaveKey`. For a Secure Enclave key that is
/// the enclave's own wrapped blob, which only this device's enclave can use.
public nonisolated struct SecureEnclaveSSHKey: Sendable {
    public enum Backing: UInt8, Sendable {
        case secureEnclave = 1
        /// The Simulator and tests only.
        case software = 2
    }

    private enum Signer: Sendable {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    private let signer: Signer

    public var backing: Backing {
        switch signer {
        case .secureEnclave: .secureEnclave
        case .software: .software
        }
    }

    public var publicKey: P256.Signing.PublicKey {
        switch signer {
        case .secureEnclave(let key): key.publicKey
        case .software(let key): key.publicKey
        }
    }

    private init(signer: Signer) {
        self.signer = signer
    }

    /// A new key for a pairing: in the Secure Enclave on a device, in
    /// software on the Simulator. Throws on a device without a Secure
    /// Enclave rather than keeping a private key in software there.
    public static func makeForThisDevice() throws -> SecureEnclaveSSHKey {
        #if targetEnvironment(simulator)
        return makeSoftware()
        #else
        return try makeInSecureEnclave()
        #endif
    }

    /// A key in the Secure Enclave, usable only while the device is unlocked
    /// and never on another device (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`),
    /// for signing only (`.privateKeyUsage`). It doesn't ask for Face ID or a
    /// passcode on each use: the app connects in the background to keep its
    /// board current.
    public static func makeInSecureEnclave() throws -> SecureEnclaveSSHKey {
        guard SecureEnclave.isAvailable else { throw SecureEnclaveSSHKeyError.secureEnclaveUnavailable }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil) else {
            throw SecureEnclaveSSHKeyError.secureEnclaveUnavailable
        }
        return SecureEnclaveSSHKey(signer: .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)))
    }

    /// A key in software: what the Simulator and tests use in place of the
    /// Secure Enclave.
    public static func makeSoftware() -> SecureEnclaveSSHKey {
        SecureEnclaveSSHKey(signer: .software(P256.Signing.PrivateKey()))
    }

    /// What the app stores for the key: one byte for `backing`, then the
    /// Secure Enclave's blob or, for a software key, its 32-byte scalar.
    public var storedRepresentation: Data {
        switch signer {
        case .secureEnclave(let key): Data([Backing.secureEnclave.rawValue]) + key.dataRepresentation
        case .software(let key): Data([Backing.software.rawValue]) + key.rawRepresentation
        }
    }

    /// The key back from `storedRepresentation`. A Secure Enclave blob only
    /// opens on the device whose enclave made it.
    public init(storedRepresentation: Data) throws {
        guard let first = storedRepresentation.first, let backing = Backing(rawValue: first) else {
            throw SecureEnclaveSSHKeyError.unreadable
        }
        let body = storedRepresentation.dropFirst()
        switch backing {
        case .secureEnclave:
            guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(body)) else {
                throw SecureEnclaveSSHKeyError.unreadable
            }
            signer = .secureEnclave(key)
        case .software:
            guard body.count == 32, let key = try? P256.Signing.PrivateKey(rawRepresentation: body) else {
                throw SecureEnclaveSSHKeyError.unreadable
            }
            signer = .software(key)
        }
    }

    /// The public key's SSH wire form, which the device sends the Mac.
    public var publicKeyBlob: Data {
        SSHP256PublicKey.blob(for: publicKey)
    }

    /// `ecdsa-sha2-nistp256 AAAA…`, with `comment` after it when there is one.
    public func publicKeyLine(comment: String = "") -> String {
        let line = "\(SSHP256PublicKey.keyType) \(publicKeyBlob.base64EncodedString())"
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? line : "\(line) \(trimmed)"
    }

    public var fingerprint: String {
        SSHKeyFingerprint.sha256(ofBlob: publicKeyBlob)
    }

    public func signature<D: DataProtocol>(for data: D) throws -> P256.Signing.ECDSASignature {
        switch signer {
        case .secureEnclave(let key): try key.signature(for: data)
        case .software(let key): try key.signature(for: data)
        }
    }
}

#if canImport(Citadel)
nonisolated extension SecureEnclaveSSHKey {
    /// The key as swift-nio-ssh signs with it: the Secure Enclave key through
    /// `NIOSSHPrivateKey(secureEnclaveP256Key:)`, so signing happens inside
    /// the enclave.
    public var nioSSHPrivateKey: NIOSSHPrivateKey {
        switch signer {
        case .secureEnclave(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
        case .software(let key): NIOSSHPrivateKey(p256Key: key)
        }
    }

    /// Public-key authentication as `username` with this key, through
    /// Citadel's `.custom`, which has no initializer of its own for a Secure
    /// Enclave key. Citadel asks it once; when the server turns the key down,
    /// the next ask fails the login with `allAuthenticationOptionsFailed`, as
    /// for any other key.
    public func authenticationMethod(username: String) -> SSHAuthenticationMethod {
        .custom(SecureEnclaveKeyAuthentication(username: username, privateKey: nioSSHPrivateKey))
    }
}

/// Offers the key to the server, when the server takes public keys at all.
nonisolated final class SecureEnclaveKeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "",
                                                                   offer: .privateKey(.init(privateKey: privateKey))))
    }
}
#endif

public nonisolated enum SecureEnclaveSSHKeyError: Error, Equatable, LocalizedError {
    case secureEnclaveUnavailable
    /// The stored key is damaged, or was made by another device's Secure Enclave.
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable:
            String(localized: "This device has no Secure Enclave to keep its key in.", bundle: .shepherdKit)
        case .unreadable:
            String(localized: "This device's key for the Mac can't be used. Remove the Mac and pair it again.", bundle: .shepherdKit)
        }
    }
}
