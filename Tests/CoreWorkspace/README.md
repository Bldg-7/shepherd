# App-owned workspace schema and CAS bookkeeping (SHPHRD-152)

This is the shared macOS/iOS model foundation, not the UI/backend cutover.
No provider account, VM, core installation, real agent, or network is required.

```sh
python3 Tests/CoreWorkspace/run-tests.py --output "$(mktemp -d /tmp/hc-workspace.XXXXXX)/run"
```

The runner builds and executes Debug and optimized Swift 6 tests, then typechecks
both production files for iOS. It preserves source hashes and stage/cleanup logs.

The pure suite passes **62 checks in each build mode**, plus iOS Swift 6
typechecking. Final evidence: `/private/tmp/hc-workspace-final.gZVGU2/unit`.
The same directory's `real` gate passes 11 checks with official hc 0.1.17 and
confirms both connect children/core/socket cleanup. `macos.log` and `ios.log`
record passing unsigned app builds. Protocol regression: seven stages at
`/private/tmp/hc-workspace-protocol.VCkHPv/run`.

The document preflight and typed decoder consume the same normalized JSON object;
they cannot disagree about which repeated-key value to validate and persist.
This normalization never touches the separate typed UInt64 CAS version.

## Owned real-core integration

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Tests/CoreProtocol/run-real-core-tests.py \
  --workspace-tests \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-workspace-real.XXXXXX)/run"
```

Two clients subscribe before reading the private core's document, race the same
CAS baseline, refetch the winner, and observe doc notifications. The fixture
intentionally discards a success reply to exercise uncertain-outcome reconciliation
without replay (not a simulated network failure), then verifies a deletion keeps
its CAS version for recreation. It launches no terminal program and never writes
to another app's document or the user's core. This test uses direct startup with
`SSH_CONNECTION=owned-fixture-no-launchd`, not machine-wide launchd registration.

## Document

`CoreWorkspaceDocument` owns only `3rdr-workspace-v1`, never the official app's
layout namespace or legacy data. UUID workspace/tab/pane IDs, binary split trees,
display names and optional cwd/terminal references are shared. Focus, zoom,
routing aliases, session leases and credentials are not shared fields.

A reference is `(origin core ID, origin terminal ID)`, not a remote machine alias
or a browser/process authorization. Multiple distinct panes may view the same
terminal. An unbound pane is a placeholder, not a request to launch a program.

The public document codec rejects unsupported schemas and unknown nested fields
rather than silently dropping them on the next save. It bounds bytes (1 MiB),
layout depth (32), items (4096), names/paths and reference strings. UUID uniqueness
is checked across the whole document. Ratios must be finite and strictly between
zero and one. Both local construction and persisted decoding validate these rules.

## CAS admission reducer

`CoreWorkspaceCAS` contains no I/O, retries, launch/kill operations or UI focus.
The eventual connection owner serializes calls to it and performs the actual RPC.

- Match the origin core ID and connection epoch, then subscribe before a read. No snapshot means unavailable, not an empty layout.
- A successful read of null is a confirmed missing document with its actual CAS
  version. It permits an explicit create, never an automatic overwrite on error.
- Events/missed/reconnect invalidate the read ticket; old replies cannot clear
  a newer invalidation. A cached layout remains read-only on errors/reconnect.
- Only one write is admitted from a fresh baseline. CAS versions remain UInt64,
  including values above Double's exact range.
- Success, conflict and uncertain outcome all require a fresh read. An ACK or
  conflict advances the minimum known version, preventing a stale read from
  undoing that evidence. No write is blindly retried or rebased.
- A lost reply is uncertain, not a confirmed failure. A new connection retires
  old read/write tokens and requires a new subscription before refreshing.
- Same-version/different-content and regressed snapshots fail closed. Recovering
  an actual server state rollback requires a separate explicit product decision.

Still to implement in C: RPC/event subscription owner, editing/rebase operations,
device-local focus, run/document and close/kill partial-success reconciliation,
and seen/notification dedup. Native launch authority and installer UI remain D.
