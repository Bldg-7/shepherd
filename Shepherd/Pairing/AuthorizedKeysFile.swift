#if os(macOS)
import Darwin
import Foundation

/// `~/.ssh/authorized_keys`, as the pairing page adds a device's line to it
/// and removes it again (SHPHRD-77, "Mac에서의 허가"). It is written only
/// when it is plainly the account's own: `~/.ssh` a directory of its own
/// that no one else can write to, and the file, if there is one, a regular
/// file of its own, not a symbolic link, that no one else can write to.
/// Otherwise nothing is written and the person is given the command to run
/// themselves.
///
/// Adding appends one line, through a descriptor that doesn't follow a
/// link, and syncs it; a key that is there already, with any options and
/// comment, isn't added again. Removing takes out only lines with both the
/// line's key and its marker comment, writes the rest to a new file beside
/// it and renames that over it, and gives up if the file changed while it
/// was being rewritten.
nonisolated struct AuthorizedKeysFile: Sendable {
    /// The most of the file read: far more than any real one.
    static let maximumSize = 4 * 1024 * 1024

    /// The account's home directory: the password database's, as sshd has it.
    let home: String
    /// Run between writing a rewritten file and putting it in place, for
    /// the tests to change the file there.
    var beforeReplacing: (@Sendable () -> Void)?

    init(home: String) {
        self.home = home
    }

    static func forThisAccount() -> AuthorizedKeysFile {
        if let entry = getpwuid(getuid()) { return AuthorizedKeysFile(home: String(cString: entry.pointee.pw_dir)) }
        return AuthorizedKeysFile(home: NSHomeDirectory())
    }

    var directoryPath: String { home + "/.ssh" }
    var path: String { directoryPath + "/authorized_keys" }

    enum Problem: Hashable, Sendable {
        case directoryIsSymbolicLink
        case directoryNotADirectory
        case directoryNotOwned
        case directoryWritableByOthers
        case fileIsSymbolicLink
        case fileNotRegular
        case fileNotOwned
        case fileWritableByOthers
        case fileTooLarge
        /// A system call failed: its name and errno.
        case system(String, Int32)
    }

    /// Whether a line can be written, without writing anything.
    enum Inspection: Hashable, Sendable {
        case writable
        case problem(Problem)
    }

    func inspect() -> Inspection {
        do {
            guard try checkDirectory(create: false) else { return .writable }
            _ = try readFile()
            return .writable
        } catch AuthorizedKeysFileError.refused(let problem) {
            return .problem(problem)
        } catch {
            return .problem(.system("read", EIO))
        }
    }

    enum AddResult: Hashable, Sendable {
        case added
        /// The key was in the file already; nothing was written.
        case alreadyPresent
    }

    func add(_ line: AuthorizedKeyLine) throws -> AddResult {
        _ = try checkDirectory(create: true)
        guard let existing = try readFile() else {
            try create(contents: Data((line.text + "\n").utf8))
            return .added
        }
        if Self.lines(of: existing.data).contains(where: { line.hasSameKey(as: $0) }) { return .alreadyPresent }
        let separator = existing.data.isEmpty || existing.data.last == UInt8(ascii: "\n") ? "" : "\n"
        try append(Data((separator + line.text + "\n").utf8), to: existing)
        return .added
    }

    enum RemoveResult: Hashable, Sendable {
        case removed
        /// No line has both the key and the marker: taken out by hand.
        case notFound
    }

    /// Takes out the lines that have the key and the comment of `lineText`,
    /// the line as it was added.
    func remove(lineText: String) throws -> RemoveResult {
        guard let wanted = AuthorizedKeysEntry(line: lineText) else { return .notFound }
        guard try checkDirectory(create: false), let existing = try readFile() else { return .notFound }
        let kept = Self.splitLines(existing.data).filter { line in
            guard let entry = AuthorizedKeysEntry(line: String(decoding: line.text, as: UTF8.self)) else { return true }
            return !(entry.keyBlob == wanted.keyBlob && entry.comment == wanted.comment)
        }
        let original = Self.splitLines(existing.data)
        guard kept.count < original.count else { return .notFound }
        var contents = Data()
        for line in kept {
            contents.append(contentsOf: line.text)
            if line.hasNewline { contents.append(UInt8(ascii: "\n")) }
        }
        try replace(existing, with: contents)
        return .removed
    }

    /// Whether a line with the key and the comment of `lineText` is in the
    /// file. Nil when the file can't be read as one the pairing page writes.
    func contains(lineText: String) -> Bool? {
        guard let wanted = AuthorizedKeysEntry(line: lineText) else { return false }
        do {
            guard try checkDirectory(create: false), let existing = try readFile() else { return false }
            return Self.lines(of: existing.data).contains { line in
                guard let entry = AuthorizedKeysEntry(line: line) else { return false }
                return entry.keyBlob == wanted.keyBlob && entry.comment == wanted.comment
            }
        } catch {
            return nil
        }
    }

    /// What to run to add the line by hand. The line is base64, a fixed
    /// key type and options, and a marker of `[a-z0-9:-]`, so it has no
    /// quote to break out of.
    static func addCommand(for line: AuthorizedKeyLine) -> String {
        "printf '%s\\n' '\(line.text)' >> ~/.ssh/authorized_keys"
    }

    // MARK: - Checks

    /// True when `~/.ssh` is there (made, 0700, when `create`).
    private func checkDirectory(create: Bool) throws -> Bool {
        var status = stat()
        if lstat(directoryPath, &status) != 0 {
            guard errno == ENOENT else { throw AuthorizedKeysFileError.refused(.system("lstat", errno)) }
            guard create else { return false }
            guard mkdir(directoryPath, 0o700) == 0 else { throw AuthorizedKeysFileError.refused(.system("mkdir", errno)) }
            guard chmod(directoryPath, 0o700) == 0, lstat(directoryPath, &status) == 0 else {
                throw AuthorizedKeysFileError.refused(.system("chmod", errno))
            }
        }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: throw AuthorizedKeysFileError.refused(.directoryIsSymbolicLink)
        default: throw AuthorizedKeysFileError.refused(.directoryNotADirectory)
        }
        guard status.st_uid == geteuid() else { throw AuthorizedKeysFileError.refused(.directoryNotOwned) }
        guard status.st_mode & 0o022 == 0 else { throw AuthorizedKeysFileError.refused(.directoryWritableByOthers) }
        return true
    }

    /// The file as read through one descriptor, and what it was.
    private struct Existing {
        let data: Data
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modified: timespec
        let mode: mode_t
    }

    /// Nil when there is no file.
    private func readFile() throws -> Existing? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw AuthorizedKeysFileError.refused(.fileIsSymbolicLink)
            default: throw AuthorizedKeysFileError.refused(.system("open", errno))
            }
        }
        defer { close(fd) }
        let status = try Self.checkedStatus(of: fd)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw AuthorizedKeysFileError.refused(.system("read", errno))
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumSize else { throw AuthorizedKeysFileError.refused(.fileTooLarge) }
        }
        return Existing(data: data, device: status.st_dev, inode: status.st_ino, size: status.st_size,
                        modified: status.st_mtimespec, mode: status.st_mode)
    }

    private static func checkedStatus(of fd: Int32) throws -> stat {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw AuthorizedKeysFileError.refused(.system("fstat", errno)) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw AuthorizedKeysFileError.refused(.fileNotRegular) }
        guard status.st_uid == geteuid() else { throw AuthorizedKeysFileError.refused(.fileNotOwned) }
        guard status.st_mode & 0o022 == 0 else { throw AuthorizedKeysFileError.refused(.fileWritableByOthers) }
        return status
    }

    // MARK: - Writing

    private func create(contents: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw errno == EEXIST ? AuthorizedKeysFileError.changedWhileWriting : AuthorizedKeysFileError.refused(.system("open", errno))
        }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw AuthorizedKeysFileError.refused(.system("fchmod", errno)) }
        try Self.write(contents, to: fd)
    }

    private func append(_ contents: Data, to existing: Existing) throws {
        let fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw errno == ELOOP ? AuthorizedKeysFileError.refused(.fileIsSymbolicLink) : AuthorizedKeysFileError.refused(.system("open", errno))
        }
        defer { close(fd) }
        let status = try Self.checkedStatus(of: fd)
        guard status.st_dev == existing.device, status.st_ino == existing.inode else { throw AuthorizedKeysFileError.changedWhileWriting }
        try Self.write(contents, to: fd)
    }

    private func replace(_ existing: Existing, with contents: Data) throws {
        let temporary = directoryPath + "/.authorized_keys.hrdrhrdrhrdr-" + UUID().uuidString
        let mode = existing.mode & 0o755
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw AuthorizedKeysFileError.refused(.system("open", errno)) }
        var renamed = false
        defer { if !renamed { unlink(temporary) } }
        do {
            defer { close(fd) }
            guard fchmod(fd, mode) == 0 else { throw AuthorizedKeysFileError.refused(.system("fchmod", errno)) }
            try Self.write(contents, to: fd)
        }
        beforeReplacing?()
        // The file must be the one read, as it was read.
        guard let now = try readFile(), now.device == existing.device, now.inode == existing.inode, now.size == existing.size,
              now.modified.tv_sec == existing.modified.tv_sec, now.modified.tv_nsec == existing.modified.tv_nsec,
              now.data == existing.data else {
            throw AuthorizedKeysFileError.changedWhileWriting
        }
        guard rename(temporary, path) == 0 else { throw AuthorizedKeysFileError.refused(.system("rename", errno)) }
        renamed = true
        let directory = open(directoryPath, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            _ = fsync(directory)
            close(directory)
        }
    }

    private static func write(_ contents: Data, to fd: Int32) throws {
        let bytes = Array(contents)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw AuthorizedKeysFileError.refused(.system("write", errno))
            }
            offset += written
        }
        guard fsync(fd) == 0 else { throw AuthorizedKeysFileError.refused(.system("fsync", errno)) }
    }

    // MARK: - Lines

    private struct Line {
        let text: [UInt8]
        let hasNewline: Bool
    }

    private static func splitLines(_ data: Data) -> [Line] {
        var lines: [Line] = []
        var current: [UInt8] = []
        for byte in data {
            if byte == UInt8(ascii: "\n") {
                lines.append(Line(text: current, hasNewline: true))
                current = []
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty { lines.append(Line(text: current, hasNewline: false)) }
        return lines
    }

    private static func lines(of data: Data) -> [String] {
        splitLines(data).map { String(decoding: $0.text, as: UTF8.self) }
    }
}

nonisolated enum AuthorizedKeysFileError: Error, Equatable, LocalizedError {
    case refused(AuthorizedKeysFile.Problem)
    /// The file changed between reading it and writing it.
    case changedWhileWriting

    var errorDescription: String? {
        switch self {
        case .refused(let problem): problem.description
        case .changedWhileWriting:
            String(localized: "~/.ssh/authorized_keys changed while hrdrhrdrhrdr was writing it, so it was left as it is. Try again.")
        }
    }
}

extension AuthorizedKeysFile.Problem: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .directoryIsSymbolicLink:
            String(localized: "~/.ssh is a symbolic link, so hrdrhrdrhrdr doesn't write to it.")
        case .directoryNotADirectory:
            String(localized: "~/.ssh isn't a folder.")
        case .directoryNotOwned:
            String(localized: "~/.ssh belongs to another user.")
        case .directoryWritableByOthers:
            String(localized: "Other users can write to ~/.ssh, so sshd wouldn't trust keys in it.")
        case .fileIsSymbolicLink:
            String(localized: "~/.ssh/authorized_keys is a symbolic link, so hrdrhrdrhrdr doesn't write to it.")
        case .fileNotRegular:
            String(localized: "~/.ssh/authorized_keys isn't a regular file.")
        case .fileNotOwned:
            String(localized: "~/.ssh/authorized_keys belongs to another user.")
        case .fileWritableByOthers:
            String(localized: "Other users can write to ~/.ssh/authorized_keys, so sshd wouldn't trust keys in it.")
        case .fileTooLarge:
            String(localized: "~/.ssh/authorized_keys is unusually large, so hrdrhrdrhrdr doesn't write to it.")
        case .system(let call, let code):
            String(localized: "~/.ssh/authorized_keys couldn't be read or written (\(call): \(String(cString: strerror(code)))).")
        }
    }
}
#endif
