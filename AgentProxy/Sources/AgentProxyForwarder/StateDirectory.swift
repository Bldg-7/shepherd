import Foundation
import Darwin

public enum AgentProxyStartError: Error, CustomStringConvertible {
    case stateDirectory(String)
    case socketPath(String)
    case alreadyRunning
    case noPort

    public var description: String {
        switch self {
        case .stateDirectory(let reason): "state folder: \(reason)"
        case .socketPath(let reason): "control socket: \(reason)"
        case .alreadyRunning: "another agent proxy is answering on the control socket"
        case .noPort: "no port could be bound"
        }
    }
}

/// The proxy's own folder: made 0700 when missing, refused when it is a
/// symbolic link or someone else's, and narrowed to 0700 when it is ours but
/// wider. Its files are written whole (a new file renamed over the old one),
/// 0600, and read only when they are plain files of ours.
struct StateDirectory {
    let path: String

    static func prepare(_ path: String) throws -> StateDirectory {
        guard path.hasPrefix("/") else { throw AgentProxyStartError.stateDirectory("not an absolute path") }
        try makeParents(of: path)
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw AgentProxyStartError.stateDirectory("cannot be made (errno \(errno))")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw AgentProxyStartError.stateDirectory("cannot be read (errno \(errno))") }
        guard info.st_mode & S_IFMT != S_IFLNK else { throw AgentProxyStartError.stateDirectory("is a symbolic link") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw AgentProxyStartError.stateDirectory("is not a folder") }
        guard info.st_uid == getuid() else { throw AgentProxyStartError.stateDirectory("belongs to another user") }
        if info.st_mode & 0o077 != 0 {
            guard chmod(path, 0o700) == 0 else { throw AgentProxyStartError.stateDirectory("cannot be made private (errno \(errno))") }
        }
        return StateDirectory(path: path)
    }

    /// The folder a socket goes in: made when missing, and taken only when it
    /// is a folder of ours that no one else can write to.
    static func prepareSocketFolder(for socketPath: String) throws {
        let folder = (socketPath as NSString).deletingLastPathComponent
        try makeParents(of: socketPath)
        var info = stat()
        guard lstat(folder, &info) == 0 else { throw AgentProxyStartError.socketPath("its folder cannot be read") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw AgentProxyStartError.socketPath("its folder is not a folder") }
        guard info.st_uid == getuid() else { throw AgentProxyStartError.socketPath("its folder belongs to another user") }
        guard info.st_mode & 0o022 == 0 else { throw AgentProxyStartError.socketPath("its folder can be written by others") }
    }

    private static func makeParents(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return }
        var info = stat()
        if stat(parent, &info) == 0 { return }
        try makeParents(of: parent)
        if mkdir(parent, 0o700) != 0 && errno != EEXIST {
            throw AgentProxyStartError.stateDirectory("\((parent as NSString).lastPathComponent) cannot be made")
        }
    }

    func url(_ name: String) -> String { path + "/" + name }

    /// nil when the file isn't there.
    func read(_ name: String, limit: Int = 4 << 20) throws -> Data? {
        let descriptor = open(url(name), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw AgentProxyStartError.stateDirectory("\(name) cannot be opened (errno \(errno))")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              Int(info.st_size) <= limit else {
            throw AgentProxyStartError.stateDirectory("\(name) is not a file of ours")
        }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AgentProxyStartError.stateDirectory("\(name) cannot be read") }
            if count == 0 { break }
            data.append(contentsOf: chunk[0..<count])
            guard data.count <= limit else { throw AgentProxyStartError.stateDirectory("\(name) is too large") }
        }
        return data
    }

    func write(_ name: String, _ data: Data) throws {
        let temporary = url(".\(name).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgentProxyStartError.stateDirectory("\(name) cannot be written (errno \(errno))") }
        var written = 0
        let ok: Bool = data.withUnsafeBytes { raw in
            while written < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress! + written, raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard ok, synced, rename(temporary, url(name)) == 0 else {
            unlink(temporary)
            throw AgentProxyStartError.stateDirectory("\(name) cannot be written")
        }
    }
}

/// `state.json`: the port, kept so that it stays the same from one start to
/// the next.
struct ProxyState: Codable {
    var version = 1
    var port: Int
}
