import Foundation

// Needs Citadel/swift-nio-ssh/swift-crypto, same as SSHHerdrTransport.swift.
#if canImport(Citadel)
import Crypto
import NIOCore
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH

enum HostKeyFingerprint {
    /// SHA256 of the SSH wire-format public key blob, base64-encoded — the
    /// same value `ssh-keygen -lf` / OpenSSH's "SHA256:..." fingerprint shows.
    nonisolated static func compute(_ key: NIOSSHPublicKey) -> String {
        var buffer = ByteBuffer()
        _ = key.write(to: &buffer)
        let digest = SHA256.hash(data: Array(buffer.readableBytesView))
        return "SHA256:" + Data(digest).base64EncodedString()
    }
}

enum HostKeyValidationError: Error, LocalizedError {
    case mismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .mismatch(let expected, let actual):
            String(localized: "This host's SSH key doesn't match the one we pinned on first connect (expected \(expected), got \(actual)). This usually means the server was reinstalled — but it's also exactly what a man-in-the-middle attack looks like, so this connection was refused rather than silently trusting it.")
        }
    }
}

/// Trust-on-first-use host key validation: the first connection pins
/// whatever key the server presents; every connection after that must
/// present the same key or the handshake is failed outright.
nonisolated final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let pinnedFingerprint: String?
    private let observedFingerprint: NIOLockedValueBox<String?>

    init(pinnedFingerprint: String?, observedFingerprint: NIOLockedValueBox<String?>) {
        self.pinnedFingerprint = pinnedFingerprint
        self.observedFingerprint = observedFingerprint
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = HostKeyFingerprint.compute(hostKey)
        observedFingerprint.withLockedValue { $0 = fingerprint }

        if let pinnedFingerprint, pinnedFingerprint != fingerprint {
            validationCompletePromise.fail(HostKeyValidationError.mismatch(expected: pinnedFingerprint, actual: fingerprint))
        } else {
            validationCompletePromise.succeed(())
        }
    }
}
#endif
