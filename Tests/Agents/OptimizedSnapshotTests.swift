import Foundation

/// The herdr machines' task group (`MachineMonitor.fetchSnapshots`) as a
/// release build has it: run-live-update-tests.py compiles this with -O and
/// -wmo and runs it with MallocScribble=1. Swift 6.3 and 6.4 drop the store
/// of `index` from a child that returns `(index, try await …, nil)` in a do
/// and `(index, nil, …)` in its catch (swiftlang/swift#92698, SHPHRD-54),
/// and only in an optimized build, so the -Onone MachineMonitorTests can't
/// see it. The receiving loop then reads whatever was in memory as the
/// index; with MallocScribble that is 0xaaaa…, out of bounds, which traps
/// on the first round, in that loop: a trap with no FAIL line before it.
/// Without MallocScribble the leftover value can be an index in bounds,
/// landing a result in another machine's place, which the checks here
/// catch.
///
/// Every round lists four machines, each answering after its own delay —
/// a different order each round — and one of them failing, and every
/// machine has to end up in its own place with its own panes or its own
/// error.
@main struct OptimizedSnapshotTests {
    static let rounds = 500
    static let machineIDs = ["alpha", "beta", "gamma", "delta"]

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        check(!_isDebugAssertConfiguration(), "built optimized (-O)")
        check(ProcessInfo.processInfo.environment["MallocScribble"] == "1", "run with MallocScribble=1")
        let start = ContinuousClock.now
        for round in 0..<rounds {
            await checkRound(round)
        }
        print("PASS: \(rounds) rounds over \(machineIDs.count) herdr machines, each in its own place (\(ContinuousClock.now - start))")
    }

    // An -O build doesn't print a precondition's message, so a failure
    // here says what it is and exits.
    static func check(_ value: Bool, _ name: String) {
        guard value else {
            print("FAIL: " + name)
            exit(1)
        }
        print("PASS: " + name)
    }

    static func checkRound(_ round: Int) async {
        let count = machineIDs.count
        let fake = FakeHerdr(herdrMachines: machineIDs)
        for (position, id) in machineIDs.enumerated() {
            // 0, 0.5, 1 and 1.5 ms, turned by one each round.
            await fake.setMachineDelay(id, .microseconds(((position + round) % count) * 500))
        }
        let failing = machineIDs[(round / count) % count]
        await fake.setMachineFailure(failing)
        let client = HerdrClient(transport: fake)
        let machines: [HerdrMachine]
        do {
            machines = try await client.listHerdrMachines()
        } catch {
            fail(round, "listing the machines failed: \(error)")
        }
        // Nothing from an earlier round, which a place left without its
        // result would otherwise go on showing.
        let groups = await MachineMonitor.fetchSnapshots(on: machines, previous: [], client: client)
        guard groups.map(\.id) == machineIDs else {
            fail(round, "machines \(groups.map(\.id)), not \(machineIDs)")
        }
        for (group, id) in zip(groups, machineIDs) {
            if id == failing {
                guard let error = group.error, error.contains("machine '\(id)'"), !group.hasLoaded, group.agents.isEmpty else {
                    fail(round, "\(id) (the failing one) has error \(group.error ?? "nil"), loaded \(group.hasLoaded), panes \(group.agents.map(\.terminalID))")
                }
            } else {
                guard group.error == nil, group.hasLoaded, group.agents.map(\.terminalID) == ["term-\(id)"] else {
                    fail(round, "\(id) has error \(group.error ?? "nil"), loaded \(group.hasLoaded), panes \(group.agents.map(\.terminalID))")
                }
            }
        }
    }

    static func fail(_ round: Int, _ message: String) -> Never {
        print("FAIL: round \(round): \(message)")
        exit(1)
    }
}
