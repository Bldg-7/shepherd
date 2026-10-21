#if os(macOS)
import Foundation
import SystemConfiguration

/// What this Mac's network looks like at one moment, as far as choosing the
/// address a pairing QR code carries goes (SHPHRD-77, "주소 selector"): its
/// interfaces with their kind, flags and addresses, the network services
/// that are active, in the order System Settings puts them, and the local
/// host name Bonjour answers to. Plain data, so that the choice made from it
/// (`PairingAddressOptions`) is a function the tests give made-up networks.
nonisolated struct NetworkSnapshot: Hashable, Sendable {
    /// What `SCNetworkInterfaceCopyAll` says an interface is.
    enum Hardware: Hashable, Sendable {
        case wifi
        case ethernet
        /// Anything else, and interfaces it doesn't list: VPN tunnels,
        /// bridges, virtual machines' networks.
        case other
    }

    struct Interface: Hashable, Sendable {
        /// The BSD name: `en0`, `utun4`.
        var name: String
        var hardware: Hardware
        var isUp: Bool
        var isRunning: Bool
        var isBroadcast: Bool
        var isPointToPoint: Bool
        /// In the order `getifaddrs` lists them.
        var ipv4: [PairingIPv4]
        /// Sixteen bytes each.
        var ipv6: [[UInt8]]

        init(name: String, hardware: Hardware = .other, isUp: Bool = true, isRunning: Bool = true, isBroadcast: Bool = false,
             isPointToPoint: Bool = false, ipv4: [PairingIPv4] = [], ipv6: [[UInt8]] = []) {
            self.name = name
            self.hardware = hardware
            self.isUp = isUp
            self.isRunning = isRunning
            self.isBroadcast = isBroadcast
            self.isPointToPoint = isPointToPoint
            self.ipv4 = ipv4
            self.ipv6 = ipv6
        }
    }

    /// A network service with IPv4 up: it has `State:/Network/Service/<id>/IPv4`.
    struct Service: Hashable, Sendable {
        var id: String
        /// What System Settings calls it: "Wi-Fi", "USB 10/100/1000 LAN".
        var name: String
        var interfaceName: String
    }

    var interfaces: [Interface]
    /// In the system's service order.
    var services: [Service]
    /// `SCDynamicStoreCopyLocalHostName`: the `<name>` of `<name>.local`.
    /// Nil when it isn't set.
    var localHostName: String?

    init(interfaces: [Interface] = [], services: [Service] = [], localHostName: String? = nil) {
        self.interfaces = interfaces
        self.services = services
        self.localHostName = localHostName
    }

    func interface(named name: String) -> Interface? {
        interfaces.first { $0.name == name }
    }
}

/// Reads `NetworkSnapshot` from the system: `getifaddrs` for flags and
/// addresses, `SCNetworkInterfaceCopyAll` for which interface is Wi-Fi or
/// Ethernet, and the dynamic store for the active services, their order and
/// names, and the local host name. Nothing is looked up on the network.
nonisolated enum NetworkSnapshotSource {
    static func current() -> NetworkSnapshot {
        let hardware = hardwareTypes()
        var interfaces: [NetworkSnapshot.Interface] = []
        for (name, found) in interfaceAddresses() {
            interfaces.append(NetworkSnapshot.Interface(
                name: name, hardware: hardware[name] ?? .other,
                isUp: found.flags & IFF_UP != 0, isRunning: found.flags & IFF_RUNNING != 0,
                isBroadcast: found.flags & IFF_BROADCAST != 0, isPointToPoint: found.flags & IFF_POINTOPOINT != 0,
                ipv4: found.ipv4, ipv6: found.ipv6))
        }
        guard let store = SCDynamicStoreCreate(nil, "hrdrhrdrhrdr pairing" as CFString, nil, nil) else {
            return NetworkSnapshot(interfaces: interfaces)
        }
        return NetworkSnapshot(interfaces: interfaces, services: activeServices(store),
                               localHostName: SCDynamicStoreCopyLocalHostName(store) as String?)
    }

    private struct Found {
        var flags: Int32 = 0
        var ipv4: [PairingIPv4] = []
        var ipv6: [[UInt8]] = []
    }

    /// Every interface `getifaddrs` lists, in its order.
    private static func interfaceAddresses() -> [(String, Found)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var order: [String] = []
        var found: [String: Found] = [:]
        var entry = list
        while let current = entry {
            entry = current.pointee.ifa_next
            let name = String(cString: current.pointee.ifa_name)
            if found[name] == nil { order.append(name) }
            var record = found[name] ?? Found()
            record.flags |= Int32(bitPattern: current.pointee.ifa_flags)
            if let address = current.pointee.ifa_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        PairingIPv4(value: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                    }
                    if !record.ipv4.contains(ipv4) { record.ipv4.append(ipv4) }
                case AF_INET6:
                    let ipv6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                    }
                    if !record.ipv6.contains(ipv6) { record.ipv6.append(ipv6) }
                default:
                    break
                }
            }
            found[name] = record
        }
        return order.map { ($0, found[$0]!) }
    }

    private static func hardwareTypes() -> [String: NetworkSnapshot.Hardware] {
        var types: [String: NetworkSnapshot.Hardware] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 as String {
                types[name] = .wifi
            } else if type == kSCNetworkInterfaceTypeEthernet as String {
                types[name] = .ethernet
            }
        }
        return types
    }

    private static func activeServices(_ store: SCDynamicStore) -> [NetworkSnapshot.Service] {
        let states = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/[^/]+/IPv4"] as CFArray) as? [String: Any] ?? [:]
        let order = (SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any])?["ServiceOrder"] as? [String] ?? []
        var services: [NetworkSnapshot.Service] = []
        for (key, value) in states {
            // State:/Network/Service/<id>/IPv4
            let parts = key.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 5, let state = value as? [String: Any], let interfaceName = state["InterfaceName"] as? String else { continue }
            let id = String(parts[3])
            let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(id)" as CFString) as? [String: Any]
            services.append(NetworkSnapshot.Service(id: id, name: setup?["UserDefinedName"] as? String ?? interfaceName,
                                                    interfaceName: interfaceName))
        }
        return services.sorted { left, right in
            let a = order.firstIndex(of: left.id) ?? Int.max, b = order.firstIndex(of: right.id) ?? Int.max
            return a != b ? a < b : left.id < right.id
        }
    }
}

/// Calls `onChange` half a second after the last of a run of changes to an
/// interface's addresses, the primary service, an active service or the
/// local host name, as the dynamic store reports them. `NWPathMonitor`
/// doesn't report address changes, so it isn't used. Started and stopped
/// with the pairing page.
@MainActor final class NetworkChangeWatcher {
    static let debounce: Duration = .milliseconds(500)
    static let keys = ["State:/Network/Global/IPv4", "Setup:/Network/HostNames"]
    static let patterns = ["State:/Network/Interface/[^/]+/IPv4", "State:/Network/Interface/[^/]+/IPv6",
                           "State:/Network/Service/[^/]+/IPv4"]

    private let onChange: @MainActor () -> Void
    private var store: SCDynamicStore?
    private var pending: Task<Void, Never>?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "hrdrhrdrhrdr pairing" as CFString, networkStoreChanged, &context) else { return }
        SCDynamicStoreSetNotificationKeys(store, Self.keys as CFArray, Self.patterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
        self.store = store
    }

    /// Before the watcher goes: the store holds it unretained.
    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        pending?.cancel()
        pending = nil
    }

    fileprivate func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}

/// The dynamic store's callback, on the main queue the store was given.
private nonisolated func networkStoreChanged(_ store: SCDynamicStore, _ keys: CFArray, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    MainActor.assumeIsolated {
        Unmanaged<NetworkChangeWatcher>.fromOpaque(info).takeUnretainedValue().changed()
    }
}
#endif
