#if os(macOS)
import Foundation
import Darwin

/// Kernel evidence for one explicitly nominated, same-user process. Not Codable:
/// argv may contain user instructions and must never enter status/log payloads.
nonisolated struct PiProcessIdentity: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let pid: Int32
    let parentPID: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
    let cwd: String
    let arguments: [String]
    var description: String { "<owned Pi process identity>" }
    var debugDescription: String { description }

    static func capture(pid: Int32) throws -> Self {
        guard pid > 1 else { throw PiBridgeFailure.identity }
        let before = try info(pid)
        // proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as (4 * MAXPATHLEN);
        // that expression macro is not imported by Swift.
        var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0 else { throw PiBridgeFailure.identity }
        var vnode = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == MemoryLayout<proc_vnodepathinfo>.size else {
            throw PiBridgeFailure.identity
        }
        let cwd = withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], count = 0
        guard sysctl(&mib, 3, nil, &count, nil, 0) == 0, count > 4, count <= 256 * 1024 else { throw PiBridgeFailure.identity }
        var buffer = [UInt8](repeating: 0, count: count)
        guard sysctl(&mib, 3, &buffer, &count, nil, 0) == 0, count > 4 else { throw PiBridgeFailure.identity }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 512 else { throw PiBridgeFailure.identity }
        var index = 4
        func string() throws -> String {
            let start = index
            while index < count && buffer[index] != 0 { index += 1 }
            guard index < count, let value = String(bytes: buffer[start..<index], encoding: .utf8) else { throw PiBridgeFailure.identity }
            index += 1; return value
        }
        _ = try string() // kernel executable path, before argv padding
        while index < count && buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argc { arguments.append(try string()) }
        let after = try info(pid)
        guard before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec,
              before.pbi_ppid == after.pbi_ppid, cwd.hasPrefix("/") else { throw PiBridgeFailure.identity }
        return .init(pid: pid, parentPID: Int32(before.pbi_ppid), startSeconds: before.pbi_start_tvsec,
                     startMicroseconds: before.pbi_start_tvusec, executable: canonical(String(cString: executable)),
                     cwd: canonical(cwd), arguments: arguments)
    }

    func isCurrent() -> Bool { (try? Self.capture(pid: pid)) == self }

    /// Only after a full initial argv match AND an unchanged kernel exec/exit
    /// watcher. The pinned Pi CLI preserves argc but replaces its argv storage
    /// with exactly "pi" followed by empty strings. No other rewrite is accepted.
    func isSameInstance(afterPiTitleRewrite original: Self) -> Bool {
        pid == original.pid && parentPID == original.parentPID && startSeconds == original.startSeconds &&
        startMicroseconds == original.startMicroseconds && executable == original.executable && cwd == original.cwd &&
        arguments.count == original.arguments.count && arguments.first == "pi" && arguments.dropFirst().allSatisfy(\.isEmpty)
    }

    func matches(node: String, entry: String, tail: [String], cwd: String) -> Bool {
        executable == Self.canonical(node) && self.cwd == Self.canonical(cwd) && arguments.count == tail.count + 2 &&
        arguments.first.map(Self.canonical) == Self.canonical(node) &&
        Self.canonical(arguments[1]) == Self.canonical(entry) && Array(arguments.dropFirst(2)) == tail
    }

    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    private static func info(_ pid: Int32) throws -> proc_bsdinfo {
        var value = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              value.pbi_uid == getuid(), value.pbi_status != UInt32(SZOMB) else { throw PiBridgeFailure.identity }
        return value
    }
}

nonisolated enum PiBridgeFailure: String, Error, Sendable {
    case denied, identity, invalidRequest, unavailable, conflict, expired, cleanupUnconfirmed, notBound
}
#endif
