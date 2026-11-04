import Foundation
#if os(macOS)
import Darwin

/// Proves a program hc launched is the process actually running in its terminal:
/// hc's own record (live, PID, exact argv), the kernel foreground anchor/snapshot
/// (session leader with a controlling tty), and a resolvable executable path.
///
/// This is observation, not authority: PID/start-time continuity is necessary
/// but not sufficient (an exec can preserve both), and it never reads argv/env
/// from the kernel or grants browser/MCP/credential access. The caller still
/// compares the resolved executable against what it asked to launch.
public nonisolated enum HcLaunchProof {
    public struct Identity: Sendable {
        public let address: String
        public let pid: Int32
        /// `proc_pidpath`, the kernel's executable for the process — not argv.
        public let executablePath: String
        public let foreground: CoreLocalForegroundSnapshot
    }
    public enum Failure: Error, Equatable, Sendable {
        case missingPID, notLive, argvMismatch, executableUnavailable
        case foreground(String)
    }
    private struct TerminalRecord: Decodable {
        let state: String
        let pid: Int32?
        let argv: [String]
    }

    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Polls `terminal.get` until the terminal is live with a PID, then
    /// double-checks the kernel. Throws on finished/missing/argv-mismatch, and
    /// never infers shell/agent readiness from the PID.
    public static func verify(connection: CoreRPCConnection, address: String, requestedArgv: [String],
                              timeout: Duration = .seconds(10)) async throws -> Identity {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let record: TerminalRecord = try await connection.call("terminal.get",
                parameters: try JSONSerialization.data(withJSONObject: ["terminal": address], options: [.sortedKeys])).result()
            if record.state == "finished" { throw Failure.notLive }
            if record.state == "live", let pid = record.pid {
                guard record.argv == requestedArgv else { throw Failure.argvMismatch }
                let anchor: CoreLocalTerminalAnchor
                do { anchor = try CoreLocalForeground.anchor(programPID: pid) }
                catch let error as CoreLocalForegroundFailure { throw Failure.foreground(error.rawValue) }
                let snapshot: CoreLocalForegroundSnapshot
                do { snapshot = try CoreLocalForeground.snapshot(for: anchor) }
                catch let error as CoreLocalForegroundFailure { throw Failure.foreground(error.rawValue) }
                guard let path = executablePath(of: pid) else { throw Failure.executableUnavailable }
                return Identity(address: address, pid: pid, executablePath: path, foreground: snapshot)
            }
            guard ContinuousClock.now < deadline else { throw Failure.missingPID }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
