#if os(macOS)
import Foundation

/// Looks this Mac's Tailscale address up both ways. The system's lookups in
/// the app; a stand-in in tests, which never look anything up.
nonisolated protocol TailscaleNameResolving: Sendable {
    /// The name a reverse (PTR) lookup of `address` gives, or nil when it
    /// has none.
    func reverseName(of address: PairingIPv4) async throws -> String?
    /// The name's IPv4 addresses.
    func ipv4Addresses(for name: String) async throws -> [PairingIPv4]
}

/// `getnameinfo` with `NI_NAMEREQD` and `getaddrinfo`, off the caller's
/// thread. With MagicDNS on, tailscaled sends the reverse zone of 100.64/10
/// to its own resolver, 100.100.100.100, which answers for the tailnet's
/// nodes — the same in the App Store, standalone and Homebrew builds, with
/// no other process run and nothing of Tailscale's read.
nonisolated struct SystemTailscaleNameResolver: TailscaleNameResolving {
    func reverseName(of address: PairingIPv4) async throws -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.reverseLookup(address))
            }
        }
    }

    func ipv4Addresses(for name: String) async throws -> [PairingIPv4] {
        try await SystemPairingNameResolver().ipv4Addresses(for: name)
    }

    private static func reverseLookup(_ address: PairingIPv4) -> String? {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_addr.s_addr = address.value.bigEndian
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        return String(cString: host)
    }
}

/// Whether a Tailscale address of this Mac has a MagicDNS name (SHPHRD-77,
/// "Tailscale MagicDNS"): its reverse name ends in `.ts.net`, and that name
/// leads back to the same address. A `.ts.net` reverse name alone is enough
/// to tell that a 100.64/10 address is Tailscale's and not another VPN's or
/// a carrier's.
nonisolated enum TailscaleNameLookup {
    enum Result: Hashable, Sendable {
        /// A MagicDNS name that leads back to the address.
        case magicDNS(PairingAddress)
        /// A `.ts.net` name that doesn't lead back to the address, or isn't
        /// a name a device could be given.
        case tailscaleNameOnly
        /// A name of something else.
        case otherName
        /// No reverse name at all: MagicDNS is off, or this isn't Tailscale.
        case noName
        case timedOut

        /// Whether the address is Tailscale's.
        var confirmsTailscale: Bool {
            switch self {
            case .magicDNS, .tailscaleNameOnly: true
            case .otherName, .noName, .timedOut: false
            }
        }

        var magicDNSAddress: PairingAddress? {
            if case .magicDNS(let address) = self { return address }
            return nil
        }
    }

    /// For each way: tailscaled answers in milliseconds, and a lookup that
    /// goes to some other DNS server for a name it doesn't have shouldn't
    /// hold the page up.
    static let timeout: Duration = .seconds(3)

    static func lookUp(_ address: PairingIPv4, resolver: any TailscaleNameResolving, timeout: Duration = timeout) async -> Result {
        let reverse: String?
        do {
            reverse = try await PairingDeadline.run(timeout) { try await resolver.reverseName(of: address) }
        } catch is PairingDeadline.Expired {
            return .timedOut
        } catch {
            return .noName
        }
        guard var name = reverse?.lowercased(), !name.isEmpty else { return .noName }
        if name.hasSuffix(".") { name.removeLast() }
        guard name.hasSuffix(".ts.net") else { return .otherName }
        guard let magicDNS = try? PairingAddress(kind: .tailscaleMagicDNS, name: name) else { return .tailscaleNameOnly }
        let forward: [PairingIPv4]
        do {
            let lookedUp = name
            forward = try await PairingDeadline.run(timeout) { try await resolver.ipv4Addresses(for: lookedUp) }
        } catch {
            return .tailscaleNameOnly
        }
        return forward.contains(address) ? .magicDNS(magicDNS) : .tailscaleNameOnly
    }
}

/// Runs `operation` for at most `timeout`, then gives up on it; an
/// operation that can't be stopped — a lookup blocked in the system — is
/// left to finish on its own, unwaited for.
nonisolated enum PairingDeadline {
    struct Expired: Error {}

    static func run<Value: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let outcome = FirstOutcome<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                outcome.wait(with: continuation)
                let timer = Task.detached {
                    try? await Task.sleep(for: timeout)
                    outcome.finish(.failure(Expired()))
                }
                Task.detached {
                    do {
                        outcome.finish(.success(try await operation()))
                    } catch {
                        outcome.finish(.failure(error))
                    }
                    timer.cancel()
                }
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }
}

/// Whichever result comes first.
private nonisolated final class FirstOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var early: Result<Value, any Error>?
    private var isFinished = false

    func wait(with continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { early = result }
        lock.unlock()
        waiting?.resume(with: result)
    }
}
#endif
