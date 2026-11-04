# Gateway origin routing and document SDK (SHPHRD-152)

This is scoped SDK/storage work, **not the product gateway UI/backend cutover**.
The app's selected machine/gateway UI, remote terminal dispatch, file/drop origin
providers and notification routing still need composition. No native/browser
permission is derived from core IDs, aliases, PID, labels or these snapshots.

## Official 0.1.17 observations

`run-gateway-probe.py` creates three private cores and local `--via` bridges under
fresh HOME/XDG/session/socket paths. No real SSH/provider account, installation,
launchd service, user configuration or VM is used; all owned core/holder/program/
bridge/connect PIDs and sockets must retire.

- `doc.get/set`'s `on` and qualified terminal addresses accept permanent core IDs.
  Ordinary rename and display-alias reuse do not retarget the selected core ID.
- **`terminal.list` ignores `on` and remains global.** Do not use that argument as
  an origin filter. Its records must be joined to the machine metadata in the
  **same reply**, not a later mutable alias lookup.
- **A display alias equal to another core's permanent ID can shadow that ID**
  because the resolver combines ID/name lookup in registration order. The probe
  uses reads only on the ambiguous selector and reproduces the wrong document.
- `/bin/ps` cannot execute in this seatbelt (set-id executable). The probe retains
  its network policy and instead queries only known owned parents via the public
  libproc child-PID API, with a positive own-child canary and depth/count bounds.
  No argv/environment/protected-folder scan or borrowed privilege is used.

Evidence: `/private/tmp/hg-route-shadow.AR6tN7/run/report.json` (discovery, not a
product pass). Original ps-denied attempt is retained at
`/private/tmp/hg-route.8tqjRX/run`; owned resources still retired.

## Upstream fix, not a maintained app core fork

Submitted [herdr-core #118](https://github.com/herdrdev/herdr-core/pull/118) to
resolve permanent local/machine/peer IDs before display aliases. The deciding
function takes `CoreInfo`/`State`, with platform-independent tests for precedence,
registration order and unchanged unambiguous names. The manual states precedence.

- Initial head `3fe6386` failed CI's strict clippy rule for test field assignment
  after `Default`; fixed the initializers without disabling any lint.
- Current head `02ab775f2927f63522d930c41f7988f0117195d8`:
  [full CI success](https://github.com/herdrdev/herdr-core/actions/runs/41840245216)
  (lint, upgrade, Linux/macOS/Windows and aggregate).
- Local existing Rust1.94.1 compiled the actual extracted resolver/tests with
  shape-only stubs: before 1 regression fails, after 2 pass; standalone clippy
  passes too. That is **not** a local full-crate Rust1.95/Zig qualification.
- PR is open, not merged/released. The distribution baseline remains official
  0.1.17; no toolchain was reinstalled globally or user daemon replaced.

## SDK behavior and limitations

`HcGatewaySnapshot` is a bounded, first-level, read-only directory. It preserves
observed alias-qualified records separately from `(originID, canonicalTerminalID)`
references. Deeper origins are not relabeled as their first-level parent. Unknown
origins, duplicate/invalid metadata and cross-ID alias/hostname collisions fail
closed. `CoreTerminalID` shares the existing generation-1 canonical-ID check with
recovery instead of treating arbitrary labels/base36 strings as IDs.

`CoreWorkspaceStore(... gatewayCoreID: ...)` explicitly distinguishes logical
remote document ownership from the actual hub transport epoch/hello. It:

- Checks fresh same-reply gateway metadata before initial reads, refreshes and
  mutations; no missing/ambiguous target falls back to local documents.
- Uses `on: permanentID` for doc get/set; CAS UInt64 stays an exact integer even
  above 2^53, and selector JSON is escaped independently of the layout bytes.
- Rechecks caller baseline/write/refresh state after suspended validation.
- Subscribes before reading. Alias-qualified remote doc notices conservatively
  invalidate, but **never apply another origin's event version as this origin's
  CAS floor**. Direct-hub doc notices are separate; gaps/missed still invalidate.
- Retains cached documents read-only on origin-validation failure and never
  automatically replays a rejected/uncertain mutation.

**A metadata preflight is not an atomic lease on gateway configuration.** The
0.1.17 server bug is not repaired client-side by a snapshot. Arbitrary concurrent
external reconfiguration that creates ID-shadowing aliases is **not qualified**;
there is no claim of atomic expected-origin enforcement by this API. Known
collisions are blocked, and product gateway mutation UI is not enabled by this
slice. Do not upgrade that to a guarantee or deploy an unsafe alias fallback.

## Gates

```sh
python3 -B Tests/CoreWorkspace/run-tests.py --output /absolute/fresh/unit
python3 -B Tests/CoreWorkspace/run-gateway-store-tests.py \
  --official-017-archive /absolute/official-0.1.17.tar.gz \
  --products build/DerivedData/Build/Products/Debug --output /absolute/fresh/sdk
```

- `/private/tmp/hc-gateway-store.I0YyAc/run`: **88+32+52+31+40 = 243 per mode**,
  21 stages and iOS17 Swift6 typecheck. Gateway policy tests cover namespace
  collisions, first-level projection, canonical IDs, cross-origin event version
  isolation and exact routed CAS encoding. Existing recovery behavior is retained.
- `/private/tmp/hc-gateway-sdk.ShTwhU/check`: **20 SDK checks** through the
  production framed stores/RPC with actual official private cores. Remote write
  lands only on the chosen origin; hub stays missing; a matching-version unsafe
  ID-shadow edit is rejected before either document changes; repaired config is
  read without replay; another origin's higher version does not poison selected
  CAS. Every owned connect PID is recorded before close and reaped. Controller
  owns/stops the three daemons/holders/programs/bridges; no user core is touched.
- `/private/tmp/hc-gateway-sdk.ShTwhU/{macos,ios}.log`: Debug builds pass.

These do not qualify product gateway navigation, multi-hop routing, credentials,
file upload, real-agent readiness, GUI foreground or a release cutover.
