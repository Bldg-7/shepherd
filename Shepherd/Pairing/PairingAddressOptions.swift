#if os(macOS)
import Foundation

/// One row of the address selector: an address of this Mac a device could
/// reach it at, of one kind.
nonisolated struct PairingAddressOption: Hashable, Sendable, Identifiable {
    /// A row's identity across network changes: its kind, and for a private
    /// IPv4 address, which has a row per interface, the interface.
    struct ID: Hashable, Sendable {
        let kind: PairingAddressKind
        let interfaceName: String?
    }

    let address: PairingAddress
    /// The network service a private IPv4 address is on: "Wi-Fi".
    let serviceName: String?
    let interfaceName: String?
    /// This Mac's addresses a device's connection for this row may arrive
    /// at: the address itself, or for a .local name, every address of the
    /// local networks it can be answered on.
    let localAddresses: [PairingIPv4]

    init(address: PairingAddress, serviceName: String? = nil, interfaceName: String? = nil, localAddresses: [PairingIPv4]) {
        self.address = address
        self.serviceName = serviceName
        self.interfaceName = interfaceName
        self.localAddresses = localAddresses
    }

    var kind: PairingAddressKind { address.kind }

    var id: ID {
        ID(kind: kind, interfaceName: kind == .privateIPv4 ? interfaceName : nil)
    }

    /// "Private IPv4 · Wi-Fi", or the kind's name.
    var title: String {
        if kind == .privateIPv4, let serviceName { return "\(kind.displayName) · \(serviceName)" }
        return kind.displayName
    }
}

/// From a `NetworkSnapshot` to the selector's rows and which one is chosen
/// (SHPHRD-77, "종류별 판정"). Only what can be used is listed; a kind
/// that can't is left out rather than shown disabled.
nonisolated enum PairingAddressOptions {
    /// Interfaces that are never a Wi-Fi or wired network a phone is on,
    /// whatever kind the system gives them: bridges (Internet Sharing,
    /// virtual machines), VPN tunnels, AWDL and low-latency WLAN, the
    /// Wi-Fi access point, and the rest.
    static let excludedInterfacePrefixes = ["bridge", "vmnet", "vnic", "utun", "ipsec", "ppp", "awdl", "llw", "anpi", "ap", "gif", "stf", "feth"]

    static func isExcluded(_ interfaceName: String) -> Bool {
        excludedInterfacePrefixes.contains { prefix in
            interfaceName.hasPrefix(prefix) && !interfaceName.dropFirst(prefix.count).isEmpty
                && interfaceName.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// The Wi-Fi and wired networks this Mac is on: interfaces of active
    /// services, of Wi-Fi or Ethernet kind, up, running, broadcast and not
    /// point-to-point, one per interface, in service order. A company VPN's
    /// tunnel with a 10.x address is none of these; neither is the default
    /// route's interface, which a full-tunnel VPN makes a tunnel.
    static func lanInterfaces(in snapshot: NetworkSnapshot) -> [(service: NetworkSnapshot.Service, interface: NetworkSnapshot.Interface)] {
        var seen: Set<String> = []
        var found: [(NetworkSnapshot.Service, NetworkSnapshot.Interface)] = []
        for service in snapshot.services where !seen.contains(service.interfaceName) {
            guard let interface = snapshot.interface(named: service.interfaceName),
                  interface.hardware == .wifi || interface.hardware == .ethernet,
                  interface.isUp, interface.isRunning, interface.isBroadcast, !interface.isPointToPoint,
                  !isExcluded(interface.name) else { continue }
            seen.insert(service.interfaceName)
            found.append((service, interface))
        }
        return found
    }

    /// Point-to-point `utun` interfaces with an address in Tailscale's node
    /// range — which NetBird, Cloudflare WARP and carrier NAT use too, so
    /// each is only a candidate until `isTailscale` confirms it.
    static func tailscaleCandidates(in snapshot: NetworkSnapshot) -> [(interface: NetworkSnapshot.Interface, address: PairingIPv4)] {
        snapshot.interfaces.compactMap { interface in
            guard interface.name.hasPrefix("utun"), interface.isUp, interface.isRunning, interface.isPointToPoint,
                  let address = interface.ipv4.first(where: PairingAddressRanges.isTailscale) else { return nil }
            return (interface, address)
        }
    }

    /// A candidate is Tailscale's when the same tunnel has an address in
    /// Tailscale's IPv6 prefix, fd7a:115c:a1e0::/48, or its address's
    /// reverse name is a `.ts.net` name.
    static func isTailscale(_ interface: NetworkSnapshot.Interface, address: PairingIPv4, lookup: TailscaleNameLookup.Result?) -> Bool {
        interface.ipv6.contains { PairingAddressRanges.isTailscaleULA($0) } || lookup?.confirmsTailscale == true
    }

    /// The rows, in the order the selector shows them: the .local name,
    /// private IPv4 addresses by interface in service order, the Tailscale
    /// IPv4 address and the MagicDNS name. `tailscaleNames` holds what
    /// `TailscaleNameLookup` found for the candidates' addresses.
    static func options(snapshot: NetworkSnapshot, tailscaleNames: [PairingIPv4: TailscaleNameLookup.Result]) -> [PairingAddressOption] {
        var options: [PairingAddressOption] = []
        let lan = lanInterfaces(in: snapshot)

        let lanAddresses = lan.flatMap { $0.interface.ipv4.filter(PairingAddressRanges.isLAN) }
        if let hostName = snapshot.localHostName, !lanAddresses.isEmpty,
           let address = try? PairingAddress(kind: .localName, name: hostName.lowercased() + ".local") {
            options.append(PairingAddressOption(address: address, localAddresses: lanAddresses))
        }

        for (service, interface) in lan {
            guard let ipv4 = interface.ipv4.first(where: PairingAddressRanges.isPrivate),
                  let address = try? PairingAddress(kind: .privateIPv4, ipv4: ipv4) else { continue }
            options.append(PairingAddressOption(address: address, serviceName: service.name, interfaceName: interface.name,
                                                localAddresses: [ipv4]))
        }

        if let (interface, ipv4) = tailscaleCandidates(in: snapshot).first(where: { isTailscale($0.interface, address: $0.address,
                                                                                                    lookup: tailscaleNames[$0.address]) }),
           let address = try? PairingAddress(kind: .tailscaleIPv4, ipv4: ipv4) {
            options.append(PairingAddressOption(address: address, interfaceName: interface.name, localAddresses: [ipv4]))
            if let name = tailscaleNames[ipv4]?.magicDNSAddress {
                options.append(PairingAddressOption(address: name, interfaceName: interface.name, localAddresses: [ipv4]))
            }
        }
        return options
    }

    /// The row chosen when the page opens: the first of the kind picked last
    /// time, if there is one; otherwise the first in the order MagicDNS,
    /// Tailscale IPv4, .local name, private IPv4.
    static func defaultOption(in options: [PairingAddressOption], lastKind: PairingAddressKind?) -> PairingAddressOption? {
        if let lastKind, let option = options.first(where: { $0.kind == lastKind }) { return option }
        for kind in PairingAddressKind.preferenceOrder {
            if let option = options.first(where: { $0.kind == kind }) { return option }
        }
        return nil
    }

    /// What became of the chosen row when the network changed.
    enum Reselection: Equatable, Sendable {
        /// The same row with the same address. A .local name's row may come
        /// back with other local addresses, which the listener's filter
        /// takes; the code stays as it is.
        case unchanged(PairingAddressOption)
        /// The same kind, at another address: another interface's private
        /// address, or the same row's new one.
        case changed(PairingAddressOption)
        /// The kind can't be used anymore; the first usable kind in the
        /// default order is chosen instead.
        case replaced(lost: PairingAddressKind, by: PairingAddressOption)
        /// Nothing can be used.
        case none(lost: PairingAddressKind)
    }

    static func reselect(_ previous: PairingAddressOption, in options: [PairingAddressOption]) -> Reselection {
        if let same = options.first(where: { $0.id == previous.id }) {
            return same.address == previous.address ? .unchanged(same) : .changed(same)
        }
        if let sameKind = options.first(where: { $0.kind == previous.kind }) {
            return .changed(sameKind)
        }
        if let fallback = defaultOption(in: options, lastKind: nil) {
            return .replaced(lost: previous.kind, by: fallback)
        }
        return .none(lost: previous.kind)
    }
}
#endif
