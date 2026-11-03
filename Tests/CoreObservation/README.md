# Core observation parity (SHPHRD-151)

These are local process and passive-screen observation slices, **not completed
agent parity or browser admission**. The product still uses the existing backend.

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

## Passive attributed-screen slice

`CorePassiveScreenSequence` requires negotiated observer resize notifications and
an authoritative RESIZE before any DATA. Packets now carry an internal stream
identity (epoch/channel/nonce) and ordinal, including controls without CREDIT
receipts. Wrong-stream, replayed/out-of-order, zero/oversized grid and retired
packets fail closed. Limits are 2,048 per dimension and 262,144 visible cells.
These are grid limits, not a complete parser/image/scrollback memory policy.

The type emits resize/data/closed instructions only. It does not expose a
snapshot-complete, ready, empty-editor or permission flag. DATA is acknowledged
only after the renderer consumes it; all generated responses are discarded.

A **separate** pinned candidate adds existing upstream observer negotiation
(`5a9de29`) and Ghostty #14725 on top of #14711, without importing unrelated HEAD
changes. Reproduction and licensing: [backport/README.md](backport/README.md).
The prior OSC8-only artifact remains intact and is a failing passive-observer
negative control, not a fallback silently accepted by this gate.

Evidence:

- Candidate receipt: `/private/tmp/hc-parity.GSdG2o/qualified/candidate-receipt.json`.
  Binary SHA256: `155712b7609d180742e0332ee953d41c2559c8fd11de568b0803ad259d591046`.
- Formatter 321 tests; Rust VT 10; core library 95 passed/1 ignored (its isolated
  child helper also runs). All builder stages and unchanged notices pass.
- `/private/tmp/candidate-passive-final.SoWGIV/run/validation.json`: 33 native
  headless SwiftTerm checks pass. Correct initial/changed/headless grid,
  blank gaps, background-only row, dim attribute, CJK/emoji and OSC8 are retained.
  Program input stays zero; no scroll-history read or renderer reply is sent.
- `/private/tmp/baseline-passive-negative.YKeITx/run/validation.json`: original
  #14711 artifact fails with `unsupported`, resize negotiation false, exit 1;
  owned process/socket cleanup succeeds. The earlier Swift top-level-throw
  experiment was replaced with a controlled nonzero exit, not a skipped check.
- Full SSH/native SwiftTerm regression: 34 checks pass for **both** the candidate
  (`/private/tmp/candidate-full-ssh.GRvVHt/run`) and original OSC8 artifact
  (`/private/tmp/osc8-baseline-full-ssh.8gb8zK/run`). Expected resize support is
  pinned by artifact selection; the common 0.1.16 string does not select it.
- `/private/tmp/hc-passive-sequence.2kBsdn/run`: protocol seven stages pass,
  connection/stream assertions increase to 140; Swift 6 and iOS 17 typecheck.
- Candidate receipt tests: eight pass; the original artifact tests: 14 pass.
- `/private/tmp/hc-passive-build.hzsR70/{macos,ios}.log`: unsigned Debug builds pass.

The synthetic grid emits an explicit end marker for its assertions. **Real CLI
initial snapshot completion and empty-composer readiness remain unqualified.**
Neither this fixture nor a DATA boundary supplies native ownership or readiness.

## Official 0.1.17 rendering check

Both `run-passive-core-tests.py` and `../CoreProtocol/run-ssh-stream-tests.py`
accept `--official-017-archive /path/to/herdr-core-macos-aarch64.tar.gz`.
This is a separate fixed checksum, not a relaxation of the 0.1.16 control.
Actual 0.1.17 negotiates observer resize, but fails the passive gap-background
assertion; SSH initial/reconnect OSC8 is also still lost. Both gates remain
nonzero failures after owned cleanup. The retained patched candidate still
passes 33 passive and 34 SSH checks with the same harness.

Fixtures explicitly set `SSH_CONNECTION=owned-fixture-no-launchd` to exercise
owned direct/SSH startup without machine-wide launchd registration or stale-job
cleanup. This does not qualify macOS app-quit survival through launchd.

## Authorized real CLI measurements

A later explicitly authorized run starts installed Claude 2.1.317, Codex 0.166.0
and Pi 1.4.0 in private hc PTYs with OS privacy/network restrictions. Pi's TUI,
automatic idle report, resize and `/new` lifecycle are observed; its session ID
changes without changing the kernel process. Claude is blocked by network/onboarding,
and Codex by managed-preference synchronization under the restrictions (also
reproduced without hc). These are **not** all-CLI readiness passes. See
[CLI-README.md](CLI-README.md) for exact invocations, boundary limitations and
result semantics. No real credentials, parent descriptor or browser authority
are used. Existing user configuration and product backend remain unchanged.

## Still required before backend cutover

1. Connect this evidence to the new launch identity/epoch and the existing native
   bridge, without promoting OSC status, labels or displayed app names to proof.
2. Preserve managed/unmanaged CLI readiness and native session detection. Real
   CLI startup/lifecycle measurements are now separate in [CLI-README.md](CLI-README.md);
   no account login or model prompt was used, and authenticated readiness remains unqualified.
3. Qualify passive attributed-screen observation, initial snapshot completion and
   resize ordering. Official 0.1.16 does not negotiate observer resize frames;
   cross-channel size events or an arbitrary DATA boundary are not such proof.
4. Extend the candidate's tested geometry/attribute behavior to actual supported
   CLI renderings and bound parser/image/scrollback resources. Candidate tests
   are not proof of arbitrary agent compatibility.
5. Preserve remote inspection, safe rename/resume and non-invasive mobile output;
   do not replace missing capabilities with synthetic `interactiveReady=true`.
