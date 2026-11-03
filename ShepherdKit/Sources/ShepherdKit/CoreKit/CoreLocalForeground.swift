#if os(macOS)
import Darwin

/// Kernel lifetime metadata, not argv, environment, credentials or a browser
/// authorization. An exec can preserve PID/start time; native exec/exit watchers
/// and exact launch/peer/session checks are still required for authority.
public nonisolated struct CoreLocalProcessStamp: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
}

/// Anchor for one nominated local controlling-terminal session. Not Codable and
/// no public memberwise initializer: core/OSC/label JSON cannot manufacture it.
/// Only use with a separately verified This Mac endpoint, never a remote PID.
public nonisolated struct CoreLocalTerminalAnchor: Equatable, Sendable {
    public let program: CoreLocalProcessStamp
    public let sessionID: Int32
    public let ttyDevice: UInt32
}

/// A bounded, double-checked observation, not an atomic kernel transaction or a
/// lease. Callers must invalidate it on disconnect/loss/restart and revalidate
/// immediately before binding. No shell/readiness inference is made from PID.
public nonisolated struct CoreLocalForegroundSnapshot: Sendable {
    public let anchor: CoreLocalTerminalAnchor
    public let processGroupID: Int32
    public let members: [CoreLocalProcessStamp]
    public let sampledAt: ContinuousClock.Instant

    /// Deliberately not named isShellForeground: the anchor might have exec'd
    /// another program without changing its PID/start time.
    public var isAnchorOnlyForeground: Bool {
        members.count == 1 && members[0] == anchor.program
    }
}

public nonisolated enum CoreLocalForegroundFailure: String, Error, Sendable {
    case invalidPID, invalidLimit, unavailable, notLocalTerminal, changed, limitExceeded
}

/// Unlike hc's single foreground leader, observes every member of the exact
/// kernel foreground process group. Never scans argv/environments or all PIDs,
/// opens a tty, changes job control, sends signals, or launches a command.
public nonisolated enum CoreLocalForeground {
    public static let maximumMembers = 256

    public static func anchor(programPID: Int32) throws -> CoreLocalTerminalAnchor {
        let first = try sample(programPID)
        guard first.sessionID == programPID, first.groupID == programPID else {
            throw CoreLocalForegroundFailure.notLocalTerminal
        }
        guard try sample(programPID) == first else { throw CoreLocalForegroundFailure.changed }
        return .init(program: first.stamp, sessionID: first.sessionID, ttyDevice: first.device)
    }

    public static func snapshot(for anchor: CoreLocalTerminalAnchor, memberLimit: Int = maximumMembers) throws -> CoreLocalForegroundSnapshot {
        guard (1...maximumMembers).contains(memberLimit) else { throw CoreLocalForegroundFailure.invalidLimit }
        let started = ContinuousClock.now
        let first = try sample(anchor.program.pid)
        guard first.stamp == anchor.program, first.sessionID == anchor.sessionID,
              first.device == anchor.ttyDevice, first.groupID == anchor.program.pid else {
            throw CoreLocalForegroundFailure.changed
        }
        let group = first.foregroundID
        let pids = try members(group: group, limit: memberLimit)
        var observations: [Sample] = []
        for pid in pids {
            let item = try sample(pid)
            guard item.sessionID == anchor.sessionID, item.device == anchor.ttyDevice,
                  item.groupID == group, item.foregroundID == group else {
                throw CoreLocalForegroundFailure.changed
            }
            observations.append(item)
        }
        // Refuse churn/truncation rather than publishing a partial candidate set.
        guard try members(group: group, limit: memberLimit) == pids else { throw CoreLocalForegroundFailure.changed }
        for item in observations {
            guard try sample(item.stamp.pid) == item else { throw CoreLocalForegroundFailure.changed }
        }
        guard try sample(anchor.program.pid) == first,
              started.duration(to: .now) <= .milliseconds(250) else { throw CoreLocalForegroundFailure.changed }
        return .init(anchor: anchor, processGroupID: group, members: observations.map(\.stamp), sampledAt: .now)
    }

    private struct Sample: Equatable {
        let stamp: CoreLocalProcessStamp
        let sessionID: Int32
        let device: UInt32
        let groupID: Int32
        let foregroundID: Int32
    }

    private static func sample(_ pid: Int32) throws -> Sample {
        guard pid > 1 else { throw CoreLocalForegroundFailure.invalidPID }
        let before = try info(pid)
        let session = getsid(pid)
        let after = try info(pid)
        guard session > 1,
              before.pbi_start_tvsec == after.pbi_start_tvsec,
              before.pbi_start_tvusec == after.pbi_start_tvusec,
              before.pbi_ppid == after.pbi_ppid,
              before.pbi_pgid == after.pbi_pgid, before.e_tdev == after.e_tdev,
              before.e_tpgid == after.e_tpgid else { throw CoreLocalForegroundFailure.changed }
        guard after.pbi_flags & UInt32(PROC_FLAG_CTTY) != 0, after.e_tdev != UInt32.max,
              after.pbi_pgid > 1, after.pbi_pgid <= UInt32(Int32.max),
              after.e_tpgid > 1, after.e_tpgid <= UInt32(Int32.max),
              after.pbi_ppid <= UInt32(Int32.max) else { throw CoreLocalForegroundFailure.notLocalTerminal }
        return .init(stamp: .init(pid: pid, parentPID: Int32(after.pbi_ppid),
                                 startSeconds: after.pbi_start_tvsec, startMicroseconds: after.pbi_start_tvusec),
                     sessionID: session, device: after.e_tdev, groupID: Int32(after.pbi_pgid), foregroundID: Int32(after.e_tpgid))
    }

    private static func info(_ pid: Int32) throws -> proc_bsdinfo {
        var value = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              value.pbi_pid == UInt32(pid), value.pbi_uid == getuid(), value.pbi_ruid == getuid(), value.pbi_svuid == getuid(),
              value.pbi_status != UInt32(SZOMB), value.pbi_flags & UInt32(PROC_FLAG_INEXIT) == 0 else {
            throw CoreLocalForegroundFailure.unavailable
        }
        return value
    }

    private static func members(group: Int32, limit: Int) throws -> [Int32] {
        // One extra slot detects an exactly-full or larger group. Never size an
        // allocation from a changing process count supplied by the kernel.
        var pids = [Int32](repeating: 0, count: limit + 1)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.stride)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, capacity) }
        guard bytes > 0, bytes % Int32(MemoryLayout<Int32>.stride) == 0 else { throw CoreLocalForegroundFailure.unavailable }
        guard bytes < capacity else { throw CoreLocalForegroundFailure.limitExceeded }
        let result = Array(pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride)).sorted()
        guard result.allSatisfy({ $0 > 1 }), Set(result).count == result.count else { throw CoreLocalForegroundFailure.changed }
        return result
    }
}
#endif
