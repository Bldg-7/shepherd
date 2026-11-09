# Default source backend: hc

## Decision and boundary

The operator directed the default backend switch now, separately from final
installation/service/release qualification. Ordinary macOS **Debug and Release**
source entry is `ShepherdHcContent → HcRootView`. A missing, incompatible or failed
hc connection stays on the hc unavailable/error/help path. It never selects
`ContentView`, a legacy socket/transport, browser runtime or capture service.

This is a source/build change, **not** deployment or approval to replace the
installed app/core, restart user services, change privacy grants, or stop/relaunch
existing agents. No existing legacy program is killed or relabeled as an hc
terminal. Existing archives/settings/routes are preserved.
The legacy herdr client/transport/monitor code, its nonshipping fixture app and
the deferred browser/agent-runtime/capture-helper code were later removed from
the source tree (tag `archive/legacy-fixtures-2026-11-09` keeps the last commit
with them). Shared models, archive readers and pinned SSH remain.

## Composition

- `ShepherdApp.mainContent`: Debug/Release use `hcContent`.
- `ShepherdHcContent`: one product composition constructs `HcRootView` with the
  normal machine store. `HcMigrationHost` supplies owned test resources to the
  **same** composition, not a replacement diagnostic root.
- Startup/termination initializes the hc notification path only.
- hc detection/help/retry and explicit SSH host-key approval remain hc paths;
  failure never authorizes a legacy transport, automatic install or service stop.

The [plain CLI policy](hc-plain-cli-launch.md) still applies: no app extension,
MCP/skill/prompt/session/provider/browser-blocking injection; Codex's existing
`--no-daemon` remains an explicit process-isolation exception.

## Evidence distinctions

`Tests/HcBackend/test_ui_preservation_wiring.py` statically checks active Debug
and Release source branches. This conditional-source guard is not a substitute
for actual product builds or a runtime receipt.

`run-default-backend-tests.py` compiles the exact extracted fixture-routing
predicate in DEBUG and optimized non-DEBUG modes, with explicit stand-ins for
fixture capability inputs. It also exercises the actual product SDK owner with
transport-start failures: one attempt, closed transport, no substitute model,
no credential reads and no legacy routing. Arbitrary start errors are correctly
normalized by RPC; this fake transport is **not** a real missing-executable
lookup. The pre-transport `missingExecutable` branch and unavailable UI are
separately source-guarded.

The native runner now requires `product-root.json` from the shared composition,
with `root=HcRootView`, `composition=ShepherdHcContent`,
`sharedProductComposition=true`, `legacyFixtureRouting=false`. This proves the
owned audit exercised the same composition. It does not pretend the fixture ran
against the user's normal HOME/accounts/services. The existing native Retry
failure/reconnect checks remain required, with no fallback model/action substitute.

## Current source/build evidence

Owned batch: `/private/tmp/hc-default-root.59i7vJ/validation.json` records
`defaultSourceBackend=hc`, no legacy fallback, compiled macOS Debug/Release and
iOS Debug, **32** source-wiring guards, and **20** routing/SDK-failure checks per
DEBUG/non-DEBUG mode. `integrated` also passes the **69** renderer/parser tests,
official 0.1.17 **6/80-column** render and **16** original UI stages (launcher81).
Actual product compiler commands in `integrated/product-compile-conditions.json`
confirm DEBUG is defined for Debug and absent for Release, rather than assuming
that from the scheme names.

Native `/private/tmp/hc-screen-app.g23w03y6` passes **74** actual hc-root checks,
including original launcher/sidebar/Preview, close/end/Retry and native fullscreen
layout. Its `product-root.json` and `sharedProductComposition=true` validation
confirm the shared product composition and disabled legacy fixture routing.
Physical edge/IME/drag, direct-SSH profile rerun and whole-UI approval are not
inferred from this local fixture.

Preserved negative: `policy` compiled but its DEBUG test failed because the test
incorrectly expected a discovery `noExecutable` error to pass unchanged through
RPC's transport-error normalization. Release/later stages in that attempt did
not run. The corrected `policy-fixed` checks the actual hc failure behavior;
production RPC normalization was not weakened. Initial source-guard comment
boundary failure is also retained in `wiring-initial.log`.

Cleanup `build/cleanup/hc-default-root-cleanup.json`: **22** exact owned output/cache
roots (~**0.717 GiB** allocated), plus the native runner's two retired staged apps.
Failures/logs/hashes/private state/native geometry and current platform products
are preserved. No unrelated process, source, installed program/service or user
credential was removed or stopped.

## Follow-up Release payload retirement

[RELEASE-PAYLOAD-README.md](../Tests/HcBackend/RELEASE-PAYLOAD-README.md) records the
follow-up exclusion of CEF runtime/helpers, AgentRuntime and proxy/LaunchAgent
payloads from Release. Debug fixtures and archive codecs remain. This reduces
shipping payload, not all compiled legacy code/build dependencies, and does not
change installed services or qualify deployment/handover. The subsequent
[CEF build-input retirement](../Tests/HcBackend/BROWSER-RETIREMENT-README.md) also
removes its real implementation, headers, wrapper and credits from Release, while
keeping the actual Debug fixture and unavailable Release ABI.

## Still not release completion

Existing physical edge-hover/IME/drag, real mobile device/OS notification delivery,
remaining remote UI and actual install/update/handover/GUI-quit service survival
gates retain their status. Shared launchd service qualification needs an approved
disposable macOS namespace; private HOME alone is insufficient. Those are not
reasons to restore the legacy default source entry or add more CLI injection.

No migration result should conflate:

1. default **source** backend switched;
2. compiled Debug/Release product;
3. owned native UI/shared composition;
4. installed-user-app deployment and fully qualified release.
