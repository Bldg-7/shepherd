import Foundation
import Citadel
import NIOConcurrencyHelpers

// Authentication/validator seams only; the production reader is unchanged.
struct HostCredential {
    let authMethod: Machine.AuthMethod
    let secretData: Data
    nonisolated func authenticationMethod(username: String) throws -> OwnedAuth { .init() }
}
struct TOFUHostKeyValidator: OwnedValidator {
    let pinnedFingerprint: String?
    let observedFingerprint: NIOLockedValueBox<String?>
}
enum MachineStore { enum EditError: Error { case missingCredential } }

@main @MainActor enum RemoteReaderTests {
    static var checks = 0
    static func check(_ b: Bool) { precondition(b); checks += 1 }
    static func main() async throws {
        let fake = OwnedSFTP.shared
        var machine = Machine(displayName: "Owned Remote", hostname: "owned-host.invalid", port: 2222, username: "owned")
        machine.pinnedHostKeyFingerprint = "owned-pin-not-a-real-account"
        let secret = Data("synthetic-only".utf8)
        let path = "/remote/a';$(touch should-not-execute).md"
        await fake.plan(Array("# Owned remote".utf8))
        let reader = FilePreviewReader()
        let result = try await reader.read(path: path, machine: machine, secret: secret)
        check(result == Data("# Owned remote".utf8))
        let hosts = await fake.hosts; check(hosts == [machine.hostname])
        let pins = await fake.pins; check(pins == [machine.pinnedHostKeyFingerprint])
        let paths = await fake.paths; check(paths.allSatisfy { $0 == path })
        let lengths = await fake.lengths; check(!lengths.isEmpty && lengths.allSatisfy { $0 <= 65536 })
        let closes = await fake.closes; check(closes == 1)
        let fileCloses = await fake.fileCloses; check(fileCloses == 1)
        let sftpCloses = await fake.sftpCloses; check(sftpCloses == 1)
        await fake.plan()
        var unpinned = machine; unpinned.pinnedHostKeyFingerprint = nil
        do { _ = try await FilePreviewReader().read(path: path, machine: unpinned, secret: secret); preconditionFailure() } catch FilePreviewError.needsHostKey { checks += 1 }
        let deniedConnects = await fake.connects; check(deniedConnects == 0)
        do { _ = try await FilePreviewReader().read(path: path, machine: machine, secret: nil); preconditionFailure() } catch MachineStore.EditError.missingCredential { checks += 1 }
        let noSecretConnects = await fake.connects; check(noSecretConnects == 0)
        let modes: [UInt32?] = [nil, 0o040700, 0o010600, 0o020600]
        for mode in modes {
            await fake.plan(mode: mode)
            do { _ = try await FilePreviewReader().read(path: path, machine: machine, secret: secret); preconditionFailure() } catch FilePreviewError.notRegularFile { checks += 1 }
            let opens = await fake.opens; check(opens == 0)
            let closes = await fake.closes; check(closes == 1)
        }
        await fake.plan(size: UInt64(FilePreviewDocument.maximumBytes + 1))
        do { _ = try await FilePreviewReader().read(path: path, machine: machine, secret: secret); preconditionFailure() } catch FilePreviewError.tooLarge { checks += 1 }
        let largeOpens = await fake.opens; check(largeOpens == 0)
        await fake.plan([1], oversize: true)
        do { _ = try await FilePreviewReader().read(path: path, machine: machine, secret: secret); preconditionFailure() } catch FilePreviewError.tooLarge { checks += 1 }
        let oversizedCloses = await fake.closes; check(oversizedCloses == 1)
        await fake.plan([1,2,3], heldConnect: true)
        let lateReader = FilePreviewReader()
        let late = Task { try await lateReader.read(path: path, machine: machine, secret: secret) }
        while !(await fake.waitingConnect) { await Task.yield() }
        await lateReader.cancel()
        await fake.releaseConnect()
        do { _ = try await late.value; preconditionFailure() } catch is CancellationError { checks += 1 }
        let lateCloses = await fake.closes; check(lateCloses == 1)
        let lateOpens = await fake.opens; check(lateOpens == 0)
        await fake.plan([1,2,3], heldRead: true)
        let pendingReader = FilePreviewReader()
        let pending = Task { try await pendingReader.read(path: path, machine: machine, secret: secret) }
        while !(await fake.waitingRead) { await Task.yield() }
        await pendingReader.cancel()
        do { _ = try await pending.value; preconditionFailure() } catch is CancellationError { checks += 1 }
        let pendingCloses = await fake.closes; check(pendingCloses >= 1)
        print("PASS \(checks) production SFTP-reader checks with explicit in-memory SSH module; late acquisition compensated and blocked read closed; no sockets/real credentials")
    }
}
