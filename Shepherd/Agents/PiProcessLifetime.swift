#if os(macOS)
import Foundation
import Darwin

/// Registered synchronously BEFORE the initial full-argv capture. Pi overwrites
/// argv using process.title, so subsequent acceptance also needs a kernel exec /
/// exit lifetime guard, never merely a process called "pi".
@MainActor final class PiProcessLifetime {
    private let descriptor: Int32
    private(set) var valid = true

    init(pid: Int32) throws {
        guard pid > 1 else { throw PiBridgeFailure.identity }
        let fd = kqueue()
        guard fd >= 0 else { throw PiBridgeFailure.unavailable }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(fd); throw PiBridgeFailure.unavailable }
        var change = kevent64_s()
        change.ident = UInt64(pid); change.filter = Int16(EVFILT_PROC)
        change.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        change.fflags = UInt32(NOTE_EXEC) | UInt32(NOTE_EXIT)
        guard Darwin.kevent64(fd, &change, 1, nil, 0, 0, nil) == 0 else { Darwin.close(fd); throw PiBridgeFailure.identity }
        descriptor = fd
    }

    func isUnchanged() -> Bool {
        guard valid else { return false }
        var event = kevent64_s(), timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let count = Darwin.kevent64(descriptor, nil, 0, &event, 1, 0, &timeout)
        if count != 0 { valid = false }
        return valid
    }
    deinit { Darwin.close(descriptor) }
}
#endif
