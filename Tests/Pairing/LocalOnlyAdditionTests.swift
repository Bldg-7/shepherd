import Foundation

// Adding a device only while the window shows This Mac (SHPHRD-110), without
// the app or a window: the rule, on This Mac and on every other kind of
// machine.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

let deviceReason = "Connect to This Mac to add a device."

let thisMac = Machine(id: UUID(uuidString: "79763D9A-997B-4E75-A3FA-6EF5D0338479")!, displayName: "This Mac", hostname: "localhost",
                      port: 0, username: "minsu", isLocal: true)
let sshHost = Machine(displayName: "workbox", hostname: "workbox.example", username: "minsu")
let pairedMac = Machine(displayName: "Minsu’s MacBook Pro", hostname: "minsus-macbook-pro.local", username: "minsu",
                        authMethod: .secureEnclaveKey, addressKind: .localName)
/// An SSH machine named and set up like This Mac: only `isLocal` counts.
let lookalike = Machine(displayName: "This Mac", hostname: "localhost", port: 22, username: "minsu")

func ruleTests() {
    expect(LocalOnlyAddition.device.unavailableReason(on: thisMac) == nil, "a device on This Mac: allowed")
    for machine in [sshHost, pairedMac, lookalike] {
        expect(LocalOnlyAddition.device.unavailableReason(on: machine) == deviceReason, "a device on \(machine.displayName) (\(machine.hostname)): why not")
    }
    expect(LocalOnlyAddition.device.unavailableReason(on: nil) == deviceReason, "no machine shown: not allowed either")
}

@main
struct LocalOnlyAdditionTests {
    static func main() {
        ruleTests()
        print("\(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
