# Real CLI startup and lifecycle measurements (SHPHRD-151)

These tests require explicit authorization to start installed CLIs. They use
fresh disposable homes and a pinned private hc, not user sessions or accounts.
**A completed capture is not authenticated readiness or full agent parity.**
No model prompt, provider login, terms acceptance, browser connection or credential
grant is performed. Pi's documented local `/new` command is the only submitted
slash command; it is not a model prompt.

## Reproduce

On macOS ARM64, after building current Debug products and the passive candidate:

```sh
ROOT=$(mktemp -d /tmp/hc-cli.XXXXXX)
python3 Tests/CoreObservation/run-cli-inventory.py --output "$ROOT/inventory"
python3 Tests/CoreObservation/run-cli-startup-capture.py \
  --inventory "$ROOT/inventory" \
  --candidate-receipt /absolute/private/candidate-receipt.json \
  --products build/DerivedData/Build/Products/Debug \
  --output "$ROOT/startup"
python3 Tests/CoreObservation/run-cli-direct-control.py \
  --inventory "$ROOT/inventory" --output "$ROOT/control"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Tests/CoreObservation -p test_cli_isolation.py
```

The inventory resolves actual executable paths, records binary/entrypoint and
package-manifest hashes, and checks real `--version` and `--help` under the OS
boundary. It does not install/update a CLI. Package manifests and entrypoints
are provenance, not a signature or a complete hash of every dependency file.
Only run inventories produced in your trusted local environment.

The startup runner captures actual core DATA through the headless SwiftTerm
replica, uses negotiated resize frames, and records kernel process observations,
selected status events, the screen and raw VT. Screen text renders NUL/empty cells
as spaces for readability; raw VT is retained unchanged. A six-second measurement
window is **not** treated as a readiness or snapshot-completion barrier.

## Privacy and process boundary

- Every child gets an explicit environment: private HOME, TMP/XDG, CLAUDE_CONFIG_DIR,
  CODEX_HOME, PI_CODING_AGENT_DIR and session directory. No parent descriptor,
  provider credential, proxy variable, NODE_OPTIONS or parent Pi session is copied.
- The OS sandbox permits code/runtime reads and scratch writes, denies external
  networking, Mach service lookup (including keychain/pasteboard brokers), process
  argument/environment sysctls and unrelated process inspection/signals.
- Before real CLI execution, inert canaries prove private reads work, outside
  regular-file reads/writes fail, and a connection to an owned loopback listener
  is refused. No real credential file is probed.
- A single policy is inherited by the controller, hc and its CLI children. macOS
  refuses applying a *different* sandbox policy inside the existing one. The
  initial nested-policy attempt therefore stopped before the CLIs entered; it
  is not counted as a startup pass.
- The shared core policy permits private core Unix sockets, same-sandbox process
  control and PTY allocation. Allocating unknown future PTYs requires a `/dev/ptmx`
  and tty-device allowance. The fixture writes only its owned stream/master; this
  is **not a claim of full isolation from every same-user tty device or hostile
  binary**, nor a replacement for a dedicated VM in stronger threat models.
- Literal code ancestors permit path traversal/directory metadata, not arbitrary
  personal file contents. Existing user CLI settings, extensions, project trust,
  model choices and authentication stores are neither copied nor modified.
- Claude's `CLAUDE_CODE_TMPDIR` is set inside its owned home; the fixture never
  permits writing the user's shared `/tmp/claude-<uid>` cache.
- Absent `/etc/codex` policy lookups may return ENOENT. The sandbox still rejects
  existing regular policy files and symlink targets; an inert-file test verifies
  EPERM/ENOENT/EPERM. No enterprise policy is read, replaced or bypassed. Managed
  preference broker access remains denied.
- Terminal query responses from the passive replica are discarded. Cancellation
  uses only the owned active stream. An unresponsive onboarding CLI is ended by
  `terminal.kill` on its explicitly created private terminal, recorded separately
  from natural quit; the user's existing core and unrelated process groups are never targeted.

## Invocation distinctions

- **Claude clean:** fresh settings sources, no MCP servers, no tools/skills or
  Chrome integration, new session ID. This is not the user's normal configured CLI.
- **Claude bare:** additionally uses the documented `--bare` option, which skips
  keychain reads and other integrations. A bare-mode result does not qualify
  managed hooks or the ordinary launch path.
- **Codex:** `--no-daemon --sandbox read-only --strict-config`. Installed 0.166.0
  has a shared-background-server mode; this test explicitly avoids attaching to it.
  It does not qualify the shared-daemon launch mode.
- **Pi:** offline TUI, no user resources/MCP/tools/context, fresh session ID. A
  private explicit extension records only lifecycle metadata (PID, mode, ID/path,
  cwd and model-object presence). It never reads a transcript or credentials and
  registers no browser/MCP server. Unexpected ordinary input is consumed and
  recorded as a failing test condition rather than sent to a model.

The Pi observer is instrumentation, **not a managed 3rdr launch or authority
provider**. Native bridge admission, exact saved-session resume, child rewriting
and headless execution remain separate capabilities. No parent descriptor is
borrowed to simulate those capabilities.

## Observed versions and outcomes

| CLI | Version | Observation under these limits | Qualification |
|---|---|---|---|
| Claude clean | 2.1.317 | Startup banner, then cannot reach Anthropic services; exit 1 | Network-denied negative case, not ready |
| Claude bare | 2.1.317 | Theme/onboarding UI and resize render; no usable core status | Not ready; fixture terminal kill required after cancel keys |
| Codex | 0.166.0 | Stops at `Failed to synchronize managed preferences` | Privacy-boundary limitation, not ready |
| Pi | 1.4.0 | TUI/resize and automatic OSC 7501 `idle`; no usable models/accounts | Startup/lifecycle observation only |

The direct owned-PTY Codex control reproduces the same managed-preferences failure
**without hc**. This is not evidence of an hc rendering regression. Restrictions
were not relaxed to make the CLI appear ready.

Pi's real lifecycle emitted initial `session_start`, `session_before_switch`, old
`session_shutdown` and a new `session_start` for `/new`. The ID changed while the
kernel process instance and hc terminal stayed the same. Core's `idle` status did
not identify that session change. Thus terminal ID, PID/start time or idle state
cannot preserve an earlier native/browser lease across a switch.

A model object can be present in the extension context while the TUI says no models
are available. `modelObjectPresent` is deliberately **not** called authenticated
model availability. No MCP/browser admission is inferred from any observed event.

## Recorded evidence

Final current-source run: `/private/tmp/hc-cli-final.m6lBLZ/` (local temporary
artifacts, not durable download URLs).

- `inventory/validation.json`: six real version/help probes pass; file/network
  canaries pass; missing-policy guard returns EPERM/ENOENT/EPERM.
- `startup/validation.json`: `captureCompleted`, `observationsUsable` and
  `piLifecycleSmokePassed` are true; full agent parity remains false.
- `startup/report.json`, per-case screen files and `.vt` files retain observations.
  `startup/pi/lifecycle.jsonl` contains only test-owned lifecycle metadata.
- `control/validation.json`: Codex shows the same managed-preferences failure
  without hc, exit 1, no forced signal and child reaped.
- All owned hc/holder/CLI PIDs and sockets retired. Claude bare specifically
  needed its own `terminal.kill`; do not describe it as a graceful CLI quit.
- The Swift harness compiles and runs in Swift 6 with the package's isolation
  flags. The test-only TypeScript observer has no LSP diagnostics and runs in the
  actual Pi 1.4.0 process. Nine pure isolation-construction tests pass.
- Source, executable/entrypoint, package-manifest, product and profile hashes are
  retained by the runners. No compiled CLI/core executable is committed.

Earlier boundary-construction and nested-sandbox failures were retained and do
not count as successful CLI starts. The final harness checks the boundary before
execution rather than weakening assertions or declaring those failures passed.

## Result semantics and remaining gate

`captureCompleted` and `observationsUsable` describe measurement and cleanup.
`piLifecycleSmokePassed` requires actual expected-image observation, TUI session
metadata, an ID change, old-session shutdown, unchanged kernel instance, and no
unexpected ordinary input. It still does not authenticate a production session.
`fullAgentParityQualified`, `providerAuthenticationQualified`,
`interactiveReadyQualified`, and `browserAuthorityGranted` remain false.

The real CLI versions differ from earlier Claude 2.1.288 / Codex 0.154.0 evidence.
Do not silently carry old UI/empty-editor/resume or process-layout assumptions
forward. Authenticated readiness, working/blocked/done transitions, safe rename /
resume and production native bridge ownership still need separately authorized
qualification. Do not use the onboarding UI, a quiet frame or Pi's idle state to
manufacture a pass.
