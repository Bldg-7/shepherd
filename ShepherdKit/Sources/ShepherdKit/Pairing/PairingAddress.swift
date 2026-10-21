import Foundation

// The address a Mac's pairing QR code carries, and the rules a device holds
// it to before connecting (SHPHRD-77, "QR 내용" and "기기 쪽 검증"). A code
// is something anyone can show a camera, so nothing in it is trusted as it
// stands: each kind of address may only be a value of that kind's shape, and
// may only lead to an IPv4 address in that kind's range. Names are looked up
// once (see `PairingAddressResolver`) and the connection goes to the IPv4
// address that came back, so what was checked is what is connected to.

/// The kinds of address a pairing QR code can carry. The cases are declared
/// with `Machine` (as `Machine.AddressKind`), which stores the kind of the
/// address it connects to.
public typealias PairingAddressKind = Machine.AddressKind

/// An IPv4 address, held as its four bytes.
public nonisolated struct PairingIPv4: Hashable, Sendable, CustomStringConvertible {
    /// The four bytes as one big-endian number: 10.1.2.3 is 0x0A010203.
    public let value: UInt32

    public init(value: UInt32) {
        self.value = value
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// Exactly four bytes, in network order.
    public init?<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        guard bytes.count == 4 else { return nil }
        let array = Array(bytes)
        self.init(array[0], array[1], array[2], array[3])
    }

    /// Dotted-decimal notation and nothing else: four parts of one to three
    /// digits, each 255 at most and without a leading zero. The looser forms
    /// `inet_aton` takes ("10.1", "0x0a.1.2.3", "010.1.2.3") are rejected,
    /// so that a value means the same address to every reader.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            let digits = Array(part.utf8)
            guard (1...3).contains(digits.count), digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            if digits.count > 1 && digits[0] == 0x30 { return nil }
            let number = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
            guard number <= 255 else { return nil }
            bytes.append(UInt8(number))
        }
        self.init(bytes[0], bytes[1], bytes[2], bytes[3])
    }

    public var bytes: [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    public var description: String {
        bytes.map(String.init).joined(separator: ".")
    }
}

/// An IPv4 network: the addresses that share its first `prefixLength` bits.
public nonisolated struct IPv4Range: Hashable, Sendable, CustomStringConvertible {
    public let network: PairingIPv4
    public let prefixLength: Int

    public init(_ network: PairingIPv4, prefixLength: Int) {
        precondition((0...32).contains(prefixLength))
        self.network = PairingIPv4(value: network.value & Self.mask(prefixLength))
        self.prefixLength = prefixLength
    }

    public func contains(_ address: PairingIPv4) -> Bool {
        address.value & Self.mask(prefixLength) == network.value
    }

    public var description: String {
        "\(network)/\(prefixLength)"
    }

    private static func mask(_ prefixLength: Int) -> UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << (32 - prefixLength)
    }
}

/// The address ranges the kinds are held to. The Mac's address selector and
/// pairing listener use the same constants.
public nonisolated enum PairingAddressRanges {
    /// RFC 1918.
    public static let privateNetworks = [
        IPv4Range(PairingIPv4(10, 0, 0, 0), prefixLength: 8),
        IPv4Range(PairingIPv4(172, 16, 0, 0), prefixLength: 12),
        IPv4Range(PairingIPv4(192, 168, 0, 0), prefixLength: 16)
    ]
    /// IPv4 link-local (RFC 3927), where two devices on one link end up
    /// without a DHCP server.
    public static let linkLocal = IPv4Range(PairingIPv4(169, 254, 0, 0), prefixLength: 16)
    /// RFC 6598's shared address space, which Tailscale gives its nodes
    /// addresses from.
    public static let tailscaleNodes = IPv4Range(PairingIPv4(100, 64, 0, 0), prefixLength: 10)
    /// What Tailscale keeps for itself inside `tailscaleNodes`: 100.100.100.100
    /// is its DNS resolver ("quad-100") and 100.115.92.0/23 is reserved
    /// (tailscale `net/tsaddr`), so no node is either.
    public static let tailscaleReserved = [
        IPv4Range(PairingIPv4(100, 100, 100, 100), prefixLength: 32),
        IPv4Range(PairingIPv4(100, 115, 92, 0), prefixLength: 23)
    ]
    /// The first six bytes of Tailscale's IPv6 ULA prefix, fd7a:115c:a1e0::/48.
    public static let tailscaleULAPrefix: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]

    public static func isPrivate(_ address: PairingIPv4) -> Bool {
        privateNetworks.contains { $0.contains(address) }
    }

    /// What a device on the same Wi-Fi or wired network can have: private or
    /// link-local.
    public static func isLAN(_ address: PairingIPv4) -> Bool {
        isPrivate(address) || linkLocal.contains(address)
    }

    public static func isTailscale(_ address: PairingIPv4) -> Bool {
        tailscaleNodes.contains(address) && !tailscaleReserved.contains { $0.contains(address) }
    }

    /// Whether 16 bytes of an IPv6 address are in fd7a:115c:a1e0::/48.
    public static func isTailscaleULA<Bytes: Collection>(_ ipv6: Bytes) -> Bool where Bytes.Element == UInt8 {
        ipv6.count == 16 && ipv6.prefix(tailscaleULAPrefix.count).elementsEqual(tailscaleULAPrefix)
    }
}

public extension Machine.AddressKind {
    /// The kind's byte in a pairing QR code.
    nonisolated var tag: UInt8 {
        switch self {
        case .localName: 1
        case .privateIPv4: 2
        case .tailscaleIPv4: 3
        case .tailscaleMagicDNS: 4
        }
    }

    /// Nil for a byte this version doesn't know.
    nonisolated init?(tag: UInt8) {
        guard let kind = Self.allCases.first(where: { $0.tag == tag }) else { return nil }
        self = kind
    }

    /// The order the Mac picks a kind in when nothing was picked before:
    /// MagicDNS, Tailscale IPv4, .local, private IPv4.
    nonisolated static let preferenceOrder: [Machine.AddressKind] = [.tailscaleMagicDNS, .tailscaleIPv4, .localName, .privateIPv4]

    /// Whether the value is a name, looked up when connecting, rather than
    /// an IPv4 address.
    nonisolated var isName: Bool {
        self == .localName || self == .tailscaleMagicDNS
    }

    /// Whether the kind only reaches as far as the network the device is on.
    nonisolated var isLAN: Bool {
        self == .localName || self == .privateIPv4
    }

    /// Whether a connection for this kind may go to `address`: a .local name
    /// to a private or link-local address, a private IPv4 address only to
    /// RFC 1918, and both Tailscale kinds only to a Tailscale node address.
    nonisolated func allows(_ address: PairingIPv4) -> Bool {
        switch self {
        case .localName: PairingAddressRanges.isLAN(address)
        case .privateIPv4: PairingAddressRanges.isPrivate(address)
        case .tailscaleIPv4, .tailscaleMagicDNS: PairingAddressRanges.isTailscale(address)
        }
    }

    /// The kind's name, as the Mac's selector and the device's preview show it.
    nonisolated var displayName: String {
        switch self {
        case .localName: String(localized: ".local Name", bundle: .shepherdKit)
        case .privateIPv4: String(localized: "Private IPv4", bundle: .shepherdKit)
        case .tailscaleIPv4: "Tailscale IPv4"
        case .tailscaleMagicDNS: "Tailscale MagicDNS"
        }
    }
}

/// An address that is a valid value of its kind. The initializers are the
/// checks; a `PairingAddress` that exists has passed them.
public nonisolated struct PairingAddress: Hashable, Sendable, CustomStringConvertible {
    public enum Value: Hashable, Sendable {
        case ipv4(PairingIPv4)
        /// Lower-case ASCII, without a trailing dot.
        case name(String)
    }

    /// The most bytes a DNS name can have in text form, without the trailing dot.
    public static let maximumNameLength = 253

    public let kind: PairingAddressKind
    public let value: Value

    /// For the IPv4 kinds: the address must be in the kind's range.
    public init(kind: PairingAddressKind, ipv4: PairingIPv4) throws {
        guard !kind.isName, kind.allows(ipv4) else { throw PairingAddressError.invalid(kind, ipv4.description) }
        self.kind = kind
        value = .ipv4(ipv4)
    }

    /// For the name kinds. A .local name is one label and `.local`:
    /// `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.local$`. A MagicDNS name is at
    /// least four such labels ending in `.ts.net` (`<host>.<tailnet>.ts.net`),
    /// 253 bytes at most. Both are lower-case ASCII: no capitals, no trailing
    /// dot and no internationalised name, so that one name has one spelling.
    public init(kind: PairingAddressKind, name: String) throws {
        guard kind.isName, Self.isValidName(name, for: kind) else { throw PairingAddressError.invalid(kind, name) }
        self.kind = kind
        value = .name(name)
    }

    /// From what `Machine.hostname` holds: a dotted-decimal address for the
    /// IPv4 kinds, a name for the others.
    public init(kind: PairingAddressKind, hostname: String) throws {
        if kind.isName {
            try self.init(kind: kind, name: hostname)
        } else {
            guard let address = PairingIPv4(hostname) else { throw PairingAddressError.invalid(kind, hostname) }
            try self.init(kind: kind, ipv4: address)
        }
    }

    /// What `Machine.hostname` holds for this address.
    public var hostname: String {
        switch value {
        case .ipv4(let address): address.description
        case .name(let name): name
        }
    }

    public var description: String {
        hostname
    }

    private static func isValidName(_ name: String, for kind: PairingAddressKind) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumNameLength else { return false }
        let labels = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard labels.allSatisfy(isValidLabel) else { return false }
        switch kind {
        case .localName:
            return labels.count == 2 && labels[1].elementsEqual("local".utf8)
        case .tailscaleMagicDNS:
            return labels.count >= 4 && labels[labels.count - 2].elementsEqual("ts".utf8) && labels[labels.count - 1].elementsEqual("net".utf8)
        case .privateIPv4, .tailscaleIPv4:
            return false
        }
    }

    /// `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?`
    private static func isValidLabel(_ label: ArraySlice<UInt8>) -> Bool {
        func isLetterOrDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
        guard let first = label.first, let last = label.last, label.count <= 63,
              isLetterOrDigit(first), isLetterOrDigit(last) else { return false }
        return label.allSatisfy { isLetterOrDigit($0) || $0 == UInt8(ascii: "-") }
    }
}

public nonisolated enum PairingAddressError: Error, Equatable, LocalizedError {
    /// The value isn't of the kind's shape, or is an address outside its range.
    case invalid(PairingAddressKind, String)

    public var errorDescription: String? {
        switch self {
        case .invalid(.localName, let value):
            String(localized: "“\(value)” isn't a .local name.", bundle: .shepherdKit)
        case .invalid(.privateIPv4, let value):
            String(localized: "“\(value)” isn't a private IPv4 address.", bundle: .shepherdKit)
        case .invalid(.tailscaleIPv4, let value):
            String(localized: "“\(value)” isn't a Tailscale IPv4 address.", bundle: .shepherdKit)
        case .invalid(.tailscaleMagicDNS, let value):
            String(localized: "“\(value)” isn't a Tailscale MagicDNS name.", bundle: .shepherdKit)
        }
    }
}
