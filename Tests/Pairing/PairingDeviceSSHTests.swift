import Darwin
import Foundation

// The app's first connection to a paired Mac (SSHPairedMacChecker), built
// against the Citadel and swift-nio-ssh an app build made, without
// connecting anywhere: the address the pairing resolved is held to the
// machine's kind before SSH starts, so one out of range ends the check with
// nothing sent — a listener on 127.0.0.1 counts connections that must not
// come. And PairingDeadline, which bounds it. Run in a sandbox that reaches
// only loopback.

@main enum PairingDeviceSSHTests {
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var failures = 0

    static func check(_ value: Bool, _ message: String) {
        count += 1
        if !value {
            failures += 1
            print("FAIL \(message)")
        }
    }

    static func main() async {
        guard let tripwire = Tripwire() else {
            print("FAIL a listener on 127.0.0.1")
            exit(1)
        }
        let key = SecureEnclaveSSHKey.makeSoftware()
        let loopback = PairingIPv4(127, 0, 0, 1)
        for (kind, name) in [(Machine.AddressKind.tailscaleMagicDNS, "minsus-mbp.tail1234.ts.net"), (.localName, "minsus-macbook-pro.local")] {
            var machine = Machine(displayName: "Studio", hostname: name, port: Int(tripwire.port), username: "minsu",
                                  authMethod: .secureEnclaveKey, addressKind: kind)
            machine.pinnedHostKeyFingerprint = "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString()
            let result = await SSHPairedMacChecker().check(machine, credential: key.storedRepresentation, at: loopback)
            let expected = PairingAddressResolutionError.noAddressInRange(kind, name: name, found: [loopback]).errorDescription
            check(!result.sshConnected && !result.herdrReached && !result.keyRefused && result.failure == expected,
                  "\(kind): an address outside the kind's range ends the check before SSH (\(result.failure ?? "-"))")
        }
        try? await Task.sleep(for: .milliseconds(300))
        check(tripwire.accepted == 0, "nothing was connected to")

        do {
            try await PairingDeadline.run(.milliseconds(100)) { try await Task.sleep(for: .seconds(5)) }
            check(false, "a deadline that runs out throws")
        } catch {
            check(error is PairingDeadline.Missed, "a deadline that runs out: Missed")
        }
        let start = ContinuousClock.now
        let stubborn = try? await PairingDeadline.run(.milliseconds(100)) {
            // Work that doesn't stop when cancelled.
            let end = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < end { usleep(10_000) }
            return 1
        }
        check(stubborn == nil && ContinuousClock.now - start < .seconds(1), "work that ignores cancellation isn't waited for")
        let value = try? await PairingDeadline.run(.seconds(5)) { 42 }
        check(value == 42, "work in time: its value")
        check(connectionFailureDescription(PairedConnectionError.accessRemoved) == PairedConnectionError.accessRemoved.errorDescription,
              "a paired Mac that removed the device: said in so many words")

        if failures > 0 {
            print("FAILED \(failures) of \(count) checks")
            exit(1)
        }
        print("PASS \(count) device SSH checks: addresses held to their kind before SSH, deadlines")
        exit(0)
    }
}

/// A listener on 127.0.0.1 that counts the connections it takes.
nonisolated final class Tripwire: @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var taken = 0

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                lock.withLock { taken += 1 }
                close(connection)
            }
        }
    }

    var accepted: Int { lock.withLock { taken } }
}
