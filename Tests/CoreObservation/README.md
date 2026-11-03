# Core observation parity (SHPHRD-151)

This is the first local process-observation slice, **not completed agent parity
or browser admission**. The product still uses the existing backend.

```sh
python3 Tests/CoreObservation/run-tests.py --output "$(mktemp -d /tmp/hc-observation.XXXXXX)/run"
```

The runner compiles `CoreLocalForeground.swift` in Swift 6 with the package's
MainActor/default isolation and upcoming features, in Debug and optimized modes,
with warnings as errors. It also checks the iOS conditional-compilation boundary.
Runtime tests deny networking and use a newly owned PTY/session, no shell startup
files, no agent accounts, no installed core and no user process argv/environment.

## What replaces the missing local foreground list

hc 0.1.16 reports the foreground **group leader**, which is not the whole job. A
pipeline's relevant node/Pi process may be another member, and the group can
survive its leader. `CoreLocalForeground` reads only macOS kernel metadata:

- Caller explicitly nominates a local program PID; the anchor must be a same-user
  controlling-terminal session leader. Remote PIDs must never be passed here.
- The anchor contains kernel PID/start time/parent, session ID and tty device;
  core labels, status, timestamps and persistent core ID cannot manufacture it.
- `proc_listpids(PROC_PGRP_ONLY, ...)` enumerates only that tty's foreground group.
  It never enumerates all processes, reads argv/environment, opens the tty,
  sends signals or changes foreground ownership.
- Fixed bounded storage (maximum 256 members, one extra overflow slot) rejects
  truncation, duplicate PIDs, missing members and churn. Membership and each
  process fingerprint are checked again, followed by the anchor; observations
  taking over 250 ms fail rather than returning a stale partial set.
- A surviving leaderless group is valid. A nonexistent leader is never invented.
- Failure is unavailable/changed, never an empty list meaning 'shell ready'.

`isAnchorOnlyForeground` deliberately does not say 'shell': an exec can preserve
PID/start time. This is a bounded observation, not an atomic kernel transaction
or an authorization capability. It does not prove executable/argv, readiness,
native session ID, browser/MCP authentication, or credential approval. Existing
exact launch/peer/session matching and exec/exit watchers remain necessary.

On disconnect, terminal loss/restart, session switch or process replacement,
callers must retire prior admission and obtain fresh evidence. No local inspection
is offered on iOS or for a remote host. It must not silently fall back to a leader
PID or a copied OS-looking JSON record.

## Evidence

- `/private/tmp/hc-observation.r1zTVw/run/validation.json`: 27 Debug and 27
  optimized checks; five stages, all owned processes retired.
- Tests cover invalid/dead PIDs, mismatched start/session/tty, invalid quotas,
  anchor-only foreground, two-member foreground job, quota overflow, leaderless
  job, restoration, anchor exit and child reaping. The fixture controls only its
  private PTY; one explicit owned child is terminated to test leader loss.
- `/private/tmp/hc-native-ssh.WYDBW2/run/validation.json`: the real owned hc PTY
  yields a valid local anchor before attach and the same process instance after
  SSH reconnect; full SSH/SwiftTerm/OSC8 gate passes (34 checks). The SSH server
  is explicitly local and owned; this does not authorize inspecting remote PIDs.
- `/private/tmp/hc-observation-build.OFDajs/{macos,ios}.log`: unsigned Debug app
  builds pass. LSP does not support Swift in this workspace; actual compiler and
  runtime results are used instead.

## Still required before backend cutover

1. Connect this evidence to the new launch identity/epoch and the existing native
   bridge, without promoting OSC status, labels or displayed app names to proof.
2. Preserve managed/unmanaged CLI readiness and native session detection. No real
   coding-agent/provider session has been launched by this fixture.
3. Qualify passive attributed-screen observation, initial snapshot completion and
   resize ordering. Official 0.1.16 does not negotiate observer resize frames;
   cross-channel size events or an arbitrary DATA boundary are not such proof.
4. Evaluate existing upstream observer-resize support and Ghostty #14725's
   blank/background/wrap restoration in separate pinned experiments.
5. Preserve remote inspection, safe rename/resume and non-invasive mobile output;
   do not replace missing capabilities with synthetic `interactiveReady=true`.
