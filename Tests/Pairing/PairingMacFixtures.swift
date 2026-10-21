import CryptoKit
import Darwin
import Foundation

// What the Mac side's test programs share: checks, made-up networks, stand-ins
// for the SSH server probe, the name lookups, the firewall, herdr and the
// owner's approval, a clock the tests move, preferences in memory, and a
// device that talks to the listener over 127.0.0.1 the way the iOS app will.
// Nothing here reaches the real network, sshd, the Keychain, Touch ID, the
// user's defaults or their home folder.

@MainActor enum Checks {
    static var count = 0
    static var failures: [String] = []

    static func check(_ value: Bool, _ message: String) {
        count += 1
        if !value {
            failures.append(message)
            print("FAIL \(message)")
        }
    }

    static func finish(_ summary: String) -> Never {
        if !failures.isEmpty {
            print("FAILED \(failures.count) of \(count) checks")
            exit(1)
        }
        print("PASS \(count) \(summary)")
        exit(0)
    }
}

@MainActor func check(_ value: Bool, _ message: String) {
    Checks.check(value, message)
}

// MARK: - Networks

nonisolated enum Net {
    static func ip(_ text: String) -> PairingIPv4 { PairingIPv4(text)! }

    /// fd7a:115c:a1e0::/48 and the rest.
    static let tailscaleULA: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0, 0xAB, 0x12, 0, 0, 0, 0, 0, 0, 0x01, 0x02]
    static let linkLocalV6: [UInt8] = [0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

    static func wifi(_ address: String, name: String = "en0") -> NetworkSnapshot.Interface {
        NetworkSnapshot.Interface(name: name, hardware: .wifi, isBroadcast: true, ipv4: [ip(address)], ipv6: [linkLocalV6])
    }

    static func ethernet(_ address: String, name: String) -> NetworkSnapshot.Interface {
        NetworkSnapshot.Interface(name: name, hardware: .ethernet, isBroadcast: true, ipv4: [ip(address)])
    }

    static func tunnel(_ name: String, _ address: String, ula: Bool) -> NetworkSnapshot.Interface {
        NetworkSnapshot.Interface(name: name, hardware: .other, isPointToPoint: true, ipv4: [ip(address)], ipv6: ula ? [tailscaleULA] : [])
    }

    static func service(_ id: String, _ name: String, _ interface: String) -> NetworkSnapshot.Service {
        NetworkSnapshot.Service(id: id, name: name, interfaceName: interface)
    }

    /// Wi-Fi at 192.168.0.12 and Tailscale at 100.101.102.103 with its ULA.
    static let home = NetworkSnapshot(
        interfaces: [NetworkSnapshot.Interface(name: "lo0", isPointToPoint: false, ipv4: [ip("127.0.0.1")]),
                     wifi("192.168.0.12"), tunnel("utun4", "100.101.102.103", ula: true)],
        services: [service("WIFI", "Wi-Fi", "en0")],
        localHostName: "Minsus-MacBook-Pro")

    static let tailscaleAddress = ip("100.101.102.103")
    static let magicDNSName = "minsus-mbp.tail1234.ts.net"
}

nonisolated final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NetworkSnapshot

    init(_ value: NetworkSnapshot) { stored = value }

    var value: NetworkSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Answers from tables; a name or address it doesn't have isn't found.
nonisolated struct FakeTailscaleResolver: TailscaleNameResolving {
    var reverse: [PairingIPv4: String] = [:]
    var forward: [String: [PairingIPv4]] = [:]
    var reverseThrows = false
    var forwardThrows = false
    var delay: Duration?

    struct NotFound: Error {}

    func reverseName(of address: PairingIPv4) async throws -> String? {
        if let delay { try? await Task.sleep(for: delay) }
        if reverseThrows { throw NotFound() }
        return reverse[address]
    }

    func ipv4Addresses(for name: String) async throws -> [PairingIPv4] {
        if forwardThrows { throw NotFound() }
        guard let found = forward[name] else { throw NotFound() }
        return found
    }

    /// MagicDNS on, for `Net.home`'s Tailscale address.
    static let magicDNS = FakeTailscaleResolver(reverse: [Net.tailscaleAddress: Net.magicDNSName + "."],
                                                forward: [Net.magicDNSName: [Net.tailscaleAddress]])
}

nonisolated final class FakeProbe: SSHHostKeyProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SSHHostKeyProbeResult
    private(set) var calls = 0

    init(_ result: SSHHostKeyProbeResult) { stored = result }

    var result: SSHHostKeyProbeResult {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func probe() async -> SSHHostKeyProbeResult {
        lock.withLock {
            calls += 1
            return stored
        }
    }

    static let hostKey = try! PairingPayload.HostKey(algorithm: .ed25519, sha256: Data((0..<32).map { UInt8($0 * 7 & 0xFF) }))
}

@MainActor final class FakeApproval: PairingApprovalAuthenticating {
    /// Each call's answer, in turn; nil approves.
    var answers: [String?] = []
    var reasons: [String] = []
    var cancels = 0
    /// While set, an authentication waits until it is cleared.
    var holds = false

    func authenticate(reason: String) async -> String? {
        reasons.append(reason)
        while holds { try? await Task.sleep(for: .milliseconds(10)) }
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func cancel() {
        cancels += 1
        holds = false
    }
}

nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ start: Date) { stored = start }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

nonisolated final class MemoryPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    var all: [String: String] { lock.lock(); defer { lock.unlock() }; return values }

    var preferences: PairingPreferences {
        PairingPreferences(read: { key in self.lock.lock(); defer { self.lock.unlock() }; return self.values[key] },
                           write: { key, value in self.lock.lock(); self.values[key] = value; self.lock.unlock() })
    }
}

/// A coordinator's world, in a folder of its own.
@MainActor struct PairingWorld {
    let home: URL
    let snapshot: SnapshotBox
    let probe: FakeProbe
    let approval = FakeApproval()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let preferences = MemoryPreferences()
    var resolver: FakeTailscaleResolver
    var firewall: FirewallState = .off
    var herdrIsRunning = true

    init(home: URL, snapshot: NetworkSnapshot = Net.home, resolver: FakeTailscaleResolver = .magicDNS,
         probe: SSHHostKeyProbeResult = .on(FakeProbe.hostKey)) {
        self.home = home
        self.snapshot = SnapshotBox(snapshot)
        self.resolver = resolver
        self.probe = FakeProbe(probe)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var authorizedKeys: AuthorizedKeysFile { AuthorizedKeysFile(home: home.path) }
    var store: PairedDeviceStore { PairedDeviceStore(directory: home.appending(path: "Library/Application Support/test.pairing")) }

    /// On loopback, which the listener's filter lets through, with every
    /// limit as in the app but the listener's ten seconds and the report's
    /// minute.
    func environment() -> PairingCoordinator.Environment {
        let snapshot = snapshot, clock = clock, firewall = firewall, herdr = herdrIsRunning
        var environment = PairingCoordinator.Environment(
            snapshot: { snapshot.value }, tailscaleResolver: resolver, hostKeyProbe: probe,
            firewall: { firewall }, herdrIsRunning: { herdr }, approval: approval,
            authorizedKeys: authorizedKeys, store: store, preferences: preferences.preferences,
            username: "minsu", macName: "Minsu’s MacBook Pro")
        environment.lookupTimeout = .milliseconds(300)
        environment.listenAddress = .loopback
        environment.filter = { _ in
            PairingConnectionFilter(sources: .ranges([IPv4Range(PairingIPv4(127, 0, 0, 0), prefixLength: 8)]),
                                    destinations: [PairingIPv4(127, 0, 0, 1)])
        }
        environment.handshakeTimeout = .milliseconds(500)
        environment.reportTimeout = .seconds(3)
        environment.watchesNetwork = false
        environment.ticks = false
        environment.now = { clock.now }
        return environment
    }
}

/// Waits, letting the main actor's other work run, until `condition` holds.
@MainActor func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - A device on loopback

/// Blocking socket calls, made off the main actor.
nonisolated enum Wire {
    static func connect(port: UInt16) async -> Int32? {
        await Task.detached { connectNow(port: port) }.value
    }

    static func connectNow(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }

    static func send(_ fd: Int32, _ data: Data) async -> Bool {
        await Task.detached {
            let bytes = Array(data)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }.value
    }

    /// The next frame's body; nil when the connection ends or nothing comes
    /// within three seconds.
    static func readFrame(_ fd: Int32) async -> Data? {
        await Task.detached {
            guard let header = readExactly(fd, 4) else { return nil }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            return readExactly(fd, length).map { Data($0) }
        }.value
    }

    /// Whether the other end closes the connection, with nothing more sent,
    /// within three seconds: an end of file, or a reset when something was
    /// written after it closed.
    static func isClosed(_ fd: Int32) async -> Bool {
        await Task.detached {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            return count == 0 || (count < 0 && errno == ECONNRESET)
        }.value
    }

    static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let read = bytes[offset...].withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard read > 0 else { return nil }
            offset += read
        }
        return bytes
    }
}

/// The iOS app's side of a pairing, with a software P-256 key in the Secure
/// Enclave's place.
nonisolated struct TestDevice {
    let key = P256.Signing.PrivateKey()
    let id: UUID
    let name: String
    let model: String
    var channel: PairingDeviceChannel
    let payload: PairingPayload

    init(scanning text: String, id: UUID = UUID(), name: String = "Minsu’s iPhone", model: String = "iPhone") throws {
        payload = try PairingPayload(scanned: text)
        channel = try PairingDeviceChannel(payload: payload)
        self.id = id
        self.name = name
        self.model = model
    }

    var publicKeyBlob: Data { SSHP256PublicKey.blob(for: key.publicKey) }

    mutating func request() throws -> Data {
        try channel.request(PairingRequest(deviceID: id, deviceName: name, deviceModel: model, appVersion: "1.0 (1)", publicKey: publicKeyBlob))
    }

    /// M1 under a secret that isn't the code's: it doesn't open on the Mac.
    func tamperedRequest() throws -> Data {
        var wrong = try PairingDeviceChannel(sessionID: payload.sessionID, presharedKey: Data(repeating: 0x5A, count: 32),
                                             macPublicKey: payload.macPublicKey)
        return try wrong.request(PairingRequest(deviceID: id, deviceName: name, deviceModel: model, appVersion: "1.0", publicKey: publicKeyBlob))
    }
}
