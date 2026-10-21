import CryptoKit
import Foundation

// The platform-independent half of pairing a Mac by QR code (SHPHRD-77),
// compiled from ShepherdKit's sources without Citadel: the address kinds and
// their ranges, the name lookup with a stand-in resolver, the QR code's text,
// the HPKE messages and their confirmation code, the authorized_keys line,
// the device key with a software P-256 key in the Secure Enclave's place,
// and `Machine`'s JSON. No network, no DNS, no Keychain, no Secure Enclave.
//
// Argument: a directory to write the authorized_keys line into, for the
// runner to read back with ssh-keygen.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

nonisolated func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

/// The error `work` threw, or nil.
func thrown(_ work: () throws -> Void) -> (any Error)? {
    do {
        try work()
        return nil
    } catch {
        return error
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

func expectError<E: Error & Equatable>(_ expected: E, line: Int = #line, _ work: () throws -> Void) {
    let error = thrown(work)
    expect((error as? E) == expected, "expected \(expected), got \(String(describing: error))", line: line)
}

func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

// MARK: - Stand-in resolver

nonisolated final class FakeResolver: PairingNameResolving, @unchecked Sendable {
    enum Answer {
        case addresses([PairingIPv4])
        case failure
        case slow(Duration, [PairingIPv4])
    }

    private let lock = NSLock()
    private let answers: [String: Answer]
    private var asked: [String] = []

    init(_ answers: [String: Answer]) {
        self.answers = answers
    }

    var lookups: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    struct NotFound: Error {}

    func ipv4Addresses(for name: String) async throws -> [PairingIPv4] {
        lock.withLock { asked.append(name) }
        switch answers[name] {
        case .addresses(let addresses): return addresses
        case .slow(let delay, let addresses):
            try await Task.sleep(for: delay)
            return addresses
        case .failure, nil: throw NotFound()
        }
    }
}

func ip(_ text: String) -> PairingIPv4 {
    PairingIPv4(text)!
}

// MARK: - Addresses

func testAddresses() {
    // Dotted-decimal only.
    expect(PairingIPv4("10.0.0.1") == PairingIPv4(10, 0, 0, 1), "plain address")
    expect(PairingIPv4("255.255.255.255")?.value == UInt32.max, "highest address")
    for text in ["010.0.0.1", "10.0.0", "10.0.0.256", "0x0a.0.0.1", " 10.0.0.1", "10.0.0.1 ", "10..0.1", "1e1.0.0.1", "10.0.0.1.", "-1.0.0.1", "１０.0.0.1"] {
        expect(PairingIPv4(text) == nil, "\(text) isn't dotted decimal")
    }
    expect(PairingIPv4(bytes: [192, 168, 1, 2])?.description == "192.168.1.2", "four bytes")
    expect(PairingIPv4(bytes: [192, 168, 1]) == nil && PairingIPv4(bytes: [1, 2, 3, 4, 5]) == nil, "not four bytes")

    func accepts(_ kind: PairingAddressKind, _ value: String) -> Bool {
        (try? PairingAddress(kind: kind, hostname: value)) != nil
    }

    // .local: one label and .local, lower-case ASCII.
    let label63 = String(repeating: "a", count: 63)
    for name in ["my-mac.local", "a.local", "0.local", "mac-mini-2.local", "\(label63).local"] {
        expect(accepts(.localName, name), "\(name) is a .local name")
    }
    for name in ["My-Mac.local", "my-mac.LOCAL", "my-mac.local.", "맥북.local", "macbook-é.local", "-mac.local", "mac-.local", "my_mac.local",
                 "my mac.local", "my-mac.lan", "a.b.local", "\(label63)a.local", "", ".local", "local", "my-mac.local\n", "my-mac..local",
                 "192.168.1.2", "my-mac.local.evil.com"] {
        expect(!accepts(.localName, name), "\(name.debugDescription) isn't a .local name")
    }

    // MagicDNS: at least four labels ending in .ts.net, 253 bytes at most.
    for name in ["my-mac.tail1234.ts.net", "a.b.ts.net", "my-mac.cat-crocodile.ts.net", "x.y.z.ts.net"] {
        expect(accepts(.tailscaleMagicDNS, name), "\(name) is a MagicDNS name")
    }
    let filler = String(repeating: String(repeating: "a", count: 62) + ".", count: 3)
    let name253 = filler + String(repeating: "b", count: 253 - filler.count - 7) + ".ts.net"
    let name254 = filler + String(repeating: "b", count: 254 - filler.count - 7) + ".ts.net"
    expect(name253.utf8.count == 253 && name254.utf8.count == 254, "fixture lengths")
    expect(accepts(.tailscaleMagicDNS, name253), "a 253-byte name")
    expect(!accepts(.tailscaleMagicDNS, name254), "a 254-byte name")
    for name in ["My-Mac.tail1234.ts.net", "my-mac.tail1234.TS.NET", "my-mac.tail1234.ts.net.", "evil.ts.net.example.com", "xts.net",
                 "my-mac.xts.net", "a.b.xts.net", "tail1234.ts.net", "ts.net", "맥.tail1234.ts.net", "my mac.tail1234.ts.net",
                 "my-mac..ts.net", "my_mac.tail1234.ts.net", "-mac.tail1234.ts.net", "my-mac.tail1234.ts.net\n", "100.101.102.103",
                 "my-mac.tail1234.ts.network"] {
        expect(!accepts(.tailscaleMagicDNS, name), "\(name.debugDescription) isn't a MagicDNS name")
    }

    // Private IPv4: RFC 1918 only, at each edge.
    let privateEdges: [(String, Bool)] = [
        ("9.255.255.255", false), ("10.0.0.0", true), ("10.255.255.255", true), ("11.0.0.0", false),
        ("172.15.255.255", false), ("172.16.0.0", true), ("172.31.255.255", true), ("172.32.0.0", false),
        ("192.167.255.255", false), ("192.168.0.0", true), ("192.168.255.255", true), ("192.169.0.0", false),
        ("169.254.1.1", false), ("100.64.0.1", false), ("8.8.8.8", false), ("127.0.0.1", false), ("0.0.0.0", false)
    ]
    for (value, allowed) in privateEdges {
        expect(accepts(.privateIPv4, value) == allowed, "private IPv4 \(value): \(allowed)")
    }
    // Tailscale IPv4: 100.64/10 without quad-100 and 100.115.92.0/23.
    let tailscaleEdges: [(String, Bool)] = [
        ("100.63.255.255", false), ("100.64.0.0", true), ("100.127.255.255", true), ("100.128.0.0", false),
        ("100.100.100.99", true), ("100.100.100.100", false), ("100.100.100.101", true),
        ("100.115.91.255", true), ("100.115.92.0", false), ("100.115.92.77", false), ("100.115.93.255", false), ("100.115.94.0", true),
        ("10.0.0.1", false), ("192.168.1.2", false)
    ]
    for (value, allowed) in tailscaleEdges {
        expect(accepts(.tailscaleIPv4, value) == allowed, "Tailscale IPv4 \(value): \(allowed)")
        expect(PairingAddressKind.tailscaleMagicDNS.allows(ip(value)) == allowed, "MagicDNS may lead to \(value): \(allowed)")
    }
    // A .local name may lead to a private or link-local address.
    let localEdges: [(String, Bool)] = [
        ("192.168.1.2", true), ("10.1.2.3", true), ("172.20.0.1", true), ("169.254.0.0", true), ("169.254.255.255", true),
        ("169.253.255.255", false), ("169.255.0.0", false), ("100.64.0.1", false), ("8.8.8.8", false), ("127.0.0.1", false)
    ]
    for (value, allowed) in localEdges {
        expect(PairingAddressKind.localName.allows(ip(value)) == allowed, ".local may lead to \(value): \(allowed)")
    }
    // Kinds and values that don't go together.
    expect(!accepts(.privateIPv4, "my-mac.local") && !accepts(.tailscaleIPv4, "my-mac.tail1234.ts.net"), "an IPv4 kind takes no name")
    expect(!accepts(.localName, "192.168.1.2") && !accepts(.tailscaleMagicDNS, "100.101.102.103"), "a name kind takes no address")
    expect((try? PairingAddress(kind: .localName, ipv4: ip("192.168.1.2"))) == nil, "a name kind takes no address (IPv4 initializer)")
    expect((try? PairingAddress(kind: .privateIPv4, name: "my-mac.local")) == nil, "an IPv4 kind takes no name (name initializer)")
    let address = try? PairingAddress(kind: .tailscaleIPv4, hostname: "100.101.102.103")
    expect(address?.hostname == "100.101.102.103" && address?.value == .ipv4(ip("100.101.102.103")), "hostname round trip")

    // Tailscale's IPv6 prefix, for the Mac's listener.
    var ula = [UInt8](repeating: 0, count: 16)
    ula.replaceSubrange(0..<6, with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    expect(PairingAddressRanges.isTailscaleULA(ula), "fd7a:115c:a1e0::")
    ula[5] = 0xE1
    expect(!PairingAddressRanges.isTailscaleULA(ula), "fd7a:115c:a1e1::")
    expect(!PairingAddressRanges.isTailscaleULA([UInt8](repeating: 0xFD, count: 15)), "15 bytes")

    // Tags and order.
    expect(PairingAddressKind.allCases.map(\.tag) == [1, 2, 3, 4], "tags 1 to 4")
    expect(PairingAddressKind.allCases.allSatisfy { PairingAddressKind(tag: $0.tag) == $0 }, "tags round trip")
    expect(PairingAddressKind(tag: 0) == nil && PairingAddressKind(tag: 5) == nil && PairingAddressKind(tag: 255) == nil, "unknown tags")
    expect(PairingAddressKind.preferenceOrder == [.tailscaleMagicDNS, .tailscaleIPv4, .localName, .privateIPv4], "default order")
    expect(PairingAddressKind.localName.isLAN && PairingAddressKind.privateIPv4.isLAN
           && !PairingAddressKind.tailscaleIPv4.isLAN && !PairingAddressKind.tailscaleMagicDNS.isLAN, "LAN kinds")
    expect(PairingAddressKind.allCases.allSatisfy { !$0.displayName.isEmpty }, "display names")

    let error = thrown { _ = try PairingAddress(kind: .privateIPv4, hostname: "8.8.8.8") }
    expect(error as? PairingAddressError == .invalid(.privateIPv4, "8.8.8.8"), "out-of-range error")
    expect(error?.localizedDescription.contains("8.8.8.8") == true, "error names the value: \(String(describing: error?.localizedDescription))")
}

// MARK: - Resolver

func testResolver() async {
    let resolver = FakeResolver([
        "mixed.local": .addresses([ip("8.8.8.8"), ip("192.168.1.20"), ip("10.0.0.5")]),
        "public.local": .addresses([ip("8.8.8.8"), ip("100.64.1.1"), ip("127.0.0.1")]),
        "linklocal.local": .addresses([ip("169.254.3.4")]),
        "funnel.tail1234.ts.net": .addresses([ip("203.0.113.10")]),
        "quad.tail1234.ts.net": .addresses([ip("100.100.100.100")]),
        "mixed.tail1234.ts.net": .addresses([ip("203.0.113.10"), ip("192.168.1.3"), ip("100.101.102.103")]),
        "empty.local": .addresses([]),
        "slow.local": .slow(.seconds(5), [ip("192.168.1.9")])
    ])
    let resolving = PairingAddressResolver(resolver: resolver, timeout: .milliseconds(300))

    func resolve(_ kind: PairingAddressKind, _ hostname: String) async -> Result<PairingIPv4, any Error> {
        do {
            return .success(try await resolving.resolve(hostname: hostname, kind: kind))
        } catch {
            return .failure(error)
        }
    }

    expect((try? await resolve(.localName, "mixed.local").get()) == ip("192.168.1.20"), "first private address, public one passed over")
    expect(resolver.lookups == ["mixed.local"], "looked up once: \(resolver.lookups)")

    if case .failure(let error) = await resolve(.localName, "public.local"),
       case PairingAddressResolutionError.noAddressInRange(let kind, let name, let found) = error {
        expect(kind == .localName && name == "public.local" && found == [ip("8.8.8.8"), ip("100.64.1.1"), ip("127.0.0.1")], "what was found is reported")
        expect(error.localizedDescription.contains("public.local"), "the message names the name")
    } else {
        expect(false, "a .local name resolving only to public, Tailscale and loopback addresses is refused")
    }
    expect((try? await resolve(.localName, "linklocal.local").get()) == ip("169.254.3.4"), "link-local for .local")

    if case .failure(PairingAddressResolutionError.noAddressInRange(.tailscaleMagicDNS, _, let found)) = await resolve(.tailscaleMagicDNS, "funnel.tail1234.ts.net") {
        expect(found == [ip("203.0.113.10")], "MagicDNS to a public address (Funnel, Tailscale off) is refused")
    } else {
        expect(false, "MagicDNS to a public address is refused")
    }
    if case .failure(let error) = await resolve(.tailscaleMagicDNS, "funnel.tail1234.ts.net") {
        expect(error.localizedDescription.contains("Tailscale DNS"), "the message points at Tailscale DNS: \(error.localizedDescription)")
    }
    if case .failure(PairingAddressResolutionError.noAddressInRange) = await resolve(.tailscaleMagicDNS, "quad.tail1234.ts.net") {
        expect(true, "MagicDNS to quad-100 is refused")
    } else {
        expect(false, "MagicDNS to quad-100 is refused")
    }
    expect((try? await resolve(.tailscaleMagicDNS, "mixed.tail1234.ts.net").get()) == ip("100.101.102.103"), "the Tailscale address among others")

    let before = resolver.lookups.count
    if case .failure(PairingAddressResolutionError.notFound(let name)) = await resolve(.localName, "missing.local") {
        expect(name == "missing.local", "not found names the name")
    } else {
        expect(false, "a lookup that fails is not found")
    }
    if case .failure(PairingAddressResolutionError.notFound) = await resolve(.localName, "empty.local") {
        expect(true, "no addresses is not found")
    } else {
        expect(false, "no addresses is not found")
    }
    expect(resolver.lookups.count == before + 2, "each looked up once")

    // Addresses aren't looked up; values that fail the kind's rules aren't either.
    let counted = resolver.lookups.count
    expect((try? await resolve(.privateIPv4, "192.168.7.8").get()) == ip("192.168.7.8"), "a private address as it is")
    expect((try? await resolve(.tailscaleIPv4, "100.90.1.2").get()) == ip("100.90.1.2"), "a Tailscale address as it is")
    for (kind, value) in [(PairingAddressKind.privateIPv4, "8.8.8.8"), (.tailscaleIPv4, "100.100.100.100"), (.localName, "My-Mac.local"),
                          (.localName, "localhost"), (.tailscaleMagicDNS, "evil.ts.net.example.com")] {
        if case .failure(let error) = await resolve(kind, value) {
            expect(error is PairingAddressError, "\(value) refused before any lookup: \(error)")
        } else {
            expect(false, "\(value) refused for \(kind)")
        }
    }
    expect(resolver.lookups.count == counted, "nothing looked up for addresses and refused values")

    // A lookup that doesn't come back in time.
    let start = ContinuousClock.now
    if case .failure(PairingAddressResolutionError.timedOut(let name)) = await resolve(.localName, "slow.local") {
        expect(name == "slow.local", "timed out names the name")
    } else {
        expect(false, "a slow lookup times out")
    }
    expect(ContinuousClock.now - start < .seconds(3), "the timeout doesn't wait for the lookup")

    // The resolver's result for an address value carries over without a lookup.
    let address = try! PairingAddress(kind: .localName, name: "mixed.local")
    expect((try? await resolving.resolve(address)) == ip("192.168.1.20"), "PairingAddress resolves the same way")
}

// MARK: - Machine JSON

func testMachineJSON() {
    // As saved before authMethod, sessionName, isLocal and addressKind existed.
    let old = #"[{"id":"6F1A1D7E-8F64-4B5C-9C1F-0E6A2A2B3C4D","displayName":"Old","hostname":"old.example","port":22,"username":"me","keychainTag":"herdr-client.private-key.6F1A1D7E-8F64-4B5C-9C1F-0E6A2A2B3C4D"}]"#
    let machines = try? JSONDecoder().decode([Machine].self, from: Data(old.utf8))
    expect(machines?.count == 1, "old JSON decodes")
    if let machine = machines?.first {
        expect(machine.addressKind == nil && machine.authMethod == .key && machine.sessionName == "" && !machine.isLocal
               && machine.pinnedHostKeyFingerprint == nil, "old JSON's defaults")
        let encoded = String(decoding: try! JSONEncoder().encode(machine), as: UTF8.self)
        expect(!encoded.contains("addressKind"), "no address kind is not written: \(encoded)")
        let again = try? JSONDecoder().decode(Machine.self, from: Data(encoded.utf8))
        expect(again == machine, "round trip without a kind")
    }

    var paired = Machine(id: UUID(), displayName: "Studio", hostname: "studio.tail1234.ts.net", username: "me",
                         authMethod: .secureEnclaveKey, addressKind: .tailscaleMagicDNS)
    paired.pinnedHostKeyFingerprint = "SHA256:abc="
    let data = try! JSONEncoder().encode(paired)
    let text = String(decoding: data, as: UTF8.self)
    expect(text.contains(#""addressKind":"tailscaleMagicDNS""#) && text.contains(#""authMethod":"secureEnclaveKey""#), "kind and method written: \(text)")
    let decoded = try? JSONDecoder().decode(Machine.self, from: data)
    expect(decoded == paired && decoded?.addressKind == .tailscaleMagicDNS && decoded?.authMethod == .secureEnclaveKey, "round trip with a kind")

    var moved = paired
    moved.addressKind = .localName
    expect(moved.connectionIdentity != paired.connectionIdentity, "the kind is part of the connection's identity")
    var renamed = paired
    renamed.displayName = "Renamed"
    expect(renamed.connectionIdentity == paired.connectionIdentity, "a rename still isn't")

    let unknown = text.replacingOccurrences(of: "tailscaleMagicDNS", with: "carrierPigeon")
    expect((try? JSONDecoder().decode(Machine.self, from: Data(unknown.utf8))) == nil, "a kind this version doesn't know isn't read as none")
    expect(Machine.AddressKind.allCases.map(\.rawValue) == ["localName", "privateIPv4", "tailscaleIPv4", "tailscaleMagicDNS"], "stored names")
}

// MARK: - QR code

func samplePayload(address: PairingAddress, herdrSession: String = "", macName: String = "Minsu's MacBook Pro",
                   username: String = "minsu") throws -> PairingPayload {
    let hostKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    var blob = Data()
    for field in [Data("ssh-ed25519".utf8), hostKey] {
        blob.append(contentsOf: withUnsafeBytes(of: UInt32(field.count).bigEndian) { Array($0) })
        blob.append(field)
    }
    return try PairingPayload(
        sessionID: randomBytes(16), presharedKey: randomBytes(32),
        macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
        expiresAt: Date(timeIntervalSince1970: 1_790_000_000.7), pairingPort: 49_152, address: address,
        hostKey: try PairingPayload.HostKey(publicKeyBlob: blob), username: username, herdrSession: herdrSession,
        macID: UUID(), macName: macName)
}

/// Builds a code's bytes field by field, for codes the encoder won't make.
func code(_ fields: [(UInt8, [UInt8])], prefix: String = "SHPHRD1:") -> String {
    var bytes: [UInt8] = []
    for (tag, value) in fields {
        bytes += [tag, UInt8(value.count)] + value
    }
    return prefix + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// A valid code's fields, to change one at a time.
func fields(of text: String) -> [(UInt8, [UInt8])] {
    var base64 = String(text.dropFirst(8)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let bytes = Array(Data(base64Encoded: base64)!)
    var result: [(UInt8, [UInt8])] = []
    var offset = 0
    while offset < bytes.count {
        let length = Int(bytes[offset + 1])
        result.append((bytes[offset], Array(bytes[offset + 2..<offset + 2 + length])))
        offset += 2 + length
    }
    return result
}

func replacing(_ fields: [(UInt8, [UInt8])], tag: UInt8, with value: [UInt8]?) -> [(UInt8, [UInt8])] {
    fields.compactMap { field in
        guard field.0 == tag else { return field }
        return value.map { (tag, $0) }
    }
}

func testPayload() throws {
    let addresses = [
        try PairingAddress(kind: .tailscaleMagicDNS, name: "minsu-mbp.tail1234.ts.net"),
        try PairingAddress(kind: .tailscaleIPv4, ipv4: ip("100.101.102.103")),
        try PairingAddress(kind: .localName, name: "minsu-mbp.local"),
        try PairingAddress(kind: .privateIPv4, ipv4: ip("192.168.0.12"))
    ]
    for address in addresses {
        for session in ["", "work"] {
            let payload = try samplePayload(address: address, herdrSession: session)
            let text = try payload.encoded()
            expect(text.hasPrefix("SHPHRD1:"), "prefix")
            expect(text.utf8.count <= 1024 && text.utf8.count < 400, "typical size \(text.utf8.count)")
            expect(text.dropFirst(8).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }, "base64url without padding")
            let decoded = try? PairingPayload(scanned: text)
            expect(decoded == payload, "round trip for \(address.kind) \(session.isEmpty ? "default session" : session)")
            expect(fields(of: text).contains { $0.0 == 0x0B } == !session.isEmpty, "the default session is left out")
            if case .ipv4 = address.value {
                expect(fields(of: text).first { $0.0 == 0x07 }?.1.count == 5, "an IPv4 address is four bytes")
            }
        }
    }

    let payload = try samplePayload(address: addresses[0], macName: "민수의 MacBook Pro")
    let text = try payload.encoded()
    let decoded = try PairingPayload(scanned: text)
    expect(decoded.macName == "민수의 MacBook Pro" && decoded.macID == payload.macID && decoded.username == "minsu", "names and ID")
    expect(decoded.expiresAt == Date(timeIntervalSince1970: 1_790_000_000), "whole seconds")
    expect(decoded.isExpired(at: Date(timeIntervalSince1970: 1_790_000_000)) && !decoded.isExpired(at: Date(timeIntervalSince1970: 1_789_999_999)), "expiry")
    expect(decoded.hostKey.algorithm == .ed25519 && decoded.hostKey.fingerprint.hasPrefix("SHA256:") && decoded.hostKey.fingerprint.count == 51,
           "host key \(decoded.hostKey.fingerprint)")
    expect(decoded.sshPort == 22 && decoded.pairingPort == 49_152, "ports")

    // The machine the device saves.
    let machine = decoded.machine()
    expect(machine.id == payload.macID && machine.displayName == "민수의 MacBook Pro" && machine.hostname == "minsu-mbp.tail1234.ts.net"
           && machine.port == 22 && machine.username == "minsu" && machine.sessionName == "" && machine.authMethod == .secureEnclaveKey
           && machine.addressKind == .tailscaleMagicDNS && machine.pinnedHostKeyFingerprint == decoded.hostKey.fingerprint && !machine.isLocal,
           "the saved machine")
    expect(decoded.machine(displayName: "Studio").displayName == "Studio", "a name of the person's own")
    let literal = try PairingPayload(scanned: try samplePayload(address: addresses[3], herdrSession: "work").encoded()).machine()
    expect(literal.hostname == "192.168.0.12" && literal.addressKind == .privateIPv4 && literal.sessionName == "work", "an address and a session")

    // 1 KiB at most, either way.
    let longName = String(repeating: "a", count: 62) + "." + String(repeating: "b", count: 62) + "." + String(repeating: "c", count: 62) + ".d.ts.net"
    let long = try samplePayload(address: try PairingAddress(kind: .tailscaleMagicDNS, name: longName),
                                 macName: String(repeating: "M", count: 255), username: String(repeating: "u", count: 255))
    expectError(PairingPayloadError.tooLong) { _ = try long.encoded() }
    expectError(PairingPayloadError.tooLong) { _ = try PairingPayload(scanned: "SHPHRD1:" + String(repeating: "A", count: 1017)) }
    let original = fields(of: text)
    let padded = code(replacing(original, tag: 0x0D, with: Array(String(repeating: "M", count: 255).utf8)))
    expect(padded.utf8.count <= 1024 && (try? PairingPayload(scanned: padded)) != nil, "a long Mac name still fits (\(padded.utf8.count))")

    // Versions and kinds this version doesn't know.
    expectError(PairingPayloadError.needsNewerApp) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x01, with: [2]))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x01, with: [0]))) }
    expectError(PairingPayloadError.needsNewerApp) { _ = try PairingPayload(scanned: "SHPHRD2:" + String(text.dropFirst(8))) }
    expectError(PairingPayloadError.needsNewerApp) {
        _ = try PairingPayload(scanned: code(replacing(original, tag: 0x07, with: [5] + Array("minsu-mbp.tail1234.ts.net".utf8))))
    }
    expectError(PairingPayloadError.needsNewerApp) {
        // A later version's field next to its version number is still a later version.
        _ = try PairingPayload(scanned: code(replacing(original, tag: 0x01, with: [2]) + [(0x40, [1, 2, 3])]))
    }
    for other in ["https://example.com", "SHPHRD", "SHPHRD1", "shphrd1:" + String(text.dropFirst(8)), "", "SHPHRDx:abc", "SHPHRD0:" + String(text.dropFirst(8))] {
        expectError(PairingPayloadError.notAPairingCode) { _ = try PairingPayload(scanned: other) }
    }

    // Damage.
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(original + [(0x40, [1])])) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(original + [(0x02, Array(randomBytes(16)))])) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x0C, with: nil))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x02, with: Array(randomBytes(15))))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: String(text.dropLast(3))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: text + "=") }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "+") }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: "SHPHRD1:" + String(text.dropFirst(8)).prefix(10) + "\n" + String(text.dropFirst(18))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x06, with: [0x03, 0xFF]))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x08, with: [0x08, 0xAE]))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x09, with: [9] + Array(randomBytes(32))))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x0A, with: Array("min su".utf8)))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x0D, with: Array("Mac\nmini".utf8)))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x0D, with: [0xFF, 0xFE]))) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(original + [(0x0B, Array("bad/name".utf8))])) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(original + [(0x0B, Array("default".utf8))])) }
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x07, with: [2, 192, 168, 0]))) }

    // Addresses the kinds don't allow.
    for (value, expected) in [([2, 8, 8, 8, 8] as [UInt8], PairingAddressError.invalid(.privateIPv4, "8.8.8.8")),
                              ([3, 100, 100, 100, 100], .invalid(.tailscaleIPv4, "100.100.100.100")),
                              ([1] + Array("Minsu-MBP.local".utf8), .invalid(.localName, "Minsu-MBP.local")),
                              ([4] + Array("evil.ts.net.example.com".utf8), .invalid(.tailscaleMagicDNS, "evil.ts.net.example.com")),
                              ([4] + Array("xts.net".utf8), .invalid(.tailscaleMagicDNS, "xts.net"))] {
        expectError(PairingPayloadError.invalidAddress(expected)) { _ = try PairingPayload(scanned: code(replacing(original, tag: 0x07, with: value))) }
    }

    // What the encoder refuses to make.
    expect(thrown { _ = try samplePayload(address: addresses[0], username: "min su") } as? PairingPayloadError == .malformed, "no space in a user name")
    expect(thrown { _ = try samplePayload(address: addresses[0], macName: "") } as? PairingPayloadError == .malformed, "a Mac name")
    expect(thrown { _ = try samplePayload(address: addresses[0], herdrSession: "default") } as? PairingPayloadError == .malformed, "the default session is \"\"")

    // The host key's form.
    expectError(PairingPayloadError.malformed) { _ = try PairingPayload.HostKey(publicKeyBlob: Data([0, 0, 0, 3]) + Data("dsa".utf8)) }
    expect(PairingPayload.HostKeyAlgorithm.allCases.allSatisfy { PairingPayload.HostKeyAlgorithm(name: $0.name) == $0 }, "algorithm names")
    for error in [PairingPayloadError.notAPairingCode, .needsNewerApp, .malformed, .tooLong, .expired] {
        expect(error.errorDescription?.isEmpty == false, "\(error) has a message")
    }
}

// MARK: - Messages

func testProtocol() throws {
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let sessionID = randomBytes(16)
    let psk = randomBytes(32)
    let deviceKey = SecureEnclaveSSHKey.makeSoftware()
    let request = PairingRequest(deviceID: UUID(), deviceName: "  Minsu's iPhone ", deviceModel: "iPhone", appVersion: "1.0 (7)",
                                 publicKey: deviceKey.publicKeyBlob)

    var device = try PairingDeviceChannel(sessionID: sessionID, presharedKey: psk, macPublicKey: macKey.publicKey.rawRepresentation)
    let m1 = try device.request(request)
    var reader = PairingFrameReader()
    var frames: [Data] = []
    for byte in m1 { frames += try reader.append([byte]) }
    expect(frames.count == 1, "one frame, read a byte at a time")
    let body = frames[0]
    expect(body.prefix(4) == Data("SHP1".utf8) && body[body.startIndex + 4] == 1 && Data(body.dropFirst(5).prefix(16)) == sessionID, "M1 header")
    let envelope = try PairingEnvelope(body: body)
    expect(envelope.type == .request && envelope.sessionID == sessionID, "M1 envelope")

    let opened = try PairingMacChannel.open(request: envelope, sessionID: sessionID, presharedKey: psk, privateKey: macKey)
    var mac = opened.channel
    let received = opened.request
    expect(received.deviceID == request.deviceID && received.deviceName == "Minsu's iPhone" && received.publicKey == deviceKey.publicKeyBlob,
           "M1 contents, the name trimmed")
    expect(mac.confirmationCode == device.confirmationCode, "both sides' code: \(mac.confirmationCode) \(device.confirmationCode)")
    expect(device.confirmationCode.value < 1_000_000 && device.confirmationCode.digits.count == 6, "six digits")
    let shown = device.confirmationCode.description
    expect(shown.count == 7 && shown.dropFirst(3).first == " " && shown.replacingOccurrences(of: " ", with: "") == device.confirmationCode.digits, "shown as ddd ddd: \(shown)")
    expect(PairingConfirmationCode(value: 42).description == "000 042", "leading zeros")

    // The code as the protocol defines it, from an HPKE context of the test's own.
    var recipient = try HPKE.Recipient(privateKey: macKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                                       info: Data("shepherd-pair v1".utf8) + sessionID,
                                       encapsulatedKey: Data(envelope.content.prefix(32)),
                                       presharedKey: SymmetricKey(data: psk), presharedKeyIdentifier: sessionID)
    let ownPlain = try recipient.open(Data(envelope.content.dropFirst(32)), authenticating: Data(body.prefix(21)) + Data(envelope.content.prefix(32)))
    expect((try? JSONDecoder().decode(PairingRequest.self, from: ownPlain))?.deviceID == request.deviceID, "M1 is the HPKE seal the protocol describes")
    let exported = try recipient.exportSecret(context: Data("shepherd-pair v1 sas".utf8), outputByteCount: 4)
    let number = exported.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    expect(device.confirmationCode.value == number % 1_000_000, "code = exportSecret(\"shepherd-pair v1 sas\", 4) mod 10^6")
    let json = String(decoding: ownPlain, as: UTF8.self)
    expect(json.contains("\"device_id\"") && json.contains("\"public_key\""), "M1's JSON keys: \(json)")

    // M2 and M3.
    let macID = UUID()
    let m2 = try mac.response(PairingResponse(decision: .approved, macID: macID))
    let m2Envelope = try PairingEnvelope(body: try reader.append(m2)[0])
    let answer = try device.openResponse(m2Envelope)
    expect(answer.decision == .approved && answer.macID == macID, "M2")
    let rejected = try device.openResponse(try PairingEnvelope(body: Data(try mac.response(PairingResponse(decision: .rejected, macID: macID)).dropFirst(4))))
    expect(rejected.decision == .rejected, "M2, turned down")
    let report = PairingReport(sshConnected: true, herdrReached: false, failure: "herdr isn't running")
    let m3 = try device.report(report)
    expect(try mac.openReport(try PairingEnvelope(body: Data(m3.dropFirst(4)))) == report, "M3")

    // A wrong secret, another code, another key, changed bytes.
    func openM1(_ body: Data, sessionID: Data = sessionID, psk: Data = psk, key: Curve25519.KeyAgreement.PrivateKey = macKey) -> (any Error)? {
        thrown { _ = try PairingMacChannel.open(request: try PairingEnvelope(body: body), sessionID: sessionID, presharedKey: psk, privateKey: key) }
    }
    expect(openM1(body, psk: randomBytes(32)) as? PairingProtocolError == .unreadable, "wrong secret")
    expect(openM1(body, sessionID: randomBytes(16)) as? PairingProtocolError == .wrongSession, "another code's session")
    expect(openM1(body, key: Curve25519.KeyAgreement.PrivateKey()) as? PairingProtocolError == .unreadable, "another Mac key")
    var relabelled = body
    let otherSession = randomBytes(16)
    relabelled.replaceSubrange(relabelled.startIndex + 5..<relabelled.startIndex + 21, with: otherSession)
    expect(openM1(relabelled, sessionID: otherSession) as? PairingProtocolError == .unreadable, "a message moved to another session doesn't open")
    for offset in [21, 40, body.count - 30, body.count - 1] {
        var changed = body
        changed[changed.startIndex + offset] ^= 0x01
        expect(openM1(changed) as? PairingProtocolError == .unreadable, "byte \(offset) changed")
    }
    var retyped = body
    retyped[retyped.startIndex + 4] = 3
    expect(openM1(retyped) as? PairingProtocolError == .unreadable, "M1 as another type")
    var badHeader = body
    badHeader[badHeader.startIndex] = UInt8(ascii: "X")
    expect(openM1(badHeader) as? PairingProtocolError == .unreadable, "not SHP1")
    expect(openM1(Data(body.prefix(30))) as? PairingProtocolError == .unreadable, "cut short")

    // M2 that isn't the Mac's.
    var changedM2 = Data(m2.dropFirst(4))
    changedM2[changedM2.startIndex + 30] ^= 0x80
    expect(thrown { _ = try device.openResponse(try PairingEnvelope(body: changedM2)) } as? PairingProtocolError == .unreadable, "changed M2")
    var otherDevice = try PairingDeviceChannel(sessionID: sessionID, presharedKey: psk, macPublicKey: macKey.publicKey.rawRepresentation)
    _ = try otherDevice.request(request)
    expect(thrown { _ = try otherDevice.openResponse(m2Envelope) } as? PairingProtocolError == .unreadable, "M2 for another device's context")
    expect(thrown { _ = try device.openResponse(try PairingEnvelope(body: Data(m3.dropFirst(4)))) } as? PairingProtocolError == .unreadable, "M3 isn't M2")

    // The Mac's unencrypted failure.
    let failure = try PairingProtocol.failure(.alreadyUsed, sessionID: sessionID)
    let failureEnvelope = try PairingEnvelope(body: Data(failure.dropFirst(4)))
    expect(failureEnvelope.type == .failure && failureEnvelope.failure == .alreadyUsed, "failure message")
    expect(thrown { _ = try device.openResponse(failureEnvelope) } as? PairingProtocolError == .failed(.alreadyUsed), "the device reads why")
    expect(PairingProtocolError.failed(.alreadyUsed).errorDescription?.isEmpty == false, "already used has a message")

    // Order.
    var fresh = try PairingDeviceChannel(sessionID: sessionID, presharedKey: psk, macPublicKey: macKey.publicKey.rawRepresentation)
    expect(thrown { _ = try fresh.report(report) } as? PairingProtocolError == .outOfOrder, "no M3 before M1")
    _ = try fresh.request(request)
    expect(thrown { _ = try fresh.request(request) } as? PairingProtocolError == .outOfOrder, "one M1")

    // Requests the Mac doesn't accept, sealed properly.
    for bad in [PairingRequest(deviceID: UUID(), deviceName: "", deviceModel: "iPhone", appVersion: "1", publicKey: deviceKey.publicKeyBlob),
                PairingRequest(deviceID: UUID(), deviceName: "Two\nLines", deviceModel: "iPhone", appVersion: "1", publicKey: deviceKey.publicKeyBlob),
                PairingRequest(deviceID: UUID(), deviceName: String(repeating: "x", count: 65), deviceModel: "iPhone", appVersion: "1", publicKey: deviceKey.publicKeyBlob),
                PairingRequest(deviceID: UUID(), deviceName: "Phone", deviceModel: "iPhone", appVersion: "1", publicKey: Data("ssh-ed25519".utf8))] {
        var sender = try PairingDeviceChannel(sessionID: sessionID, presharedKey: psk, macPublicKey: macKey.publicKey.rawRepresentation)
        let framed = try sender.request(bad)
        expect(openM1(Data(framed.dropFirst(4))) as? PairingProtocolError == .invalidRequest, "refused request: \(bad.deviceName.debugDescription)")
    }

    // Frames.
    var two = PairingFrameReader()
    let both = try two.append(m1 + m2)
    expect(both.count == 2 && both[0] == body, "two frames in one read")
    var large = PairingFrameReader()
    expect(thrown { _ = try large.append([0, 0, 0x20, 0x01]) } as? PairingProtocolError == .tooLong, "a frame over 8 KiB is refused from its length")
    var exact = PairingFrameReader()
    expect((try? exact.append([0, 0, 0x20, 0x00])) == [], "8 KiB exactly waits for its body")
    expect(thrown { _ = try PairingProtocol.frame(Data(count: 8 * 1024 + 1)) } as? PairingProtocolError == .tooLong, "no frame over 8 KiB is made")
    expect((try? PairingProtocol.frame(Data(count: 8 * 1024)))?.count == 8 * 1024 + 4, "8 KiB is made")
    expect(thrown { _ = try PairingDeviceChannel(sessionID: randomBytes(15), presharedKey: psk, macPublicKey: macKey.publicKey.rawRepresentation) } != nil, "16-byte sessions")
}

// MARK: - authorized_keys

func testAuthorizedKeys(outputDirectory: URL) throws {
    let key = SecureEnclaveSSHKey.makeSoftware()
    let deviceID = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!
    let line = try AuthorizedKeyLine(devicePublicKey: key.publicKeyBlob, deviceID: deviceID, deviceName: "Minsu's iPhone 15")
    let base64 = key.publicKeyBlob.base64EncodedString()
    expect(line.text == "restrict,port-forwarding ecdsa-sha2-nistp256 \(base64) shepherd-mobile:0f1e2d3c:minsu-s-iphone-15", line.text)
    expect(line.marker == "shepherd-mobile:0f1e2d3c:minsu-s-iphone-15" && line.fingerprint == key.fingerprint, "marker and fingerprint")
    try (line.text + "\n").write(to: outputDirectory.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
    try (key.fingerprint + "\n").write(to: outputDirectory.appendingPathComponent("fingerprint"), atomically: true, encoding: .utf8)

    expect(line.matches(line.text) && line.matches(line.text + "\n") && line.matches("  " + line.text + "\r\n"), "its own line")
    expect(line.matches("restrict ecdsa-sha2-nistp256 \(base64) \(line.marker)"), "options changed by hand")
    expect(line.matches("ecdsa-sha2-nistp256 \(base64) \(line.marker)"), "no options")
    expect(!line.matches("restrict,port-forwarding ecdsa-sha2-nistp256 \(base64) shepherd-mobile:0f1e2d3c:other"), "another marker")
    expect(!line.matches("restrict,port-forwarding ecdsa-sha2-nistp256 \(base64) \(line.marker) extra"), "the marker with more after it")
    let other = SecureEnclaveSSHKey.makeSoftware()
    expect(!line.matches("restrict,port-forwarding ecdsa-sha2-nistp256 \(other.publicKeyBlob.base64EncodedString()) \(line.marker)"), "another key with the marker")
    expect(!line.matches("# " + line.text) && !line.matches("") && !line.matches("garbage"), "comments and other lines")
    expect(line.hasSameKey(as: "ecdsa-sha2-nistp256 \(base64) minsu@laptop") && !line.hasSameKey(as: other.publicKeyLine()), "the same key under another comment")

    // Lines as sshd reads them.
    let quoted = AuthorizedKeysEntry(line: #"command="echo \"a b\"",no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA== a comment"#)
    expect(quoted?.options == #"command="echo \"a b\"",no-pty"# && quoted?.keyType == "ssh-ed25519" && quoted?.comment == "a comment", "quoted options")
    expect(AuthorizedKeysEntry(line: #"command="unterminated ssh-ed25519 AAAA"#) == nil, "unterminated quotes")
    expect(AuthorizedKeysEntry(line: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA==")?.comment == "", "no comment")
    expect(AuthorizedKeysEntry(line: "ssh-ed25519 not-base64!") == nil, "not base64")
    expect(AuthorizedKeysEntry(line: "   # ssh-ed25519 AAAA") == nil && AuthorizedKeysEntry(line: "\n") == nil, "comment and blank lines")

    // The device's key is parsed and written out again.
    let blob = key.publicKeyBlob
    let id = UUID()
    expectError(AuthorizedKeyLineError.notAP256Key) { _ = try AuthorizedKeyLine(devicePublicKey: blob + Data([0]), deviceID: id, deviceName: "x") }
    expectError(AuthorizedKeyLineError.notAP256Key) { _ = try AuthorizedKeyLine(devicePublicKey: Data(blob.dropLast()), deviceID: id, deviceName: "x") }
    var notOnCurve = blob
    notOnCurve[notOnCurve.endIndex - 1] ^= 0x01
    expectError(AuthorizedKeyLineError.notAP256Key) { _ = try AuthorizedKeyLine(devicePublicKey: notOnCurve, deviceID: id, deviceName: "x") }
    var renamed = blob
    renamed.replaceSubrange(renamed.startIndex + 4 + 6..<renamed.startIndex + 4 + 19, with: Data("sha2-nistp384".utf8))
    expectError(AuthorizedKeyLineError.notAP256Key) { _ = try AuthorizedKeyLine(devicePublicKey: renamed, deviceID: id, deviceName: "x") }
    var compressedBlob = Data()
    for field in [Data("ecdsa-sha2-nistp256".utf8), Data("nistp256".utf8), key.publicKey.compressedRepresentation] {
        compressedBlob.append(contentsOf: withUnsafeBytes(of: UInt32(field.count).bigEndian) { Array($0) })
        compressedBlob.append(field)
    }
    expectError(AuthorizedKeyLineError.notAP256Key) { _ = try AuthorizedKeyLine(devicePublicKey: compressedBlob, deviceID: id, deviceName: "x") }
    var ed25519Blob = Data()
    for field in [Data("ssh-ed25519".utf8), Curve25519.Signing.PrivateKey().publicKey.rawRepresentation] {
        ed25519Blob.append(contentsOf: withUnsafeBytes(of: UInt32(field.count).bigEndian) { Array($0) })
        ed25519Blob.append(field)
    }
    expectError(AuthorizedKeyLineError.notAP256Key) { _ = try AuthorizedKeyLine(devicePublicKey: ed25519Blob, deviceID: id, deviceName: "x") }
    expectError(AuthorizedKeyLineError.notAP256Key) { _ = try AuthorizedKeyLine(devicePublicKey: Data([0, 0, 0, 0xFF]), deviceID: id, deviceName: "x") }

    // Slugs.
    for (name, slug) in [("José's iPad", "jose-s-ipad"), ("민수의 iPhone", "iphone"), ("!!!", "device"), ("", "device"), ("ＡＢＣ Phone", "abc-phone"),
                         ("--Work  Phone--", "work-phone"), ("a; rm -rf ~", "a-rm-rf")] {
        expect(AuthorizedKeyLine.slug(for: name) == slug, "slug of \(name.debugDescription): \(AuthorizedKeyLine.slug(for: name))")
    }
    let longSlug = AuthorizedKeyLine.slug(for: String(repeating: "abcd ", count: 20))
    expect(longSlug.count <= 32 && !longSlug.hasSuffix("-") && longSlug.hasPrefix("abcd-abcd"), "long names: \(longSlug)")
    expect(AuthorizedKeyLine.shortID(deviceID) == "0f1e2d3c", "short ID")
}

// MARK: - Device key

func testDeviceKey() throws {
    let key = SecureEnclaveSSHKey.makeSoftware()
    expect(key.backing == .software, "the stand-in is software")
    let stored = key.storedRepresentation
    expect(stored.count == 33 && stored.first == 2, "stored: backing byte and the scalar")
    let restored = try SecureEnclaveSSHKey(storedRepresentation: stored)
    expect(restored.publicKey.rawRepresentation == key.publicKey.rawRepresentation && restored.backing == .software, "restored")
    let message = Data("session id and user auth request".utf8)
    let signature = try restored.signature(for: message)
    expect(key.publicKey.isValidSignature(signature, for: message), "the restored key signs for the public key")
    expect(!SecureEnclaveSSHKey.makeSoftware().publicKey.isValidSignature(signature, for: message), "another key doesn't verify")

    // ecdsa-sha2-nistp256 in the SSH wire form, 104 bytes.
    let blob = Array(key.publicKeyBlob)
    expect(blob.count == 104, "blob length \(blob.count)")
    expect(Array(blob[0..<4]) == [0, 0, 0, 19] && Array(blob[4..<23]) == Array("ecdsa-sha2-nistp256".utf8), "key type field")
    expect(Array(blob[23..<27]) == [0, 0, 0, 8] && Array(blob[27..<35]) == Array("nistp256".utf8), "curve field")
    expect(Array(blob[35..<39]) == [0, 0, 0, 65] && blob[39] == 4 && Array(blob[39...]) == Array(key.publicKey.x963Representation), "point field")
    expect((try? SSHP256PublicKey.publicKey(fromBlob: key.publicKeyBlob))?.rawRepresentation == key.publicKey.rawRepresentation, "blob parses back")
    expect(key.publicKeyLine() == "ecdsa-sha2-nistp256 " + key.publicKeyBlob.base64EncodedString(), "line without comment")
    expect(key.publicKeyLine(comment: " phone ") == "ecdsa-sha2-nistp256 " + key.publicKeyBlob.base64EncodedString() + " phone", "line with comment")
    expect(key.fingerprint == "SHA256:" + Data(SHA256.hash(data: key.publicKeyBlob)).base64EncodedString(), "fingerprint")

    // Only software stored forms are opened here; a Secure Enclave one would
    // go to the enclave, which the tests leave alone.
    for bad in [Data(), Data([3]) + Data(count: 32), Data([2]) + Data(count: 31), Data([2]) + Data(count: 33), Data([0])] {
        expectError(SecureEnclaveSSHKeyError.unreadable) { _ = try SecureEnclaveSSHKey(storedRepresentation: bad) }
    }
    expect(Machine.AuthMethod.secureEnclaveKey.rawValue == "secureEnclaveKey", "stored method name")
}

@main enum PairingCoreTests {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        testAddresses()
        await testResolver()
        testMachineJSON()
        try testPayload()
        try testProtocol()
        try testAuthorizedKeys(outputDirectory: output)
        try testDeviceKey()
        print(failures == 0 ? "\(checks) checks passed" : "\(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
