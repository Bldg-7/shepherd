import Foundation
import Darwin

@main
struct PersistenceFilesTests {
    private static var failures = 0

    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--lock-child" {
            do {
                _ = try ConversationPersistenceFiles(verifiedStateRootPath: CommandLine.arguments[2])
                exit(10)
            } catch ConversationPersistenceFilesError.lockUnavailable {
                exit(0)
            } catch {
                exit(11)
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
        var holder: ConversationPersistenceFiles? = try ConversationPersistenceFiles(verifiedStateRootPath: valid)
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

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--lock-child", valid]
        try child.run()
        child.waitUntilExit()
        check(child.terminationReason == .exit && child.terminationStatus == 0,
              "positively owned second process cannot acquire the writer lock")
        holder = nil
        _ = try ConversationPersistenceFiles(verifiedStateRootPath: valid)

        let atomic = try root("atomic", under: work)
        do {
            let writer = try ConversationPersistenceFiles(verifiedStateRootPath: atomic)
            try writer.writeIndex(Data("old".utf8))
        }
        do {
            let writer = try ConversationPersistenceFiles(verifiedStateRootPath: atomic, testFault: .beforeRename)
            try expect(.ioFailure, "pre-rename checked-I/O fault") { try writer.writeIndex(Data("new".utf8)) }
            check(try writer.readIndex() == Data("old".utf8), "old bytes survive a precommit fault")
            let names = try FileManager.default.contentsOfDirectory(atPath: atomic + "/Conversations")
            check(!names.contains(where: { $0.hasPrefix(".tmp-") }), "failed precommit temporary is safely cleaned up")
        }
        do {
            let writer = try ConversationPersistenceFiles(verifiedStateRootPath: atomic,
                                                          testFault: .afterRenameBeforeDirectorySync)
            try expect(.committedButDurabilityUncertain, "post-rename directory-sync fault") {
                try writer.writeIndex(Data("new".utf8))
            }
            check(try writer.readIndex() == Data("new".utf8),
                  "post-rename failure is visible as durability-uncertain, not claimed durable")
        }

        let bounds = try root("bounds", under: work)
        let bounded = try ConversationPersistenceFiles(verifiedStateRootPath: bounds)
        try bounded.writeIndex(Data("small".utf8))
        try expect(.tooLarge, "index write cap") {
            try bounded.writeIndex(Data(repeating: 0x61, count: ConversationPersistenceFiles.maximumIndexBytes + 1))
        }
        check(try bounded.readIndex() == Data("small".utf8), "oversized write does not replace prior bytes")
        let oversized = Data(repeating: 0x62, count: ConversationPersistenceFiles.maximumIndexBytes + 1)
        try oversized.withUnsafeBytes { raw in
            let fd = open(bounds + "/Conversations/index-v1.json", O_WRONLY | O_TRUNC | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXFailure("open oversized fixture") }
            defer { close(fd) }
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw POSIXFailure("write oversized fixture") }
                offset += count
            }
        }
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
        let lock = open(lockPath, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXFailure("lock fixture") }
        close(lock)
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

    private static func root(_ name: String, under work: String) throws -> String {
        let path = work + "/" + name
        try makeDirectory(path, mode: 0o700)
        return path
    }

    private static func makeDirectory(_ path: String, mode: mode_t) throws {
        guard mkdir(path, mode) == 0 else { throw POSIXFailure("mkdir") }
        guard chmod(path, mode) == 0 else { throw POSIXFailure("chmod") }
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

    private struct POSIXFailure: Error, CustomStringConvertible {
        let operation: String
        init(_ operation: String) { self.operation = operation }
        var description: String { "\(operation) errno \(errno)" }
    }
}
