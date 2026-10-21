import Foundation

/// Looks a name up to IPv4 addresses. The system's lookup in the app; a
/// stand-in in tests, which never look a real name up.
public nonisolated protocol PairingNameResolving: Sendable {
    /// The name's IPv4 addresses, in the order the lookup gave them. Throws,
    /// or returns none, when the name doesn't resolve.
    func ipv4Addresses(for name: String) async throws -> [PairingIPv4]
}

/// `getaddrinfo` for IPv4 only, run off the caller's thread since it blocks.
/// A .local name goes to multicast DNS and a .ts.net name to whatever DNS the
/// device has, Tailscale's own when its VPN is on.
public nonisolated struct SystemPairingNameResolver: PairingNameResolving {
    public init() {}

    public func ipv4Addresses(for name: String) async throws -> [PairingIPv4] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.lookUp(name) })
            }
        }
    }

    private struct LookupFailed: Error {
        let status: Int32
    }

    private static func lookUp(_ name: String) throws -> [PairingIPv4] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(name, nil, &hints, &list)
        guard status == 0 else { throw LookupFailed(status: status) }
        defer { freeaddrinfo(list) }
        var addresses: [PairingIPv4] = []
        var entry = list
        while let current = entry {
            if current.pointee.ai_family == AF_INET, let socketAddress = current.pointee.ai_addr {
                let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    PairingIPv4(value: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                }
                if !addresses.contains(address) { addresses.append(address) }
            }
            entry = current.pointee.ai_next
        }
        return addresses
    }
}

/// Turns a paired Mac's address into the one IPv4 address to connect to
/// (SHPHRD-77, "기기 쪽 검증"): an address as it is, a name looked up once,
/// keeping only what is in the kind's range — a .local name only to a
/// private or link-local address, a MagicDNS name only to a Tailscale node.
/// A .local name on a network with Active Directory can come back from
/// unicast DNS as any address, and a `*.ts.net` name with Funnel turned on
/// comes back as a public address when Tailscale is off; neither is
/// connected to. The caller connects to the returned address, not the name,
/// so the name can't resolve differently in between.
public nonisolated struct PairingAddressResolver: Sendable {
    public var resolver: any PairingNameResolving
    /// How long a lookup is waited for. A lookup that goes on after this is
    /// left to finish on its own.
    public var timeout: Duration

    public init(resolver: any PairingNameResolving = SystemPairingNameResolver(), timeout: Duration = .seconds(10)) {
        self.resolver = resolver
        self.timeout = timeout
    }

    public func resolve(_ address: PairingAddress) async throws -> PairingIPv4 {
        switch address.value {
        case .ipv4(let ipv4):
            // `PairingAddress` already held it to the kind's range.
            return ipv4
        case .name(let name):
            let found = try await lookUp(name)
            guard let usable = found.first(where: address.kind.allows) else {
                throw PairingAddressResolutionError.noAddressInRange(address.kind, name: name, found: found)
            }
            return usable
        }
    }

    /// For a saved machine: `hostname` checked against `kind` first, then
    /// resolved as above.
    public func resolve(hostname: String, kind: PairingAddressKind) async throws -> PairingIPv4 {
        try await resolve(PairingAddress(kind: kind, hostname: hostname))
    }

    private func lookUp(_ name: String) async throws -> [PairingIPv4] {
        let resolver = resolver
        let timeout = timeout
        let outcome = LookupOutcome()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[PairingIPv4], any Error>) in
                outcome.wait(with: continuation)
                let timer = Task.detached {
                    try? await Task.sleep(for: timeout)
                    outcome.finish(.failure(PairingAddressResolutionError.timedOut(name)))
                }
                Task.detached {
                    do {
                        let addresses = try await resolver.ipv4Addresses(for: name)
                        outcome.finish(addresses.isEmpty ? .failure(PairingAddressResolutionError.notFound(name)) : .success(addresses))
                    } catch is CancellationError {
                        outcome.finish(.failure(CancellationError()))
                    } catch {
                        outcome.finish(.failure(PairingAddressResolutionError.notFound(name)))
                    }
                    timer.cancel()
                }
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }
}

/// Whichever of the lookup, the timeout and cancellation comes first.
private nonisolated final class LookupOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[PairingIPv4], any Error>?
    private var early: Result<[PairingIPv4], any Error>?
    private var isFinished = false

    func wait(with continuation: CheckedContinuation<[PairingIPv4], any Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// True for the first result, which is the one passed on.
    @discardableResult
    func finish(_ result: Result<[PairingIPv4], any Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { early = result }
        lock.unlock()
        waiting?.resume(with: result)
        return true
    }
}

public nonisolated enum PairingAddressResolutionError: Error, LocalizedError {
    case notFound(String)
    case timedOut(String)
    /// The name resolved, but to no address the kind may connect to.
    case noAddressInRange(PairingAddressKind, name: String, found: [PairingIPv4])

    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            String(localized: "Couldn't find \(name): the name doesn't resolve.", bundle: .shepherdKit)
        case .timedOut(let name):
            String(localized: "Looking up \(name) took too long.", bundle: .shepherdKit)
        case .noAddressInRange(.tailscaleMagicDNS, let name, _):
            String(localized: "\(name) didn't resolve to a Tailscale address, so Shepherd didn't connect. Check that Tailscale is connected on this device and that Use Tailscale DNS is turned on.", bundle: .shepherdKit)
        case .noAddressInRange(_, let name, _):
            String(localized: "\(name) didn't resolve to an address on the local network, so Shepherd didn't connect.", bundle: .shepherdKit)
        }
    }
}

/// A paired Mac's connection that was stopped for what answered it.
public nonisolated enum PairedConnectionError: Error, Equatable, LocalizedError {
    /// The SSH server at a .local name or private IPv4 address presented a
    /// host key other than the pinned one: on a local network that is most
    /// likely another device that got the Mac's old address. The connection
    /// was refused before the device's key was used.
    case anotherDeviceAnswered(address: String)
    /// The paired Mac turned the device's key down: someone removed the
    /// device on the Mac, or took its line out of `authorized_keys`
    /// (SHPHRD-77, "화면 흐름"). Asking again won't change that.
    case accessRemoved

    public var errorDescription: String? {
        switch self {
        case .anotherDeviceAnswered(let address):
            String(localized: "A different device answered at \(address). If the Mac's address has changed, scan its QR code again.", bundle: .shepherdKit)
        case .accessRemoved:
            String(localized: "This Mac removed this device's access. To connect again, remove the Mac from Machines, then scan a new QR code on the Mac.", bundle: .shepherdKit)
        }
    }
}
