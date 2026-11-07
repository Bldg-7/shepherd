# Plain launcher / deferred-integration separation

Policy: [hc-plain-cli-launch.md](../../docs/hc-plain-cli-launch.md).
This is a source/product-composition simplification, not default-root cutover or
legacy backend retirement.

## Current evidence

Owned output root: `/private/tmp/hc-plain-cli.TzgCvk`.

- `launcher`: complete `NewTabLauncher`, Swift 6/MainActor, **81 checks** using
  actual AppKit key-downs in never-shown windows. Ordinary argv mapping,
  canonical program offers, Tab/Shift-Tab, text/composition preservation,
  pending Return, nested targets, Shell-only inspection and live offer withdrawal
  pass. No installed CLI/provider/account is run.
- `integrated`: first platform/UI pass before the final ordinary machine-update
  and paired-device capture-control gates. Kept as that exact earlier result.
- `integrated-final`: current macOS Debug/Release and iOS Simulator Debug builds;
  vendored-renderer provenance and **69** renderer/parser tests; official 0.1.17
  real-core **6/80-column** rendering; **16** original UI stages (including the
  new 81-check launcher) and **27** source-wiring tests. Bounded stage receipts
  record natural exit, verified retirement and no runner signals. Real-core
  validation records its owned core/process/socket retirement.
- `pairing`: **279** Mac pairing, **11** SSH probe and **115** Settings component
  checks. Loopback-only sandbox; no real SSH, Keychain, user HOME, user defaults
  or visible app windows. The retained capture controls are exercised with a
  fake service; production Settings passes no service when integrations are
  unavailable. Those fixture controls are not proof of product capture support.
- `pairing-retirement`: the same unchanged binaries consumed again with fresh
  private fixtures and bounded process-group receipts for all three tests. Natural
  exit/verified child retirement/no runner signals pass; the original runner's
  successful result alone was not relabeled as a bounded retirement receipt.

The source-wiring guards cover the common `launchTab` path, lack of managed-browser
checks in the launcher, inspection rejection before metadata, no deferred-service
startup, no ordinary legacy browser/runtime update, and separation of pairing and
Terminal File Drop from deferred capture/browser settings.

Cleanup: `build/cleanup/hc-plain-cli-cleanup.json` records **38** exact owned
product/cache removals (~**1.112 GiB** allocated), after test/core/socket retirement
and no active builders. An unrelated cargo build observed during checks exited
naturally before cleanup; it was not stopped. Logs, source hashes, source,
private fixture evidence and current app/platform products remain available.

## Boundaries

- At this batch the default product root was still legacy. A subsequent
  [source-entry switch](../../docs/hc-default-backend-cutover.md) selects hc for
  ordinary Debug/Release. Installed app/core/services were not replaced or restarted. Existing capture archives/routes/settings and user
  programs are untouched.
- The sole added ordinary-CLI option remains Codex `--no-daemon`, explicitly kept
  for process isolation until actual shared-daemon ownership/lifecycle evidence.
- No Pi extension, skill, prompt, MCP, session ID/directory, provider override,
  browser blocking, user-command rewrite or hidden equivalent is added to hc
  execution.
- Native OSC status is not native-session or mutation authority. An actual
  foreground Pi sidebar/provider workload remains separate. Follow-up actual
  plain-Pi startup/idle through hc/product SDK/renderer/shared mapper is recorded
  in [PI-PLAIN-STATUS-README.md](../CoreObservation/PI-PLAIN-STATUS-README.md);
  that is a new scoped execution receipt, not a retroactive pass for this batch.
- No new foreground/native UI audit was run in this batch. Earlier native 78,
  physical edge-hover/IME/drag gaps, mobile runtime, OS notifications and service
  lifecycle gates keep their original scope/status.
- No packaging/target dependency removal is claimed. The retained implementations
  and fixtures are preserved; removing legacy runtime dependencies is a later
  target-composition gate, not an untested deletion in this batch.
