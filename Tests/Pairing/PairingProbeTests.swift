import Citadel
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH

// The Mac's look at its own SSH server (SHPHRD-77), the part that goes
// through Citadel and swift-nio-ssh, against the modules an app build made:
// the host key taken down and failed in the key exchange, which ends the
// connection before anything is authenticated; nothing offered to log in
// with; the key as the code carries it, with the pin's own fingerprint; and
// what counts as Remote Login being off. Nothing here connects anywhere —
// the probe itself is never run — and the runner runs it in a sandbox that
// reaches only loopback.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

nonisolated func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL \(message())")
    }
}

@main enum PairingProbeTests {
    static func main() async {
        let loop = EmbeddedEventLoop()

        // The host key is taken down, then failed.
        let ed25519 = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let captured = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
        let validation = loop.makePromise(of: Void.self)
        HostKeyCapture(captured: captured).validateHostKey(hostKey: ed25519.publicKey, validationCompletePromise: validation)
        var validated: Result<Void, any Error>?
        validation.futureResult.whenComplete { validated = $0 }
        loop.run()
        if case .failure(let error)? = validated {
            expect(error is HostKeyCapture.Captured, "the host key fails validation, which ends the key exchange")
        } else {
            expect(false, "the host key never passes")
        }
        expect(captured.withLockedValue { $0 } == ed25519.publicKey, "…after it is taken down")

        // Nothing is offered to log in with.
        let offer = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        OfferNothing().nextAuthenticationType(availableMethods: .all, nextChallengePromise: offer)
        var offered: Result<NIOSSHUserAuthenticationOffer?, any Error>?
        offer.futureResult.whenComplete { offered = $0 }
        loop.run()
        if case .failure? = offered {
            expect(true, "no way to log in is offered")
        } else {
            expect(false, "no way to log in is offered")
        }

        // The key as a code carries it.
        do {
            let key = try LocalSSHServerProbe.hostKey(from: ed25519.publicKey)
            expect(key.algorithm == .ed25519 && key.fingerprint == HostKeyFingerprint.compute(ed25519.publicKey),
                   "an Ed25519 host key: its algorithm, and the fingerprint a connection pins")
            let p256 = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
            let p256Key = try LocalSSHServerProbe.hostKey(from: p256.publicKey)
            expect(p256Key.algorithm == .ecdsaP256 && p256Key.fingerprint == HostKeyFingerprint.compute(p256.publicKey), "a P-256 host key too")
            let payload = try PairingPayload(sessionID: Data(repeating: 1, count: 16), presharedKey: Data(repeating: 2, count: 32),
                                             macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                             expiresAt: Date(timeIntervalSince1970: 1_800_000_000), pairingPort: 50_000,
                                             address: try PairingAddress(kind: .privateIPv4, ipv4: PairingIPv4(192, 168, 0, 12)),
                                             hostKey: key, username: "minsu", macID: UUID(), macName: "Mac")
            expect(payload.machine().pinnedHostKeyFingerprint == HostKeyFingerprint.compute(ed25519.publicKey),
                   "the machine a device saves pins the same fingerprint a connection to this Mac computes")
        } catch {
            expect(false, "host keys convert: \(error)")
        }

        // Remote Login off is a refused connection, and only that.
        expect(LocalSSHServerProbe.isConnectionRefused(IOError(errnoCode: ECONNREFUSED, reason: "connect")), "ECONNREFUSED: Remote Login off")
        expect(!LocalSSHServerProbe.isConnectionRefused(IOError(errnoCode: ETIMEDOUT, reason: "connect")), "a timeout isn't")
        expect(!LocalSSHServerProbe.isConnectionRefused(ChannelError.connectTimeout(.seconds(5))), "a connect timeout isn't")
        expect(!LocalSSHServerProbe.isConnectionRefused(HostKeyCapture.Captured()), "a captured key isn't")

        let probe = LocalSSHServerProbe()
        expect(probe.host == "127.0.0.1" && probe.port == 22 && probe.timeout == .seconds(5), "the probe goes to 127.0.0.1:22, for five seconds at most")

        try? await loop.close()
        if failures > 0 {
            print("FAILED \(failures) of \(checks) checks")
            exit(1)
        }
        print("PASS \(checks) SSH server probe checks; no connection made")
    }
}
