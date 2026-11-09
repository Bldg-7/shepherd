# Fixed hc code/build cleanup boundary

**Completed:** all three agreed code/build cleanup exit criteria are satisfied.
The ordinary backend remains hc. No additional code-cleanup prerequisite is
left behind by this batch; separately declared deployment/physical qualification
is not represented as completed.

The agreed exit criteria are **only** (1) remove executable legacy client and
transport from the normal SDK, preserving necessary shared code/data; (2) fully
separate historical fixtures from ordinary product configurations/actions;
(3) verify residual references and regressions. This is not a new feature plan.
Installation/handover, signing/notarization and physical/device/OS-delivery
qualification were separately declared before this batch and are not silently
included in a code-cleanup verdict.

> **Later change.** The fixture partition described in this batch no longer
> exists: the `Shepherd Legacy Fixtures` app/scheme, the `ShepherdLegacyFixtures`
> SDK target and `legacy-fixture-sources.json` were deleted along with the legacy
> herdr sources, the CEF browser, the Node agent runtime and the app-side capture
> service. Sections 1 and 2 describe the current boundary; the evidence sections
> below are this batch's historical receipts.

## 1. SDK

`ShepherdKit/Package.swift` has one target. The old typed RPC client,
socket/SSH transports, request/subscription wire types, monitor/scheduler,
machine setup and legacy terminal attach are deleted, not partitioned.
`product_build_policy.check_sdk_boundary` rejects a reintroduced fixture
target/source set, and the archive gate's executable-legacy symbol check runs on
the Release `ShepherdKit.o`.

Shared presentation/persistence models, bounded archive line protocols/readers,
pinned SSH credentials/keys, local command execution, shell quoting, notifications,
and crypto stay in the normal SDK intentionally. Their historical folder/type
names are **not** unfinished executable-backend retirement. Existing captured
history/cache/configuration/data is not deleted. Shared model initializers and
resource access have explicit public module boundaries, with unchanged values.

The terminal's existing selection-preserving renderer protocol/conformance is
shared independently of the historical terminal view model. hc uses the same
native terminal implementation, not a substituted renderer or new UI.

## 2. Native products

| Product | SDK | Build behavior |
| --- | --- | --- |
| `Shepherd` | `ShepherdKit` | hc only for Debug/Release run/test/build/archive |
| `Shepherd Mobile` | `ShepherdKit` | hc screen/input/cache/pairing/archive history |

The project has only these two targets and their two schemes. The macOS app has
no Copy Files phase or Node/credits resource references, and does not link the
browser-only X509/NIOSSL/HTTP/WebSocket products.

`product_build_policy.py` fails closed when another target or scheme, a target
dependency, a retired package product, a CEF/fixture build setting, a Copy Files
phase or a retired resource payload comes back. `hc_release_bundle.py` rejects
retired payloads, CEF and executable-legacy SDK symbols; the exact archive gate
(`Tests/Notices/run-notices-tests.py --profile hc --app --products`) additionally
checks real object/link inputs, retired built products, dSYM/UUID and licenses.

## Evidence and boundaries

Owned evidence: `/private/tmp/hc-final-cleanup.i1ammkzh`.

- Fresh unsigned arm64/x86_64 Release archives build from a source projection
  **without Vendor/CEF**, both with the preserved working project and with the
  HEAD-only owned project patch, excluding unrelated project edits.
- Exact links, nonempty real objects, per-slice SDK source lists, unavailable
  browser objects, payloads, licenses, dSYMs and UUIDs pass. A separate unsigned
  copied export with a changed UUID is rejected; exact original bytes restored
  pass. No post-build stripping or package/plugin-sandbox relaxation.
- A real pre-partition SDK object is rejected by the executable-legacy symbol
  gate. The normal SDK object is accepted. This complements, not replaces,
  source/object/link proof.
- Fresh normal Debug, generic Release **build** and iOS Debug/Release pass with no
  fixture/forwarder target in their actual build graphs. The explicit fixture
  application and its real historical SDK/CEF/helper compile separately.
- Normal Debug auditing checks both Xcode's launcher and `.debug.dylib` image.
  A strict Release-image audit initially rejected the Debug launcher for lacking
  a direct Sparkle load command. Release validation was **not** relaxed; a
  separate Debug-image inspector verifies the actual implementation and loader.
- Product policy: 14 methods with negative subcases; bundle/notice policy:
  12 methods; notice content: 7 methods. The unavailable ABI has 10 native checks
  in each of Release, DEBUG=0 and ordinary DEBUG=1, with CEF reads/network denied.
- Actual shared-product native UI: `/private/tmp/hc-screen-app.z12pmaut`, 74 checks,
  `HcRootView` / `ShepherdHcContent`, legacy fixture routing false, native fullscreen
  layout/exit restored, owned processes/socket retired. The first attempt
  `.6yy2ifjp` failed owned foreground readiness and was retired, not counted as a
  pass. The successful run observed foreground naturally and dispatched no
  wrapper activation/control events; `UI_RUNNING_NO_INPUT` was respected.

The per-component regression receipts remain separate from native UI, real core,
SSH and OS delivery evidence. Physical IME/drag/edge-hover, real mobile hardware,
notification permission/delivery and deployed service survival are **not** inferred.
The known official-core OSC8/routing boundaries are not replaced with a legacy
fallback or disguised as another code-cleanup work item.

## Final regression completion

The 19 fixed-scope component gates plus the product-backed pinned-SSH lifecycle
regression pass after preserving the initial failures. `regression/results.json`
retains the first run (16/19); `regression-followup` records the corrected
notification/mobile invocations. Their first exit-2 results were wrapper argument
errors, not executed/passing tests. The successful Preview receipt is
`preview-native-wheel-fixed-api/validation.json`; pinned SSH is
`/private/tmp/hc-fssh.1d3es9jq/run/validation.json`.

The Preview failure was reproduced with the same view remaining mounted: after
Reload the viewport went from 2500 to 960 (linked line 40). The old fixture moved
`NSClipView.bounds` directly, bypassing SwiftUI's input ownership while leaving
its initial `scrollTo(line:)` target latched. It now dispatches one native pixel
wheel event to the exact owned scroll view. All original position/line/view
identity assertions remain; **198** actual panel checks pass, including Reload,
find, retained pane/source/selection, clamping and error/Retry. No production
Preview behavior or assertion tolerance was changed. Derived observer copies
still require exact reviewed hashes, inverse-byte equality and a negative inverse
mutation control. API-rename/fixture-hash preparation failures remain recorded.
This is component event handling, not physical trackpad or system-pointer proof.

The first deeply nested SSH output namespace failed its private core hello;
that failure is retained. The bounded short owned Unix namespace passes actual
product SDK/pinned loopback SSH and confirms credential removal, process exit
and socket retirement. No pinning, network policy, credential isolation or core
version was relaxed. This does not qualify production launchd or provider login.

The payload-only receipt's broad historical `legacyCodeDependenciesRetired=false`
field is not a whole-source verdict: shared format models are intentionally
retained. The combined source-list/object/link/graph and regression evidence,
not a payload-only flag or stripped final binary, defines this cleanup boundary.

## Cleanup

After every build/test/owned core/UI process retired, cleanup removed **217**
exact owned superseded copies, test executables, caches and consumed fixture/old
SDK baselines, about **9.746 GiB** allocated. The final HEAD-only universal archive,
exact matching source/link/object/dSYM baseline, current normal Debug/iOS products,
raw VT/logs, screenshots/geometry, source/contract hashes and all positive/failed
receipts remain. Receipt: `build/cleanup/hc-final-code-build-cleanup.json`.

A read-only preflight initially encountered the Preview reader's deliberate FIFO
negative controls. No deletion had begun. Only the owned inventory worker was
retired; the scanner now lstat-skips every nonregular file before opening a
Mach-O candidate. No FIFO type/permission or user program was changed. The initial
timeout, owned-worker retirement and corrected cleanup receipts are preserved.

The final unsigned universal app is approximately **31.7 MiB** allocated, down
from the preceding CEF-only retirement's ~42.4 MiB. Neither is compressed download
size, runtime memory, signing or deployment evidence.

## Project ownership

`project.before.pbxproj`, `project.head.pbxproj`, exact owned operations,
`project.index.pbxproj` and `project-preservation.json` prove byte-preservation
of unrelated working changes. Only the owned HEAD-based patch is staged. Added
fixture configuration is derived from HEAD, not copied from the user's dirty
configuration. No installed user app/core/service, credential, privacy grant,
archive, branch or user worktree is retired for this split.
