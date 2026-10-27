import Foundation
import Darwin

/// Checked, descriptor-anchored storage for the later conversation journal.
/// This type intentionally has no schema, retention, restore, or recorder wiring.
/// A caller supplies the app's already-selected state root; this initializer walks
/// that absolute path without following symlinks and then owns only fixed children.
enum ConversationPersistenceFilesError: Error, Equatable {
    case unsafeStateRoot
    case unsafeObject
    case lockUnavailable
    case tooLarge
    case ioFailure
    /// The rename completed but syncing its parent directory did not. The new
    /// bytes may be visible, but their durability across a crash is unknown.
    case committedButDurabilityUncertain
}

struct ConversationPersistenceGeneration: Hashable {
    fileprivate let value: String

    /// An opaque store-controlled name, never derived from a session, content,
    /// persistent ID, route, or other captured value.
    static func make() -> ConversationPersistenceGeneration {
        ConversationPersistenceGeneration(value: UUID().uuidString.lowercased())
    }
}

/// Test-only fault points still execute all production validation and I/O before
/// returning an error. They avoid environment switches and never skip checks.
enum ConversationPersistenceFilesTestFault {
    case beforeRename
    case afterRenameBeforeDirectorySync
}

/// A single synchronous, single-writer lease. Keep one instance alive on the
/// later persistence queue for the recorder lifetime; its lock descriptor is
/// closed only when this object is released.
final class ConversationPersistenceFiles {
    static let maximumRecordBytes = 32 << 20
    static let maximumIndexBytes = 1 << 20

    private static let conversationsName = "Conversations"
    private static let recordsName = "records"
    private static let lockName = "lock"
    private static let indexName = "index-v1.json"

    private let stateRootFD: Int32
    private let conversationsFD: Int32
    private let recordsFD: Int32
    private let lockFD: Int32
    private let testFault: ConversationPersistenceFilesTestFault?

    /// `stateRootPath` must identify the state root selected by the forwarder,
    /// not a user/content-derived location. It is walked from `/` using FDs so
    /// no component below that root is subsequently addressed by path.
    init(verifiedStateRootPath stateRootPath: String,
         testFault: ConversationPersistenceFilesTestFault? = nil) throws {
        let root = try Self.openVerifiedStateRoot(stateRootPath)
        var conversations: Int32 = -1
        var records: Int32 = -1
        do {
            conversations = try Self.openOrCreateDirectory(named: Self.conversationsName, in: root)
            records = try Self.openOrCreateDirectory(named: Self.recordsName, in: conversations)
            let lock = try Self.openAndLock(named: Self.lockName, in: conversations)
            stateRootFD = root
            conversationsFD = conversations
            recordsFD = records
            lockFD = lock
            self.testFault = testFault
        } catch {
            if records >= 0 { Darwin.close(records) }
            if conversations >= 0 { Darwin.close(conversations) }
            Darwin.close(root)
            throw error
        }
    }

    deinit {
        Darwin.close(lockFD)
        Darwin.close(recordsFD)
        Darwin.close(conversationsFD)
        Darwin.close(stateRootFD)
    }

    func writeIndex(_ bytes: Data) throws {
        try Self.require(bytes.count <= Self.maximumIndexBytes)
        try writeAtomically(bytes, named: Self.indexName, in: conversationsFD, replacing: true)
    }

    /// `nil` means that the bounded, verified index does not exist yet.
    func readIndex() throws -> Data? {
        try readFile(named: Self.indexName, in: conversationsFD, maximumBytes: Self.maximumIndexBytes)
    }

    @discardableResult
    func writeRecord(_ bytes: Data) throws -> ConversationPersistenceGeneration {
        try Self.require(bytes.count <= Self.maximumRecordBytes)
        let generation = ConversationPersistenceGeneration.make()
        try writeAtomically(bytes, named: Self.recordName(for: generation), in: recordsFD, replacing: false)
        return generation
    }

    func readRecord(_ generation: ConversationPersistenceGeneration) throws -> Data {
        guard let data = try readFile(named: Self.recordName(for: generation), in: recordsFD,
                                      maximumBytes: Self.maximumRecordBytes) else {
            throw ConversationPersistenceFilesError.ioFailure
        }
        return data
    }

    private func writeAtomically(_ bytes: Data, named name: String, in directoryFD: Int32,
                                 replacing: Bool) throws {
        try Self.checkFixedName(name)
        try Self.verifyDirectory(directoryFD)
        try Self.checkDestination(named: name, in: directoryFD, replacing: replacing)
        let temporaryName = ".tmp-" + UUID().uuidString.lowercased()
        var temporaryFD: Int32 = -1
        var renamed = false
        defer {
            if temporaryFD >= 0 { Darwin.close(temporaryFD) }
            if !renamed { Self.unlinkOwnedTemporary(named: temporaryName, in: directoryFD) }
        }

        temporaryFD = Darwin.openat(directoryFD, temporaryName,
                                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporaryFD >= 0 else { throw ConversationPersistenceFilesError.ioFailure }
        guard fchmod(temporaryFD, 0o600) == 0 else { throw ConversationPersistenceFilesError.ioFailure }
        try Self.verifyRegularFile(temporaryFD, maximumBytes: bytes.count, exactSize: 0)
        try Self.writeAll(bytes, to: temporaryFD)
        guard fsync(temporaryFD) == 0 else { throw ConversationPersistenceFilesError.ioFailure }
        try Self.verifyRegularFile(temporaryFD, maximumBytes: bytes.count, exactSize: off_t(bytes.count))
        try Self.verifyFileBinding(named: temporaryName, in: directoryFD, descriptor: temporaryFD,
                                   maximumBytes: bytes.count, exactSize: off_t(bytes.count))
        if testFault == .beforeRename { throw ConversationPersistenceFilesError.ioFailure }
        guard renameat(directoryFD, temporaryName, directoryFD, name) == 0 else {
            throw ConversationPersistenceFilesError.ioFailure
        }
        renamed = true
        do {
            _ = try Self.verifyFileBinding(named: name, in: directoryFD, descriptor: temporaryFD,
                                           maximumBytes: bytes.count, exactSize: off_t(bytes.count))
        } catch {
            // The commit point was crossed, but its current name binding and
            // crash durability can no longer be asserted.
            throw ConversationPersistenceFilesError.committedButDurabilityUncertain
        }
        if testFault == .afterRenameBeforeDirectorySync {
            throw ConversationPersistenceFilesError.committedButDurabilityUncertain
        }
        guard fsync(directoryFD) == 0 else {
            throw ConversationPersistenceFilesError.committedButDurabilityUncertain
        }
    }

    private func readFile(named name: String, in directoryFD: Int32, maximumBytes: Int) throws -> Data? {
        try Self.checkFixedName(name)
        try Self.verifyDirectory(directoryFD)
        let descriptor = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ConversationPersistenceFilesError.ioFailure
        }
        defer { Darwin.close(descriptor) }
        let before = try Self.verifyFileBinding(named: name, in: directoryFD, descriptor: descriptor,
                                                maximumBytes: maximumBytes, exactSize: nil)
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ConversationPersistenceFilesError.ioFailure }
            if count == 0 { break }
            data.append(contentsOf: chunk[0..<count])
            guard data.count <= maximumBytes else { throw ConversationPersistenceFilesError.tooLarge }
        }
        let after = try Self.verifyFileBinding(named: name, in: directoryFD, descriptor: descriptor,
                                               maximumBytes: maximumBytes, exactSize: before.st_size)
        guard after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              data.count == Int(before.st_size) else { throw ConversationPersistenceFilesError.unsafeObject }
        return data
    }

    private static func openVerifiedStateRoot(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ConversationPersistenceFilesError.unsafeStateRoot }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ConversationPersistenceFilesError.unsafeStateRoot
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConversationPersistenceFilesError.ioFailure }
        for component in parts {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(descriptor)
            guard next >= 0 else { throw ConversationPersistenceFilesError.unsafeStateRoot }
            descriptor = next
        }
        do {
            try verifyDirectory(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openOrCreateDirectory(named name: String, in parentFD: Int32) throws -> Int32 {
        try checkFixedName(name)
        try verifyDirectory(parentFD)
        if mkdirat(parentFD, name, 0o700) != 0 && errno != EEXIST {
            throw ConversationPersistenceFilesError.ioFailure
        }
        let descriptor = Darwin.openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConversationPersistenceFilesError.unsafeObject }
        do {
            // mkdirat requests 0700 and the strict post-create check rejects
            // any umask-narrowed result rather than chmodding a pre-existing or
            // replacement directory.
            try verifyDirectoryBinding(named: name, in: parentFD, descriptor: descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openAndLock(named name: String, in directoryFD: Int32) throws -> Int32 {
        try checkFixedName(name)
        try verifyDirectory(directoryFD)
        var descriptor = Darwin.openat(directoryFD, name,
                                       O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 {
            guard fchmod(descriptor, 0o600) == 0 else {
                Darwin.close(descriptor)
                throw ConversationPersistenceFilesError.ioFailure
            }
        } else if errno == EEXIST {
            descriptor = Darwin.openat(directoryFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ConversationPersistenceFilesError.unsafeObject }
        do {
            _ = try verifyFileBinding(named: name, in: directoryFD, descriptor: descriptor,
                                      maximumBytes: 0, exactSize: 0)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw ConversationPersistenceFilesError.lockUnavailable }
                throw ConversationPersistenceFilesError.ioFailure
            }
            _ = try verifyFileBinding(named: name, in: directoryFD, descriptor: descriptor,
                                      maximumBytes: 0, exactSize: 0)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func checkDestination(named name: String, in directoryFD: Int32, replacing: Bool) throws {
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard replacing else { throw ConversationPersistenceFilesError.unsafeObject }
            try verifyStatRegular(info, maximumBytes: Self.maximumIndexBytes, exactSize: nil)
            return
        }
        guard errno == ENOENT else { throw ConversationPersistenceFilesError.ioFailure }
    }

    private static func verifyDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ConversationPersistenceFilesError.ioFailure }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw ConversationPersistenceFilesError.unsafeObject
        }
    }

    private static func verifyDirectoryBinding(named name: String, in parentFD: Int32, descriptor: Int32) throws {
        try verifyDirectory(descriptor)
        var pathInfo = stat()
        var descriptorInfo = stat()
        guard fstatat(parentFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(descriptor, &descriptorInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFDIR,
              pathInfo.st_dev == descriptorInfo.st_dev, pathInfo.st_ino == descriptorInfo.st_ino else {
            throw ConversationPersistenceFilesError.unsafeObject
        }
    }

    @discardableResult
    private static func verifyFileBinding(named name: String, in directoryFD: Int32, descriptor: Int32,
                                          maximumBytes: Int, exactSize: off_t?) throws -> stat {
        let info = try verifyRegularFile(descriptor, maximumBytes: maximumBytes, exactSize: exactSize)
        var pathInfo = stat()
        guard fstatat(directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG,
              pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino else {
            throw ConversationPersistenceFilesError.unsafeObject
        }
        return info
    }

    @discardableResult
    private static func verifyRegularFile(_ descriptor: Int32, maximumBytes: Int,
                                          exactSize: off_t?) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ConversationPersistenceFilesError.ioFailure }
        try verifyStatRegular(info, maximumBytes: maximumBytes, exactSize: exactSize)
        return info
    }

    private static func verifyStatRegular(_ info: stat, maximumBytes: Int, exactSize: off_t?) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1 else { throw ConversationPersistenceFilesError.unsafeObject }
        guard info.st_size >= 0, info.st_size <= off_t(maximumBytes) else { throw ConversationPersistenceFilesError.tooLarge }
        if let exactSize, info.st_size != exactSize { throw ConversationPersistenceFilesError.unsafeObject }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var written = 0
        try data.withUnsafeBytes { raw in
            while written < raw.count {
                let base = raw.baseAddress!.advanced(by: written)
                let count = Darwin.write(descriptor, base, raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ConversationPersistenceFilesError.ioFailure }
                written += count
            }
        }
    }

    private static func unlinkOwnedTemporary(named name: String, in directoryFD: Int32) {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1 else { return }
        _ = unlinkat(directoryFD, name, 0)
    }

    private static func recordName(for generation: ConversationPersistenceGeneration) -> String {
        generation.value + ".json"
    }

    private static func checkFixedName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw ConversationPersistenceFilesError.unsafeObject
        }
    }

    private static func require(_ condition: Bool) throws {
        guard condition else { throw ConversationPersistenceFilesError.tooLarge }
    }
}
