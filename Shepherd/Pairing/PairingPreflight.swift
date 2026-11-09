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
