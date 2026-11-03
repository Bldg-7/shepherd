# App-owned workspace schema and CAS bookkeeping (SHPHRD-152)

This is the shared macOS/iOS model foundation, not the UI/backend cutover.
No provider account, VM, core installation, real agent, or network is required.

```sh
python3 Tests/CoreWorkspace/run-tests.py --output "$(mktemp -d /tmp/hc-workspace.XXXXXX)/run"
```

The runner builds and executes Debug and optimized Swift 6 tests, then typechecks
both production files for iOS. It preserves source hashes and stage/cleanup logs.

Current validation: **88 codec/edit/CAS checks and 32 RPC-owner checks in each
build mode**, plus iOS Swift 6 typechecking (nine stages).
Evidence: `/private/tmp/hc-owner-final.7YBFUc/unit`.
The same directory's `real` gate passes 23 checks against official hc 0.1.17,
including the production store, automatic cross-client refresh and layout edits.
Both connect children/core/socket retire. Protocol regression: seven stages at
`/private/tmp/hc-owner-protocol.8akAt8/run`. Unsigned macOS/iOS app builds pass
at `/private/tmp/hc-owner-build.OSQg6g/{macos,ios}.log`.

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

## RPC/event owner and explicit edits

`CoreWorkspaceStore` owns one unfiltered event subscription on an already
negotiated **direct origin connection** (local or direct SSH). It does not own the
core/connection, use gateway `on` aliases, or grant any process/browser authority.
It subscribes before `doc.get`, decodes the outer UInt64 version separately from
the strict layout codec, and consumes/acknowledges bounded event lines.

Doc changes, missed snapshots and sequence gaps invalidate a pending read and
schedule a coalesced read. Document event versions establish a minimum read
version. Old events covered by a missed snapshot are ignored per the protocol;
remote-machine or other-namespace doc events do not become local documents.
At most one refresh job and three read attempts run per batch. Errors leave the
cached view read-only, with a public error kind rather than raw server messages.

`commit` and `edit` require the exact version the caller edited. A newer background
refresh never authorizes an older proposed replacement. Writes are sent once;
conflicts, timeouts/cancellation and unexpected ACKs require a read, not replay.
An invalid stream or a 45-second event/heartbeat stall retires the store.
Reconnect creates a new store; old views and
subscriptions cannot become writable again.

Full-view UI subscriptions use newest-one buffering with at most eight observers.
Explicit close awaits shared cleanup, cancels background reads, and closes only
its event stream. Late canceled opens remain under the connection's existing
orphan-stream cleanup. Closing a view does not prove that an in-flight remote
mutation was canceled or that its shared connection/core has stopped.

`CoreWorkspaceEdit` supports workspace/tab additions and renames, tab removal,
pane split/removal (including split collapse), and expected-reference binding.
All edits return a newly validated immutable document. Removal is **layout-only**:
it never kills a terminal or changes device-local focus. No automatic rebase.

The in-memory framed peer tests the production owner through real RPC routing:
subscribe-before-read, held/stale reads, missed events, read failures, malformed
schema/events, a dropped write ACK, no mutation replay, stale caller versions,
bounded subscribers and close/late-response behavior. The owned-core integration
also exercises the production owner and automatic cross-client event refresh.

Still to implement in C: product UI/local focus, explicit rebase policy,
gateway remote-document routing, run/document and close/kill partial-success
reconciliation, and seen/notification dedup. Native launch authority and installer
UI remain D.
