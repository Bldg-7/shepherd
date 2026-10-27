import Foundation
import Darwin

@main
struct PersistenceFilesTests {
    private static var failures = 0

    static func main() {
        if CommandLine.arguments.count == 3 {
            let action = CommandLine.arguments[1]
            let root = CommandLine.arguments[2]
            do {
                _ = try ConversationPersistenceFiles(verifiedStateRootPath: root)
                exit(action == "--acquire-child" ? 0 : 10)
            } catch ConversationPersistenceFilesError.lockUnavailable {
                exit(action == "--lock-child" ? 0 : 11)
            } catch {
                exit(12)
            }
        }
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: PersistenceFilesTests <owned-work-directory>\n".utf8))
            exit(64)
        }
        do {
            try run(work: CommandLine.arguments[1])
            if failures == 0 {
                print("PASS: conversation persistence filesystem foundation")
                exit(0)
            }
        } catch {
            print("FAIL setup: \(error)")
        }
        exit(1)
    }

    private static func run(work: String) throws {
        // 077 is intentionally restrictive: production creation must still
        // verify owner-only modes rather than assume a caller's umask.
        let originalUmask = umask(0o077)
        defer { _ = umask(originalUmask) }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(work, &resolved) != nil else { throw POSIXFailure("realpath owned work directory") }
        let work = String(cString: resolved)
        guard mode(work) == 0o700 else { throw POSIXFailure("owned work directory mode") }

        let valid = try root("valid", under: work)
        let initialSyncs = EventLog()
        var holder: ConversationPersistenceFiles? = try ConversationPersistenceFiles(
            verifiedStateRootPath: valid,
            testControl: .init(event: { event in
                if case let .beforeDirectoryParentSync(directory) = event { initialSyncs.directories.append(directory) }
            }))
        check(initialSyncs.directories == [.conversations, .records],
              "new verified Conversations and records links each sync their parent")
        check(mode(valid) == 0o700, "verified state root remains private")
        check(mode(valid + "/Conversations") == 0o700 && mode(valid + "/Conversations/records") == 0o700,
              "created storage directories are explicitly 0700")
        check(mode(valid + "/Conversations/lock") == 0o600, "created lock is explicitly 0600")
        try holder!.writeIndex(Data("first".utf8))
        let generation = try holder!.writeRecord(Data("record".utf8))
        let initialIndex = try holder!.readIndex()
        let initialRecord = try holder!.readRecord(generation)
        check(initialIndex == Data("first".utf8) && initialRecord == Data("record".utf8),
              "bounded index and opaque record writes round trip")
        check(mode(valid + "/Conversations/index-v1.json") == 0o600,
              "atomic output is explicitly 0600 independent of the fixture umask")
        try runChild("--lock-child", root: valid, expected: 0)
        holder = nil

        let priorUmask = umask(0o022)
        let umask022Root = try root("umask-022", under: work)
        let umask022Writer = try ConversationPersistenceFiles(verifiedStateRootPath: umask022Root)
        _ = umask(priorUmask)
        try umask022Writer.writeIndex(Data("umask-022".utf8))
        check(mode(umask022Root + "/Conversations") == 0o700 &&
              mode(umask022Root + "/Conversations/records") == 0o700 &&
              mode(umask022Root + "/Conversations/index-v1.json") == 0o600,
              "0700/0600 creation is explicitly verified under 022 and 077 umasks")

        let existingSyncs = EventLog()
        holder = try ConversationPersistenceFiles(
            verifiedStateRootPath: valid,
            testControl: .init(event: { event in
                if case let .beforeDirectoryParentSync(directory) = event { existingSyncs.directories.append(directory) }
            }))
        check(existingSyncs.directories == [.conversations, .records],
              "already-existing verified child links are conservatively parent-synced on init")

        let replacementLock = valid + "/Conversations/lock"
        guard unlink(replacementLock) == 0 else { throw POSIXFailure("unlink held lock fixture") }
        try writePrivateFile(replacementLock, Data())
        try runChild("--acquire-child", root: valid, expected: 0)
        try expect(.unsafeObject, "held lease detects replaced lock") { try holder!.writeIndex(Data("blocked".utf8)) }
        holder = nil

        let renamedParent = try root("renamed-parent", under: work)
        let originalRoot = renamedParent + "/original"
        try makeDirectory(originalRoot, mode: 0o700)
        let retained = try ConversationPersistenceFiles(verifiedStateRootPath: originalRoot)
        let renamedRoot = renamedParent + "/moved"
        guard rename(originalRoot, renamedRoot) == 0 else { throw POSIXFailure("rename root ancestor fixture") }
        try retained.writeIndex(Data("retained-capability".utf8))
        check(readFile(renamedRoot + "/Conversations/index-v1.json") == Data("retained-capability".utf8),
              "root ancestor rename retains original verified FD capability")

        let syncFailure = try root("sync-failure", under: work)
        let failedSyncs = EventLog()
        try expect(.ioFailure, "directory parent sync failure prevents init") {
            _ = try ConversationPersistenceFiles(
                verifiedStateRootPath: syncFailure,
                testControl: .init(fault: .directoryParentSync(.conversations), event: { event in
                    if case let .beforeDirectoryParentSync(directory) = event { failedSyncs.directories.append(directory) }
                }))
        }
        check(failedSyncs.directories == [.conversations] && directoryExists(syncFailure + "/Conversations"),
              "failed initial sync leaves owned link for safe retry without removal")
        let recoverySyncs = EventLog()
        _ = try ConversationPersistenceFiles(
            verifiedStateRootPath: syncFailure,
            testControl: .init(event: { event in
                if case let .beforeDirectoryParentSync(directory) = event { recoverySyncs.directories.append(directory) }
            }))
        check(recoverySyncs.directories == [.conversations, .records],
              "recovery revalidates and syncs remaining owned links")

        let atomic = try root("atomic", under: work)
        do {
            let writer = try ConversationPersistenceFiles(verifiedStateRootPath: atomic)
            try writer.writeIndex(Data("old".utf8))
        }
        do {
            let writer = try ConversationPersistenceFiles(
                verifiedStateRootPath: atomic, testControl: .init(fault: .beforeRename))
            try expect(.ioFailure, "pre-rename checked-I/O fault") { try writer.writeIndex(Data("new".utf8)) }
            check(try writer.readIndex() == Data("old".utf8), "old bytes survive a precommit fault")
            let names = try FileManager.default.contentsOfDirectory(atPath: atomic + "/Conversations")
            check(!names.contains(where: { $0.hasPrefix(".tmp-") }), "owned failed precommit temporary is cleaned up")
        }
        do {
            let writer = try ConversationPersistenceFiles(
                verifiedStateRootPath: atomic, testControl: .init(fault: .afterRenameBeforeDirectorySync))
            try expect(.committedButDurabilityUncertain, "post-rename directory-sync fault") {
                try writer.writeIndex(Data("new".utf8))
            }
            check(try writer.readIndex() == Data("new".utf8),
                  "post-rename failure is visible as durability-uncertain, not claimed durable")
        }

        let eexist = try root("temp-eexist", under: work)
        let fixedTemporary = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let eexistWriter = try ConversationPersistenceFiles(
            verifiedStateRootPath: eexist, testControl: .init(temporaryUUID: fixedTemporary))
        let existingTemp = eexist + "/Conversations/.tmp-" + fixedTemporary.uuidString.lowercased()
        try writePrivateFile(existingTemp, Data("preserve-existing-temp".utf8))
        try expect(.ioFailure, "pre-existing exclusive temporary collision") { try eexistWriter.writeIndex(Data("new".utf8)) }
        check(readFile(existingTemp) == Data("preserve-existing-temp".utf8),
              "failed O_EXCL creation never unlinks a pre-existing private temp")

        let replacement = try root("temp-replacement", under: work)
        let replacementTemporary = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let replacementPath = replacement + "/Conversations/.tmp-" + replacementTemporary.uuidString.lowercased()
        let replacementWriter = try ConversationPersistenceFiles(
            verifiedStateRootPath: replacement,
            testControl: .init(temporaryUUID: replacementTemporary, event: { event in
                guard case .afterTemporaryCreate = event else { return }
                guard unlink(replacementPath) == 0 else { return }
                try? writePrivateFile(replacementPath, Data("preserve-replacement".utf8))
            }))
        try expect(.unsafeObject, "temporary path replacement") { try replacementWriter.writeIndex(Data("new".utf8)) }
        check(readFile(replacementPath) == Data("preserve-replacement".utf8),
              "observed replacement temp is never cleaned up")

        let recordCollision = try root("record-collision", under: work)
        let fixedRecord = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let recordPath = recordCollision + "/Conversations/records/" + fixedRecord.uuidString.lowercased() + ".json"
        let recordWriter = try ConversationPersistenceFiles(
            verifiedStateRootPath: recordCollision,
            testControl: .init(recordUUID: fixedRecord, event: { event in
                guard case let .beforePublish(name) = event, name.hasSuffix(".json") else { return }
                try? writePrivateFile(recordPath, Data("existing-record".utf8))
            }))
        try expect(.ioFailure, "atomic immutable record collision") { _ = try recordWriter.writeRecord(Data("new-record".utf8)) }
        check(readFile(recordPath) == Data("existing-record".utf8),
              "atomic no-replace record publish preserves late destination")

        let indexReplacement = try root("index-replacement", under: work)
        do {
            let writer = try ConversationPersistenceFiles(verifiedStateRootPath: indexReplacement)
            try writer.writeIndex(Data("old-index".utf8))
        }
        let indexPath = indexReplacement + "/Conversations/index-v1.json"
        let indexWriter = try ConversationPersistenceFiles(
            verifiedStateRootPath: indexReplacement,
            testControl: .init(event: { event in
                guard case let .beforeLateDestinationCheck(name) = event, name == "index-v1.json" else { return }
                guard unlink(indexPath) == 0 else { return }
                try? writePrivateFile(indexPath, Data("replacement-index".utf8))
            }))
        try expect(.unsafeObject, "late index replacement") { try indexWriter.writeIndex(Data("new-index".utf8)) }
        check(readFile(indexPath) == Data("replacement-index".utf8),
              "late valid-looking index replacement is detected and preserved")

        let bounds = try root("bounds", under: work)
        let bounded = try ConversationPersistenceFiles(verifiedStateRootPath: bounds)
        try bounded.writeIndex(Data("small".utf8))
        try expect(.tooLarge, "index write cap") {
            try bounded.writeIndex(Data(repeating: 0x61, count: ConversationPersistenceFiles.maximumIndexBytes + 1))
        }
        check(try bounded.readIndex() == Data("small".utf8), "oversized write does not replace prior bytes")
        try replaceWithPrivateFile(bounds + "/Conversations/index-v1.json",
                                   Data(repeating: 0x62, count: ConversationPersistenceFiles.maximumIndexBytes + 1))
        try expect(.tooLarge, "bounded read cap") { _ = try bounded.readIndex() }

        let symlinkRoot = try root("symlink", under: work)
        guard symlink(symlinkRoot, symlinkRoot + "/Conversations") == 0 else { throw POSIXFailure("symlink") }
        try expect(.unsafeObject, "symlink storage directory") {
            _ = try ConversationPersistenceFiles(verifiedStateRootPath: symlinkRoot)
        }

        let wrongModeRoot = try root("wrong-mode", under: work)
        try makeDirectory(wrongModeRoot + "/Conversations", mode: 0o700)
        guard chmod(wrongModeRoot + "/Conversations", 0o755) == 0 else { throw POSIXFailure("chmod 0755") }
        check(mode(wrongModeRoot + "/Conversations") & 0o077 == 0o055,
              "negative directory fixture explicitly applies unsafe group/world bits")
        try expect(.unsafeObject, "unsafe directory mode") {
            _ = try ConversationPersistenceFiles(verifiedStateRootPath: wrongModeRoot)
        }

        let lockModeRoot = try root("lock-mode", under: work)
        try makeDirectory(lockModeRoot + "/Conversations", mode: 0o700)
        try makeDirectory(lockModeRoot + "/Conversations/records", mode: 0o700)
        let lockPath = lockModeRoot + "/Conversations/lock"
        try writePrivateFile(lockPath, Data())
        guard chmod(lockPath, 0o644) == 0 else { throw POSIXFailure("chmod 0644") }
        check(mode(lockPath) & 0o077 == 0o044, "negative lock fixture explicitly applies unsafe mode")
        try expect(.unsafeObject, "unsafe lock mode") {
            _ = try ConversationPersistenceFiles(verifiedStateRootPath: lockModeRoot)
        }

        let links = try root("hardlink", under: work)
        let linked = try ConversationPersistenceFiles(verifiedStateRootPath: links)
        try linked.writeIndex(Data("index".utf8))
        guard link(links + "/Conversations/index-v1.json", links + "/Conversations/index-copy") == 0 else {
            throw POSIXFailure("link")
        }
        try expect(.unsafeObject, "hard-linked index") { _ = try linked.readIndex() }

        print("checks: \(failures == 0 ? "all passed" : "\(failures) failed")")
    }

    private static func runChild(_ action: String, root: String, expected: Int32) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [action, root]
        try child.run()
        child.waitUntilExit()
        check(child.terminationReason == .exit && child.terminationStatus == expected,
              "positively owned child \(action) has expected lock result")
    }

    private static func root(_ name: String, under work: String) throws -> String {
        let path = work + "/" + name
        try makeDirectory(path, mode: 0o700)
        return path
    }

    private static func makeDirectory(_ path: String, mode: mode_t) throws {
        guard mkdir(path, mode) == 0 else { throw POSIXFailure("mkdir") }
        guard chmod(path, mode) == 0 else { throw POSIXFailure("chmod") }
    }

    private static func writePrivateFile(_ path: String, _ data: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXFailure("create fixture file") }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXFailure("chmod fixture file") }
        try writeAll(data, to: descriptor)
    }

    private static func replaceWithPrivateFile(_ path: String, _ data: Data) throws {
        guard unlink(path) == 0 else { throw POSIXFailure("unlink fixture file") }
        try writePrivateFile(path, data)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        try data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard count > 0 else { throw POSIXFailure("write fixture file") }
                written += count
            }
        }
    }

    private static func readFile(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func directoryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func mode(_ path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }

    private static func expect(_ expected: ConversationPersistenceFilesError, _ label: String,
                               _ body: () throws -> Void) throws {
        do {
            try body()
            check(false, "\(label) must throw")
        } catch let actual as ConversationPersistenceFilesError {
            check(actual == expected, "\(label) returns sanitized typed error")
        }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        do {
            if try !condition() {
                failures += 1
                print("FAIL: \(message)")
            }
        } catch {
            failures += 1
            print("FAIL: \(message) (\(error))")
        }
    }

    private final class EventLog {
        var directories: [ConversationPersistenceFilesDirectory] = []
    }

    private struct POSIXFailure: Error, CustomStringConvertible {
        let operation: String
        init(_ operation: String) { self.operation = operation }
        var description: String { "\(operation) errno \(errno)" }
    }
}
