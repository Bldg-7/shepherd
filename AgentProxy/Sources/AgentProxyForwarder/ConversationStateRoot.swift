import Foundation
import Darwin

enum ConversationStateRootError: Error, Equatable {
    case unsafeStateRoot
    case unsafeObject
    case ioFailure
    case lockUnavailable
    /// EIO, EINTR, descriptor or memory exhaustion and full disks may clear.
    case retryableOpen(Int32)
}

/// Descriptor-anchored checks for the private state root. Every component is
/// opened without following symlinks; directories must be 0700 and files 0600,
/// owned by this UID with one link. This is not a boundary against a hostile
/// same-UID process.
enum ConversationStateRoot {
    /// Confirmed maintenance may need a fresh root. Walk without symlinks and
    /// create only missing directory components, never chmod or unlink an
    /// existing object. Competing creators converge on the same verified root.
    static func prepare(_ path: String) throws {
        let parts = try components(path)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw openError(errno, unsafe: .unsafeStateRoot) }
        defer { Darwin.close(descriptor) }
        for component in parts {
            var next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if next < 0 && errno == ENOENT {
                let made = component.withCString { mkdirat(descriptor, $0, 0o700) }
                guard made == 0 || errno == EEXIST else { throw openError(errno, unsafe: .unsafeStateRoot) }
                if made == 0 && fsync(descriptor) != 0 { throw ConversationStateRootError.ioFailure }
                next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            }
            guard next >= 0 else { throw openError(errno, unsafe: .unsafeStateRoot) }
            Darwin.close(descriptor); descriptor = next
        }
        try verifyDirectory(descriptor)
    }

    static func openVerified(_ path: String) throws -> Int32 {
        let parts = try components(path)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw openError(errno, unsafe: .unsafeStateRoot) }
        for component in parts {
            let next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            let failure = errno
            Darwin.close(descriptor)
            guard next >= 0 else { throw openError(failure, unsafe: .unsafeStateRoot) }
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

    /// mkdirat requests 0700 and the strict check rejects any umask-narrowed
    /// result rather than chmodding a pre-existing or replacement directory.
    /// The parent is synced even when the link already existed, so a prior
    /// mkdir whose fsync failed is retried safely.
    static func openOrCreateDirectory(named name: String, in parentFD: Int32) throws -> Int32 {
        try checkFixedName(name)
        try verifyDirectory(parentFD)
        if mkdirat(parentFD, name, 0o700) != 0 && errno != EEXIST { throw openError(errno, unsafe: .unsafeObject) }
        let descriptor = Darwin.openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw openError(errno, unsafe: .unsafeObject) }
        do {
            try verifyDirectoryBinding(named: name, in: parentFD, descriptor: descriptor)
            guard fsync(parentFD) == 0 else { throw ConversationStateRootError.ioFailure }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Open, or exclusively create, a private regular file without following
    /// a symlink. The caller owns the returned descriptor.
    static func openOrCreateFile(named name: String, in directoryFD: Int32, maximumBytes: Int) throws -> Int32 {
        try checkFixedName(name)
        try verifyDirectory(directoryFD)
        var descriptor = Darwin.openat(directoryFD, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 {
            guard fchmod(descriptor, 0o600) == 0, fsync(directoryFD) == 0 else {
                Darwin.close(descriptor); throw ConversationStateRootError.ioFailure
            }
        } else if errno == EEXIST {
            descriptor = Darwin.openat(directoryFD, name, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw openError(errno, unsafe: .unsafeObject) }
        do {
            _ = try verifyFileBinding(named: name, in: directoryFD, descriptor: descriptor, maximumBytes: maximumBytes, exactSize: nil)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func openAndLock(named name: String, in directoryFD: Int32) throws -> Int32 {
        let descriptor = try openOrCreateFile(named: name, in: directoryFD, maximumBytes: 0)
        do {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw ConversationStateRootError.lockUnavailable }
                throw ConversationStateRootError.ioFailure
            }
            _ = try verifyFileBinding(named: name, in: directoryFD, descriptor: descriptor, maximumBytes: 0, exactSize: 0)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Unlink a verified private regular file. A missing file is success.
    static func removeFile(named name: String, in directoryFD: Int32) throws {
        try checkFixedName(name)
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ConversationStateRootError.ioFailure }
            return
        }
        try verifyStatRegular(info, maximumBytes: Int.max, exactSize: nil)
        guard unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT else { throw ConversationStateRootError.ioFailure }
    }

    static func verifyDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ConversationStateRootError.ioFailure }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw ConversationStateRootError.unsafeObject
        }
    }

    static func verifyDirectoryBinding(named name: String, in parentFD: Int32, descriptor: Int32) throws {
        try verifyDirectory(descriptor)
        var pathInfo = stat(), descriptorInfo = stat()
        guard fstatat(parentFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0, fstat(descriptor, &descriptorInfo) == 0,
              pathInfo.st_mode & S_IFMT == S_IFDIR,
              pathInfo.st_dev == descriptorInfo.st_dev, pathInfo.st_ino == descriptorInfo.st_ino else {
            throw ConversationStateRootError.unsafeObject
        }
    }

    @discardableResult
    static func verifyFileBinding(named name: String, in directoryFD: Int32, descriptor: Int32,
                                  maximumBytes: Int, exactSize: off_t?) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ConversationStateRootError.ioFailure }
        try verifyStatRegular(info, maximumBytes: maximumBytes, exactSize: exactSize)
        var pathInfo = stat()
        guard fstatat(directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG,
              pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino else {
            throw ConversationStateRootError.unsafeObject
        }
        return info
    }

    private static func verifyStatRegular(_ info: stat, maximumBytes: Int, exactSize: off_t?) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1 else { throw ConversationStateRootError.unsafeObject }
        guard info.st_size >= 0, maximumBytes == Int.max || info.st_size <= off_t(maximumBytes) else {
            throw ConversationStateRootError.unsafeObject
        }
        if let exactSize, info.st_size != exactSize { throw ConversationStateRootError.unsafeObject }
    }

    private static func components(_ path: String) throws -> [Substring] {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ConversationStateRootError.unsafeStateRoot }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." }) else { throw ConversationStateRootError.unsafeStateRoot }
        return parts
    }

    private static func checkFixedName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw ConversationStateRootError.unsafeObject
        }
    }

    static func openError(_ code: Int32, unsafe: ConversationStateRootError) -> ConversationStateRootError {
        switch code {
        case EIO, EINTR, EMFILE, ENFILE, ENOMEM, EAGAIN, ENOSPC, EDQUOT: return .retryableOpen(code)
        default: return unsafe
        }
    }
}

/// Root-wide exclusive admission for every persistent producer. Forwarder and
/// its recorder share the same locked open-file description; independent
/// recorders and offline maintenance must acquire their own lock. The file is
/// never unlinked. This is not a boundary against a hostile same-UID process
/// or unsupported experimental binaries that ignore this protocol.
final class ConversationProducerLease: @unchecked Sendable {
    private static let name = "producer.lock"
    private let path: String
    private let rootFD: Int32
    let descriptor: Int32

    init(rootPath: String, inheritedDescriptor: Int32? = nil) throws {
        let root = try ConversationStateRoot.openVerified(rootPath)
        var lock: Int32 = -1
        do {
            if let inheritedDescriptor {
                lock = dup(inheritedDescriptor)
                guard lock >= 0, fcntl(lock, F_SETFD, FD_CLOEXEC) == 0 else { throw ConversationStateRootError.ioFailure }
                _ = try ConversationStateRoot.verifyFileBinding(named: Self.name, in: root, descriptor: lock, maximumBytes: 0, exactSize: 0)
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ConversationStateRootError.lockUnavailable }
            } else {
                lock = try ConversationStateRoot.openAndLock(named: Self.name, in: root)
            }
            try Self.verify(path: rootPath, rootFD: root, descriptor: lock)
            path = rootPath; rootFD = root; descriptor = lock
        } catch {
            if lock >= 0 { Darwin.close(lock) }
            Darwin.close(root)
            throw error
        }
    }

    deinit { Darwin.close(descriptor); Darwin.close(rootFD) }

    /// Re-walk the explicit path and compare root and lock inodes; reject a
    /// replaced/moved namespace rather than following it or recreating a lock.
    func verify() throws { try Self.verify(path: path, rootFD: rootFD, descriptor: descriptor) }

    private static func verify(path: String, rootFD: Int32, descriptor: Int32) throws {
        let current = try ConversationStateRoot.openVerified(path)
        defer { Darwin.close(current) }
        var expected = stat(), actual = stat()
        guard fstat(rootFD, &expected) == 0, fstat(current, &actual) == 0,
              expected.st_dev == actual.st_dev, expected.st_ino == actual.st_ino else { throw ConversationStateRootError.unsafeObject }
        try ConversationStateRoot.verifyDirectory(rootFD)
        _ = try ConversationStateRoot.verifyFileBinding(named: Self.name, in: rootFD, descriptor: descriptor, maximumBytes: 0, exactSize: 0)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ConversationStateRootError.lockUnavailable }
        _ = try ConversationStateRoot.verifyFileBinding(named: Self.name, in: rootFD, descriptor: descriptor, maximumBytes: 0, exactSize: 0)
    }
}
