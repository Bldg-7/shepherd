# App-owned workspace schema and CAS bookkeeping (SHPHRD-152)

This is the shared macOS/iOS model foundation, not the UI/backend cutover.
No provider account, VM, core installation, real agent, or network is required.

```sh
python3 Tests/CoreWorkspace/run-tests.py --output "$(mktemp -d /tmp/hc-workspace.XXXXXX)/run"
```

The runner builds and executes Debug and optimized Swift 6 tests, then typechecks
both production files for iOS. It preserves source hashes and stage/cleanup logs.

Current validation: **88 codec/edit/CAS + 32 RPC-owner + 52 focus/recovery/
notification + 31 lossless attach + 40 gateway policy checks per build mode**
(243/mode), plus iOS17 Swift6 typechecking (21 stages). Evidence:
`/private/tmp/hc-gateway-store.I0YyAc/run`.

[Gateway routing/storage scope and limitations](GATEWAY-README.md): actual
three-private-core SDK20, known ID-shadow configuration rejection and exact CAS;
not product gateway UI, arbitrary concurrent config routing or release cutover.

The actual-screen model is now composed in `HcWorkspaceModel`; its private-core
integration checks real launch/binding, focus persistence, view-close/program
survival and disconnect cleanup (41 checks including previous storage tests).
Final real-core cleanup rerun: `/private/tmp/hc-screen-cleanup.29msb4/run`.

The real suite also retains a lost-launch orphan without label adoption or
automatic kill. The fixture's final stop verifies core, holders and recorded
program PIDs retire. Protocol regression (seven stages) passes at
`/private/tmp/hc-screen-regression.ofHCyB/protocol`; unsigned macOS/iOS builds pass
at `/private/tmp/hc-screen-final.TtxPl4/{macos,ios}.log`.
See `../HcBackend/README.md` for the separate native SwiftUI screen gate.

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

## Device focus, recovery and notification dedup

`CoreWorkspaceFocus` keeps workspace/tab/pane selection and zoom per device/window
and restores from caller-selected local storage scoped to a core ID. It is never
in the shared document, never a core focus command, seen mark or launch authority.
A remote edit does not move another device's selection; deleted panes fall back
and clear stale zoom. Unavailable (nil snapshot) retains selections; a confirmed
missing document clears them.

`CoreWorkspaceRecovery` journals non-atomic run/document and close/kill outcomes
and persists **before** any dispatch ticket is exposed. It is correlation bookkeeping,
not launch authority. A missing/failed run reply is uncertain and never re-run; only
a successful run reply supplies a known terminal reference. Close plans use canonical
generation-1 terminal IDs (names can retarget), keep shared views and mark foreign
origins for their own routing. Layout application and stop attempts are explicit
post-review steps, not automatic retries; lost doc/kill ACKs are reconciled by a
fresh read. Journal restore promotes in-flight states to uncertain and rejects wrong
origin IDs. Forgetting metadata is an explicit UI action and never kills a program.

The dispatch labels are correlation hints only — matching one label is not proof of
ownership. The real-core integration creates a lost-launch orphan for review and
never adopts or auto-kills it by label.

`CoreAttentionFeed` derives blocked/done/unexpected-working-exit candidates from
direct-origin full snapshots, with connection-epoch and sequence guards. The first
snapshot, missed snapshots and sequence gaps are baselines; restarts and incarnation
changes reset instead of replaying catch-up alerts. Candidates are confirmed against
a fresh record on the same connection before presentation, bounded to 128 pending,
and suppressed once delivered/viewed. Core's private parent `seen` is not UI seen,
and status/PID/turn never authorize input or termination.

Still to implement in C: product UI/local focus wiring, explicit rebase policy and
gateway remote-document routing (the document/feed foundations above cover the local
origin), and run/kill integration with native launch authority and the installer
(D). The three foundations here are tested in isolation and against an owned core.
