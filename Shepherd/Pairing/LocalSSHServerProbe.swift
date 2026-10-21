#if os(macOS)
import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// Finds out whether Remote Login is on, and which host key a device will
/// be given, by connecting to this Mac's own SSH server at 127.0.0.1:22 and
/// going only as far as the key exchange (SHPHRD-77, "그 밖의 접속 정보").
/// The host key arrives during the key exchange, before anything is
/// authenticated; the connection is ended there, so nothing is offered and
/// no login is attempted. The algorithms are Citadel's defaults, the same
/// `SSHHerdrTransport` uses on the device, so the key found is the one the
/// device will be shown and checks against the code's pin.
///
/// Nothing listening on the port is Remote Login being off.
nonisolated struct LocalSSHServerProbe: SSHHostKeyProbing {
    var host = "127.0.0.1"
    var port = 22
    var timeout: TimeAmount = .seconds(5)

    func probe() async -> SSHHostKeyProbeResult {
        let captured = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
        var settings = SSHClientSettings(host: host, port: port,
                                         authenticationMethod: { .custom(OfferNothing()) },
                                         hostKeyValidator: .custom(HostKeyCapture(captured: captured)))
        settings.connectTimeout = timeout
        do {
            let client = try await SSHClient.connect(to: settings)
            // `HostKeyCapture` fails every key, so a connection is never made.
            try? await client.close()
        } catch {
            if let key = captured.withLockedValue({ $0 }) {
                do {
                    return .on(try Self.hostKey(from: key))
                } catch {
                    return .failed(String(localized: "This Mac's SSH server offered a host key of a type hrdrhrdrhrdr can't pin."))
                }
            }
            if Self.isConnectionRefused(error) { return .off }
            return .failed(String(describing: error))
        }
        return .failed(String(localized: "This Mac's SSH server didn't show its host key."))
    }

    /// The key's algorithm and the SHA-256 of its SSH wire form, as a code
    /// carries them.
    static func hostKey(from key: NIOSSHPublicKey) throws -> PairingPayload.HostKey {
        var buffer = ByteBuffer()
        _ = key.write(to: &buffer)
        return try PairingPayload.HostKey(publicKeyBlob: Data(buffer.readableBytesView))
    }

    /// Whether every way of connecting was refused: no SSH server listens.
    static func isConnectionRefused(_ error: any Error) -> Bool {
        if let error = error as? IOError { return error.errnoCode == ECONNREFUSED }
        if let error = error as? NIOConnectionError {
            return !error.connectionErrors.isEmpty && error.connectionErrors.allSatisfy { isConnectionRefused($0.error) }
        }
        return false
    }
}

/// Takes the host key down and fails it, which ends the connection before
/// user authentication starts.
nonisolated final class HostKeyCapture: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Captured: Error {}

    private let captured: NIOLockedValueBox<NIOSSHPublicKey?>

    init(captured: NIOLockedValueBox<NIOSSHPublicKey?>) {
        self.captured = captured
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        captured.withLockedValue { $0 = hostKey }
        validationCompletePromise.fail(Captured())
    }
}

/// Offers no way to log in, should it ever be asked.
nonisolated final class OfferNothing: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    struct NothingOffered: Error {}

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.fail(NothingOffered())
    }
}
#endif
