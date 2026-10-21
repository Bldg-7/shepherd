import Citadel
import Crypto
import Foundation
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH

// The half of pairing a Mac by QR code (SHPHRD-77) that goes through Citadel
// and swift-nio-ssh, compiled from ShepherdKit's sources against the modules
// an app build made: the device key as swift-nio-ssh signs and offers it,
// the QR code's host key pin against the pin a connection takes, and
// `SSHHerdrTransport` refusing a paired Mac's address that is out of its
// kind's range before it connects anywhere.
//
// Nothing here connects to an SSH server. A listener of the test's own on
// 127.0.0.1 counts connections, to show that none was attempted; the runner
// runs this in a sandbox where nothing but loopback can be reached and no
// name can be looked up.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

nonisolated func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func thrown(_ work: () async throws -> Void) async -> (any Error)? {
    do {
        try await work()
        return nil
    } catch {
        return error
    }
}

func blob(_ key: NIOSSHPublicKey) -> Data {
    var buffer = ByteBuffer()
    _ = key.write(to: &buffer)
    return Data(buffer.readableBytesView)
}

nonisolated final class FakeResolver: PairingNameResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: [PairingIPv4]]
    private let delay: Duration?
    private var asked: [String] = []

    init(_ answers: [String: [PairingIPv4]], delay: Duration? = nil) {
        self.answers = answers
        self.delay = delay
    }

    var lookups: [String] {
        lock.withLock { asked }
    }

    struct NotFound: Error {}

    func ipv4Addresses(for name: String) async throws -> [PairingIPv4] {
        lock.withLock { asked.append(name) }
        if let delay { try await Task.sleep(for: delay) }
        guard let addresses = answers[name] else { throw NotFound() }
        return addresses
    }
}

/// Accepts connections on 127.0.0.1 and counts them, closing each at once.
nonisolated final class Tripwire: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = 0
    let port: Int

    init() {
        let listening = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        precondition(listening >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(bound == 0 && listen(listening, 8) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listening, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in
            while true {
                let connection = accept(listening, nil, nil)
                if connection < 0 { return }
                lock.withLock { accepted += 1 }
                close(connection)
            }
        }
    }

    var count: Int {
        lock.withLock { accepted }
    }

    /// Connects to the listener with a plain socket, to show it counts.
    func knock() -> Bool {
        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}

@MainActor final class MemorySecrets: MachineSecretStore {
    var values: [String: Data] = [:]
    func saveSecret(_ data: Data, tag: String) throws { values[tag] = data }
    func loadSecret(tag: String) throws -> Data? { values[tag] }
    func deleteSecret(tag: String) throws { values.removeValue(forKey: tag) }
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
    let method = try credential.authenticationMethod(username: "minsu")
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

// MARK: - The transport

func testTransport() async throws {
    let tripwire = Tripwire()
    expect(tripwire.knock(), "the listener takes a plain connection")
    try await Task.sleep(for: .milliseconds(200))
    expect(tripwire.count == 1, "and counts it")
    let credential = HostCredential(authMethod: .secureEnclaveKey, secretData: SecureEnclaveSSHKey.makeSoftware().storedRepresentation)

    func connect(_ host: String, _ kind: Machine.AddressKind, resolver: FakeResolver, timeout: Duration = .seconds(5)) async -> (any Error)? {
        let transport = SSHHerdrTransport(host: host, port: tripwire.port, username: "minsu", credential: credential,
                                          pinnedFingerprint: "SHA256:pinned", addressKind: kind,
                                          addressResolver: PairingAddressResolver(resolver: resolver, timeout: timeout))
        return await thrown { try await transport.connect() }
    }

    let resolver = FakeResolver([
        "studio.local": [PairingIPv4(127, 0, 0, 1), PairingIPv4(203, 0, 113, 5)],
        "studio.tail1234.ts.net": [PairingIPv4(203, 0, 113, 5), PairingIPv4(127, 0, 0, 1)]
    ])
    var error = await connect("127.0.0.1", .privateIPv4, resolver: resolver)
    expect(error as? PairingAddressError == .invalid(.privateIPv4, "127.0.0.1"), "loopback isn't a private address: \(String(describing: error))")
    error = await connect("100.100.100.100", .tailscaleIPv4, resolver: resolver)
    expect(error as? PairingAddressError == .invalid(.tailscaleIPv4, "100.100.100.100"), "quad-100 isn't a node: \(String(describing: error))")
    error = await connect("localhost", .localName, resolver: resolver)
    expect(error as? PairingAddressError == .invalid(.localName, "localhost"), "localhost isn't a .local name: \(String(describing: error))")
    error = await connect("Studio.local", .localName, resolver: resolver)
    expect(error is PairingAddressError, "capitals: \(String(describing: error))")
    expect(resolver.lookups.isEmpty, "nothing looked up for values the kind refuses")

    error = await connect("studio.local", .localName, resolver: resolver)
    if case PairingAddressResolutionError.noAddressInRange(.localName, "studio.local", let found)? = error {
        expect(found.count == 2, "a .local name that resolves to loopback and a public address is refused")
    } else {
        expect(false, ".local out of range: \(String(describing: error))")
    }
    error = await connect("studio.tail1234.ts.net", .tailscaleMagicDNS, resolver: resolver)
    if case PairingAddressResolutionError.noAddressInRange(.tailscaleMagicDNS, _, _)? = error {
        expect(error.map(connectionFailureDescription)?.contains("Tailscale") == true, "the board's text: \(error.map(connectionFailureDescription) ?? "")")
    } else {
        expect(false, "MagicDNS to a public address: \(String(describing: error))")
    }
    expect(resolver.lookups == ["studio.local", "studio.tail1234.ts.net"], "each name looked up once: \(resolver.lookups)")

    let slow = FakeResolver(["studio.local": [PairingIPv4(127, 0, 0, 1)]], delay: .seconds(5))
    error = await connect("studio.local", .localName, resolver: slow, timeout: .milliseconds(200))
    if case PairingAddressResolutionError.timedOut("studio.local")? = error {
        expect(true, "a lookup that takes too long")
    } else {
        expect(false, "timeout: \(String(describing: error))")
    }

    // The production path: a saved machine with an address kind, through
    // MachineStore and the system resolver, which an address never reaches.
    let domain = "shepherd.pairing.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = MachineStore(defaults: defaults, keychain: MemorySecrets())
    var machine = Machine(displayName: "Studio", hostname: "127.0.0.1", port: tripwire.port, username: "minsu",
                          authMethod: .secureEnclaveKey, addressKind: .privateIPv4)
    machine.pinnedHostKeyFingerprint = "SHA256:pinned"
    try store.addMachine(machine, privateKey: SecureEnclaveSSHKey.makeSoftware().storedRepresentation)
    let transport = try store.makeHerdrTransport(for: machine)
    error = await thrown { try await transport.connect() }
    expect(error as? PairingAddressError == .invalid(.privateIPv4, "127.0.0.1"), "a saved machine's kind holds: \(String(describing: error))")
    expect(error.map(connectionFailureDescription)?.contains("127.0.0.1") == true, "the board names the address")

    // The address moves with a later scan of the same Mac's code.
    let saved = store.machines[0]
    try store.updatePairedAddress(of: saved, hostname: "100.101.102.103", addressKind: .tailscaleIPv4)
    expect(store.machines[0].hostname == "100.101.102.103" && store.machines[0].addressKind == .tailscaleIPv4
           && store.machines[0].pinnedHostKeyFingerprint == "SHA256:pinned" && store.machines[0].keychainTag == saved.keychainTag,
           "only the address and its kind change")
    do {
        try store.updatePairedAddress(of: saved, hostname: "studio.local", addressKind: .localName)
        expect(false, "a stale machine isn't updated")
    } catch {
        expect(error as? MachineStore.EditError == .settingsChanged, "stale: \(error)")
    }

    try await Task.sleep(for: .milliseconds(200))
    expect(tripwire.count == 1, "no connection was attempted (\(tripwire.count - 1) beyond the knock)")

    // What a host key mismatch on a local network says.
    let anotherDevice = PairedConnectionError.anotherDeviceAnswered(address: "studio.local")
    expect(connectionFailureDescription(anotherDevice).contains("studio.local"), connectionFailureDescription(anotherDevice))
}

@main enum PairingSSHTests {
    static func main() async throws {
        try testDeviceKey()
        try testHostKeyPin()
        try await testTransport()
        print(failures == 0 ? "\(checks) checks passed" : "\(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
