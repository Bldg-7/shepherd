import Foundation
import Darwin
import Citadel
import NIOConcurrencyHelpers

// Authentication/validator seams only; the production uploader is unchanged.
struct HostCredential: Sendable {
    nonisolated func authenticationMethod(username: String) throws -> OwnedAuth { .init() }
}
struct TOFUHostKeyValidator: OwnedValidator {
    let pinnedFingerprint: String?
    let observedFingerprint: NIOLockedValueBox<String?>
}

// The actual RemoteExecDropUploader against the in-memory Citadel module: B
// (the host's own herdr) and D (a herdr machine, through the host's fake ssh).
@main @MainActor enum RemoteExecTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: String) { precondition(condition, why); checks += 1 }
    static func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }
    static var work = ""

    static func file(_ name: String, _ bytes: Data, as remoteName: String) throws -> TerminalDropFile {
        let path = "\(work)/\(name)"
        try bytes.write(to: URL(fileURLWithPath: path))
        return try TerminalDropFile.open(URL(fileURLWithPath: path), remoteName: remoteName)
    }

    static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        work = CommandLine.arguments[1]
        let bin = CommandLine.arguments[2]
        let hostHome = "\(work)/host-home", machineHome = "\(work)/machine-home"
        try FileManager.default.createDirectory(atPath: hostHome, withIntermediateDirectories: true)
        let fake = FakeSSH.shared
        await fake.configure(hostHome: hostHome, path: "\(bin):/usr/bin:/bin")

        // B: one connection for the drop, one exec per file.
        let pin = "SHA256:owned-pin-not-a-real-host"
        let host = RemoteExecDropUploader(host: "owned-host.invalid", port: 2222, username: "owned", credential: HostCredential(), pinnedFingerprint: pin)
        let batch = UUID().uuidString.lowercased()
        let big = Data((0..<200_000).map { UInt8(($0 * 31) % 256) })
        let progress = Meter()
        let first = try await host.upload(try file("one.png", big, as: "one.png"), batch: batch, progress: { progress.record($0) })
        let second = try await host.upload(try file("two.png", Data([5, 6]), as: "two.png"), batch: batch, progress: { _ in })
        check(first == "\(hostHome)/.cache/3rdr/drops/\(batch)/one.png" && second == "\(hostHome)/.cache/3rdr/drops/\(batch)/two.png", "\(first) \(second)")
        check(FileManager.default.contents(atPath: first) == big && FileManager.default.contents(atPath: second) == Data([5, 6]), "every byte")
        check(progress.values.last == Int64(big.count) && progress.values == progress.values.sorted(), "progress rises to the size")
        let writes = await fake.writes
        check(writes.allSatisfy { $0 <= RemoteExecDropUploader.chunkSize } && writes.reduce(0, +) == big.count + 2, "32 KiB writes, nothing else")
        let connects = await fake.connects, hosts = await fake.hosts, pins = await fake.pins
        check(connects == 1 && hosts == ["owned-host.invalid"] && pins == [pin], "one connection, to the pinned host key")
        let commands = await fake.commands
        check(commands.count == 2 && commands.allSatisfy { $0.hasPrefix("sh -c '") }, "the receive script, run on the host")
        await host.close()
        let closes = await fake.closes
        check(closes == 1, "closed once")

        // 72: a name already there; the connection carries on.
        let again = RemoteExecDropUploader(host: "owned-host.invalid", port: 2222, username: "owned", credential: HostCredential(), pinnedFingerprint: pin)
        do { _ = try await again.upload(try file("dup.png", Data([1]), as: "one.png"), batch: batch, progress: { _ in }); check(false, "a duplicate must fail") }
        catch let error as TerminalDropError { check(error == .failed(status: 72, detail: "") && error.concernsOnlyThisFile, "\(error)") }
        check(FileManager.default.contents(atPath: first) == big, "the file there is left alone")
        let third = try await again.upload(try file("three.png", Data([3]), as: "three.png"), batch: batch, progress: { _ in })
        check(third.hasSuffix("/\(batch)/three.png"), "the next file still goes")

        // Startup-file noise around the receipt.
        await fake.set(override: nil, prefix: "echo 'Welcome'; echo 'SHEPHERD_DROP_OK /not/this'; echo 'motd' >&2; ")
        let noisy = try await again.upload(try file("noisy.png", Data([8]), as: "noisy.png"), batch: batch, progress: { _ in })
        check(noisy == "\(hostHome)/.cache/3rdr/drops/\(batch)/noisy.png", "the receive script's own line counts")

        // A command that ends well but says nothing.
        await fake.set(override: "cat >/dev/null")
        do { _ = try await again.upload(try file("quiet.png", Data([8]), as: "quiet.png"), batch: batch, progress: { _ in }); check(false, "unconfirmed must fail") }
        catch let error as TerminalDropError { check(error == .unconfirmed, "\(error)") }
        await fake.set(override: nil)
        await again.close()

        // D: through the host's ssh to a herdr machine; nothing stays on the host.
        let machine = HerdrMachine(id: "m1", label: "GPU", target: "gpu'$(touch INJECTED-d)", session: "default", enabled: true)
        let viaHost = RemoteExecDropUploader(host: "owned-host.invalid", port: 2222, username: "owned", credential: HostCredential(), pinnedFingerprint: pin, on: machine)
        let machineBatch = UUID().uuidString.lowercased()
        let d = try await viaHost.upload(try file("d.png", big, as: "d.png"), batch: machineBatch, progress: { _ in })
        check(d == "\(machineHome)/.cache/3rdr/drops/\(machineBatch)/d.png" && FileManager.default.contents(atPath: d) == big, "on the machine: \(d)")
        check(!exists("\(hostHome)/.cache/3rdr/drops/\(machineBatch)"), "nothing on the host")
        let last = (await fake.commands).last ?? ""
        check(last.hasPrefix("'ssh' '-T' '-o' 'BatchMode=yes'") && last.contains("'--' 'gpu'\\''$(touch INJECTED-d)'"), "the host's ssh, target after --: \(last)")
        check((try String(contentsOfFile: "\(bin)/ssh-targets.log", encoding: .utf8)).split(separator: "\n").last.map(String.init) == machine.target, "target as one argument")

        // ssh on the host can't reach the machine.
        FileManager.default.createFile(atPath: "\(bin)/unreachable", contents: nil)
        do { _ = try await viaHost.upload(try file("u.png", Data([1]), as: "u.png"), batch: machineBatch, progress: { _ in }); check(false, "must fail") }
        catch let error as TerminalDropError {
            check(error == .failed(status: 255, detail: "ssh: connect to host \(machine.target) port 22: Connection refused") && !error.concernsOnlyThisFile, "\(error)")
        }
        try FileManager.default.removeItem(atPath: "\(bin)/unreachable")
        await viaHost.close()

        // A target that would be an option never gets a channel.
        let execs = (await fake.commands).count
        let optionLike = RemoteExecDropUploader(host: "owned-host.invalid", port: 2222, username: "owned", credential: HostCredential(), pinnedFingerprint: pin,
                                                on: HerdrMachine(id: "m2", label: "x", target: "-oProxyCommand=touch INJECTED-o", session: "default", enabled: true))
        do { _ = try await optionLike.upload(try file("o.png", Data([1]), as: "o.png"), batch: machineBatch, progress: { _ in }); check(false, "must fail") }
        catch let error as TerminalDropError { check(error == .unusableTarget, "\(error)") }
        let execsAfter = (await fake.commands).count
        check(execsAfter == execs, "nothing run")

        // Cancelled mid-file: the connection is closed under the waiting write,
        // the far end reads a short file and removes it, and its batch.
        await fake.set(override: nil, holdAfter: 64 * 1024)
        let cancelled = RemoteExecDropUploader(host: "owned-host.invalid", port: 2222, username: "owned", credential: HostCredential(), pinnedFingerprint: pin)
        let cancelBatch = UUID().uuidString.lowercased()
        let large = try file("large.png", Data(count: 1_000_000), as: "large.png")
        let task = Task { try await cancelled.upload(large, batch: cancelBatch, progress: { _ in }) }
        let started = ContinuousClock.now
        while !(await fake.waitingWrite) {
            try await Task.sleep(for: .milliseconds(10))
            precondition(ContinuousClock.now - started < .seconds(10), "the write never waited")
        }
        let closesBefore = await fake.closes
        task.cancel()
        do { _ = try await task.value; check(false, "a cancelled upload must not succeed") } catch { checks += 1 }
        let closesAfter = await fake.closes
        check(closesAfter == closesBefore + 1, "cancelling closed the connection")
        check(!exists("\(hostHome)/.cache/3rdr/drops/\(cancelBatch)"), "the far end removed the short file and its batch")
        do { _ = try await cancelled.upload(try file("after.png", Data([1]), as: "after.png"), batch: cancelBatch, progress: { _ in }); check(false, "closed stays closed") }
        catch is CancellationError { checks += 1 }
        await fake.set(override: nil)

        // A connect that fails is the caller's to describe; nothing is run.
        await fake.set(override: nil, refuseConnect: true)
        let refused = RemoteExecDropUploader(host: "owned-host.invalid", port: 2222, username: "owned", credential: HostCredential(), pinnedFingerprint: pin)
        let before = (await fake.commands).count
        do { _ = try await refused.upload(try file("r.png", Data([1]), as: "r.png"), batch: batch, progress: { _ in }); check(false, "must fail") }
        catch FakeChannelError.connectRefused { checks += 1 }
        let after = (await fake.commands).count
        check(after == before, "no exec without a connection")

        let injected = (FileManager.default.enumerator(atPath: work)?.allObjects as? [String] ?? []).filter { $0.contains("INJECTED") }
        check(injected.isEmpty, "no argument ran as code: \(injected)")
        print("remote exec checks: \(checks)")
    }

    nonisolated final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Int64] = []
        func record(_ sent: Int64) { lock.withLock { recorded.append(sent) } }
        var values: [Int64] { lock.withLock { recorded } }
    }
}
