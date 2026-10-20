import Foundation
import Darwin

/// Gets dropped images onto the machine a pane is on, each with
/// `TerminalDropPaste.receiveScript`, and says where they landed there.
/// One instance is one drop's uploads: `close()` ends whatever connection
/// they went over.
nonisolated protocol TerminalDropUploading: Sendable {
    /// Sends `file` into `batch` and returns its path on the pane's machine.
    /// Calls `progress` with the bytes sent so far, as they go. Cancelling
    /// the task stops the upload, and the far end then removes what it got.
    func upload(_ file: TerminalDropFile, batch: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> String
    func close() async
}

/// A dropped image, opened once: what is checked (that it is a regular
/// file, and its size) is what is sent, whatever happens at its path in
/// the meantime. The descriptor is closed with this.
nonisolated final class TerminalDropFile: Sendable {
    /// Its name as dropped, for messages.
    let name: String
    /// Its name on the pane's machine (see `TerminalDropPaste.remoteName`).
    let remoteName: String
    let descriptor: Int32
    let size: Int64

    private init(name: String, remoteName: String, descriptor: Int32, size: Int64) {
        self.name = name
        self.remoteName = remoteName
        self.descriptor = descriptor
        self.size = size
    }

    deinit { Darwin.close(descriptor) }

    /// Opens what is at `url`, refusing anything but a regular file of at
    /// most `TerminalDropPaste.maximumFileBytes`.
    static func open(_ url: URL, remoteName: String) throws -> TerminalDropFile {
        // Non-blocking only for the open: a FIFO dropped by mistake must
        // not hold this up waiting for a writer.
        let descriptor = Darwin.open(url.path(percentEncoded: false), O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalDropError.unreadable(errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw TerminalDropError.unreadable(code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw TerminalDropError.notRegularFile
        }
        guard Int64(info.st_size) <= TerminalDropPaste.maximumFileBytes else {
            Darwin.close(descriptor)
            throw TerminalDropError.tooLarge
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        return TerminalDropFile(name: url.lastPathComponent, remoteName: remoteName,
                                descriptor: descriptor, size: Int64(info.st_size))
    }
}

nonisolated enum TerminalDropError: Error, LocalizedError, Equatable {
    /// A pane on the host, whose host key hasn't been pinned yet: nothing
    /// is sent to a host whose key the terminal hasn't checked first.
    case needsHostKey
    case tooLarge
    case notRegularFile
    case unreadable(Int32)
    /// Nothing moved for the time `TerminalDropController` allows.
    case stalled
    /// The far end ended well but didn't print the file's path, or printed
    /// one that isn't the file's.
    case unconfirmed
    /// A herdr machine's target `TerminalDropPaste.isUsableTarget` refuses.
    case unusableTarget
    /// The command on the far end ended with `status`; `detail` is the last
    /// line it wrote to stderr. `receiveScript` exits with 64–75, ssh
    /// itself with 255.
    case failed(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .needsHostKey: String(localized: "Connect to this machine's terminal first to verify its host key.")
        case .tooLarge: String(localized: "It is larger than 16 MiB.")
        case .notRegularFile: String(localized: "It isn't a regular file.")
        case .unreadable(let code): POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription
        case .stalled: String(localized: "The upload stopped making progress.")
        case .unconfirmed: String(localized: "The machine didn't confirm the upload.")
        case .unusableTarget: String(localized: "This machine's SSH address can't be used for uploads.")
        case .failed(let status, let detail):
            switch status {
            case 70, 71: String(localized: "Uploads need sh and a writable ~/.cache/3rdr/drops on that machine.")
            case 72: String(localized: "A file with that name is already there.")
            case 73, 75: String(localized: "It couldn't be written on that machine.")
            case 74: String(localized: "It arrived incomplete on that machine.")
            case 255 where detail.isEmpty: String(localized: "ssh couldn't reach the machine.")
            default: detail.isEmpty ? String(localized: "The upload ended with exit status \(status).") : detail
            }
        }
    }

    /// Whether this was about the one file only, so the drop's other files
    /// are still worth sending. Anything else — a connection that failed
    /// or stopped, ssh that couldn't reach the machine, a machine that
    /// can't take uploads at all — would fail them all the same way.
    var concernsOnlyThisFile: Bool {
        switch self {
        case .tooLarge, .notRegularFile, .unreadable, .unconfirmed: true
        case .failed(let status, _): (72...75).contains(status)
        case .needsHostKey, .stalled, .unusableTarget: false
        }
    }
}
