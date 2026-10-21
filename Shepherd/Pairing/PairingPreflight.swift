#if os(macOS)
import Darwin
import Foundation

// What the pairing page checks before it shows a code (SHPHRD-77, "사전
// 점검"): that Remote Login is on, and the SSH host key a device is to
// expect; whether herdr is running; and what the firewall would do to the
// pairing listener. The checks are reached through these protocols and
// closures, so the tests can stand in for them without touching sshd, the
// firewall or herdr.

/// What `LocalSSHServerProbe` found at 127.0.0.1:22.
nonisolated enum SSHHostKeyProbeResult: Hashable, Sendable {
    /// Remote Login is on; this is the host key a client is given.
    case on(PairingPayload.HostKey)
    /// Nothing listens on port 22: Remote Login is off.
    case off
    /// Something went wrong other than Remote Login being off.
    case failed(String)
}

nonisolated protocol SSHHostKeyProbing: Sendable {
    func probe() async -> SSHHostKeyProbeResult
}

/// What the application firewall would do with the pairing listener.
nonisolated enum FirewallState: Hashable, Sendable {
    case off
    /// On: macOS may ask whether hrdrhrdrhrdr may accept incoming
    /// connections the first time it listens.
    case on
    /// On, with every incoming connection blocked but the system's own:
    /// no device can reach the pairing listener.
    case blocksAllIncoming
    case unknown
}

/// The firewall's state, as `socketfilterfw` prints it; it needs no
/// administrator rights to read.
nonisolated enum FirewallStatusReader {
    static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    /// From `--getglobalstate` ("Firewall is enabled. (State = 1)") and
    /// `--getblockall` ("Firewall has block all state set to enabled.").
    static func parse(globalState: String, blockAll: String) -> FirewallState {
        let global = globalState.lowercased(), all = blockAll.lowercased()
        if all.contains("set to enabled") || global.contains("state = 2") || global.contains("block all non-essential") {
            return .blocksAllIncoming
        }
        if global.contains("is enabled") || global.contains("state = 1") { return .on }
        if global.contains("is disabled") || global.contains("state = 0") { return .off }
        return .unknown
    }

    static func current() async -> FirewallState {
        async let global = run(["--getglobalstate"])
        async let all = run(["--getblockall"])
        guard let globalState = await global else { return .unknown }
        return parse(globalState: globalState, blockAll: await all ?? "")
    }

    /// The tool's output, or nil when it fails or takes more than three seconds.
    private static func run(_ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                if finished.wait(timeout: .now() + 3) == .timedOut {
                    process.terminate()
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}

/// Whether this Mac's herdr is running: its default session's socket
/// exists and takes a connection. A device's first connection ends at
/// herdr, so pairing while it isn't running fails that check.
nonisolated enum LocalHerdrStatus {
    static func isRunning(socketPath: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: accepts(socketPath))
            }
        }
    }

    private static func accepts(_ path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }
}

/// Asks the person at the Mac to prove they are its owner before a device
/// is let in: Touch ID, or the account's password (`DeviceOwnerApproval`).
/// The pairing page goes through this protocol, so the tests can answer
/// for them.
@MainActor protocol PairingApprovalAuthenticating: AnyObject {
    /// Nil once they have; otherwise why not, in words to show.
    func authenticate(reason: String) async -> String?
    /// Ends a request that is still waiting, as if it had been cancelled.
    func cancel()
}

/// System Settings' Sharing pane, at Remote Login: the anchor the Sharing
/// settings extension lists for it (`Services_RemoteLogin`).
nonisolated enum RemoteLoginSettings {
    static let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension?Services_RemoteLogin")!
}
#endif
