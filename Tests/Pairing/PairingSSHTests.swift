import Citadel
import Crypto
import Foundation
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH

// The half of pairing a Mac by QR code (SHPHRD-77) that goes through Citadel
// and swift-nio-ssh, compiled from ShepherdKit's sources against the modules
// an app build made: the device key as swift-nio-ssh signs and offers it,
// the QR code's host key pin against the pin a connection takes, and the
// text a host key mismatch on a local network shows. (The hc connection
// factory's address-kind refusal is checked in Tests/CoreProtocol.)
//
// Nothing here connects to an SSH server; the runner runs this in a sandbox
// where nothing but loopback can be reached and no name can be looked up.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

nonisolated func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func blob(_ key: NIOSSHPublicKey) -> Data {
    var buffer = ByteBuffer()
    _ = key.write(to: &buffer)
    return Data(buffer.readableBytesView)
}

// MARK: - The device key in swift-nio-ssh

func testDeviceKey() throws {
    let key = SecureEnclaveSSHKey.makeSoftware()
    let nioKey = key.nioSSHPrivateKey
    expect(blob(nioKey.publicKey) == key.publicKeyBlob, "swift-nio-ssh writes the same public key blob")
    let parsed = try NIOSSHPublicKey(openSSHPublicKey: key.publicKeyLine(comment: "phone"))
    expect(parsed == nioKey.publicKey, "the public key line reads back in swift-nio-ssh")
    expect(HostKeyFingerprint.compute(parsed) == key.fingerprint, "the fingerprint is the one a connection computes")

    let digest = SHA256.hash(data: Data("exchange hash".utf8))
    let signature = try nioKey.sign(digest: digest)
    expect(parsed.isValidSignature(signature, for: digest), "a signature swift-nio-ssh makes with the key verifies")
    expect(!SecureEnclaveSSHKey.makeSoftware().nioSSHPrivateKey.publicKey.isValidSignature(signature, for: digest), "not for another key")

    let line = try AuthorizedKeyLine(devicePublicKey: key.publicKeyBlob, deviceID: UUID(), deviceName: "Phone")
    let fromLine = try NIOSSHPublicKey(openSSHPublicKey: line.text.split(separator: " ").dropFirst().joined(separator: " "))
    expect(fromLine == nioKey.publicKey, "the authorized_keys line holds the key swift-nio-ssh offers")

    // Through HostCredential, as MachineStore hands it to the transport.
    let credential = HostCredential(authMethod: .secureEnclaveKey, secretData: key.storedRepresentation)
    let factory = try credential.authenticationFactory(username: "minsu")
    let method = factory()
    expect(method !== factory(), "each connection gets a fresh authentication delegate")
    let loop = EmbeddedEventLoop()
    var offered: Result<NIOSSHUserAuthenticationOffer?, any Error>?
    let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    first.futureResult.whenComplete { offered = $0 }
    method.nextAuthenticationType(availableMethods: .all, nextChallengePromise: first)
    if case .success(let offer?) = offered, case .privateKey(let privateKey) = offer.offer {
        expect(offer.username == "minsu" && privateKey.publicKey == nioKey.publicKey, "offers the key as the user")
    } else {
        expect(false, "a public key offer: \(String(describing: offered))")
    }
    offered = nil
    let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    second.futureResult.whenComplete { offered = $0 }
    method.nextAuthenticationType(availableMethods: .all, nextChallengePromise: second)
    if case .failure(SSHClientError.allAuthenticationOptionsFailed) = offered {
        expect(true, "offered once")
    } else {
        expect(false, "once turned down, the login fails: \(String(describing: offered))")
    }
    let passwordOnly = try credential.authenticationMethod(username: "minsu")
    offered = nil
    let third = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    third.futureResult.whenComplete { offered = $0 }
    passwordOnly.nextAuthenticationType(availableMethods: .password, nextChallengePromise: third)
    if case .failure(SSHClientError.unsupportedPrivateKeyAuthentication) = offered {
        expect(true, "not offered where keys aren't taken")
    } else {
        expect(false, "a server without public keys: \(String(describing: offered))")
    }
    let unreadable = HostCredential(authMethod: .secureEnclaveKey, secretData: Data([2, 1, 2, 3]))
    do {
        _ = try unreadable.authenticationMethod(username: "minsu")
        expect(false, "a damaged stored key")
    } catch {
        expect(error as? SecureEnclaveSSHKeyError == .unreadable, "a damaged stored key: \(error)")
    }
    try loop.syncShutdownGracefully()
}

// MARK: - The QR code's pin

func testHostKeyPin() throws {
    for privateKey in [NIOSSHPrivateKey(ed25519Key: .init()), NIOSSHPrivateKey(p256Key: .init()), NIOSSHPrivateKey(p384Key: .init())] {
        let hostKey = privateKey.publicKey
        let pin = try PairingPayload.HostKey(publicKeyBlob: blob(hostKey))
        expect(pin.fingerprint == HostKeyFingerprint.compute(hostKey), "the code's pin is what TOFUHostKeyValidator compares: \(pin.algorithm)")
    }
    expect(try PairingPayload.HostKey(publicKeyBlob: blob(NIOSSHPrivateKey(ed25519Key: .init()).publicKey)).algorithm == .ed25519, "ed25519")
    expect(try PairingPayload.HostKey(publicKeyBlob: blob(NIOSSHPrivateKey(p256Key: .init()).publicKey)).algorithm == .ecdsaP256, "P-256")
}

// MARK: - What a host key mismatch on a local network says

func testConnectionText() {
    let anotherDevice = PairedConnectionError.anotherDeviceAnswered(address: "studio.local")
    expect(connectionFailureDescription(anotherDevice).contains("studio.local"), connectionFailureDescription(anotherDevice))
}

@main enum PairingSSHTests {
    static func main() async throws {
        try testDeviceKey()
        try testHostKeyPin()
        testConnectionText()
        print(failures == 0 ? "\(checks) checks passed" : "\(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
