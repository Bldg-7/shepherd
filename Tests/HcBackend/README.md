# hc backend replacement (SHPHRD-153)

The app backend moves from legacy herdr (`HerdrClient` + `herdr terminal attach`
over an SSH PTY) to hc (`CoreRPCConnection` + `terminal.attach` framed streams).
The experimental browser/`3rdr-browser` injection layer is out of scope for this
first slice; it is deferred until after the core launch path ships.

```sh
python3 Tests/HcBackend/run-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-attach.XXXXXX)/run"
```

## HcTerminalSession

`ShepherdKit/CoreKit/HcTerminalSession.swift` is the hc replacement for the
herdr `TerminalSession`. It attaches interactively (`observe=false`) to one
terminal on an already-negotiated connection and exposes:

- `start(columns:rows:)` — opens exactly one owned attach.
- `nextOutput(timeout:)` → raw DATA packet, first paint then live VT.
- `acknowledgeOutput(packet)` — only after the renderer consumes the packet.
- `write(Data)` — keys as DATA on the stream.
- `resize(columns:rows:)` — a RESIZE frame, not a shell command.
- `stop()` — a CLOSE frame; idempotent and safe before/during/after `start`.

CREDIT is returned only after the caller renders and explicitly acknowledges
each packet. **The previous AsyncStream/drop-oldest implementation was unsafe:**
dropping VT chunks can split control sequences and corrupt screen state; that is
not equivalent to evicting parsed scrollback. There is now no second output queue.
The connection enforces a single outstanding receipt and its existing byte/credit
limits. Quiet terminals have no idle timeout (the open-RPC timeout is separate).

Stop-before-start opens nothing; stop-during-open cancels the open and the
connection tracks late orphan replies. Concurrent stops share a cleanup task;
close errors propagate. The session never stops the core or program. Output is
raw `Data` in the packet; CoreKit remains Foundation-only.

## Actual hc workspace screen (staged integration, not release cutover)

`Shepherd/HcBackend/HcWorkspaceView.swift` and `HcTerminalPane.swift` render an
actual SwiftUI sidebar/split layout and the existing native SwiftTerm host.
`HcWorkspaceModel` composes the real core connection, workspace store, terminal
event subscription, device focus and persistent recovery journal. Creating a tab
saves its placeholder first, sends terminal.run once, saves the returned reference,
and binds through CAS. Unconfirmed operations remain review items, never retries
or label-based automatic adoption. Closing a view explicitly keeps programs alive.
The screen exposes plain CLI launch (shell/Claude/Codex/Pi), with no AgentRuntime,
MCP, browser/credential service or legacy HerdrClient dependency in this path.

`HcTerminalPaneModel` feeds each packet into SwiftTerm on the main actor before
returning CREDIT, does no legacy Ctrl+B translation, and serializes bounded input,
renderer responses, resize and focus. A new pane lifetime awaits old attach cleanup.

The migration host is **DEBUG-only and requires an explicit private tmp HOME**.
It bypasses AppDelegate's legacy monitor/proxy/browser startup and never chooses
a user core or persisted user browser opt-in. No release/backend preference is
added: this is a staged integration route until remote/file/install parity gates
are complete, not a permanent dual-backend design.

```sh
python3 Tests/HcBackend/run-ui-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --products build/DerivedData/Build/Products/Debug
```

The fixture stages a uniquely identified Debug bundle copy (tested executable
and debug-dylib hashes unchanged) and an owned GUI helper. The helper starts its
child with fresh env through sandbox-exec and may yield activation only to that
child; no user's app is opened/replaced. Both temporary owned registrations are
removed. The app independently checks TCP denial before starting its private
core/program. It creates/selects a tab through the product root/model, waits for
**rendered SwiftTerm cells**, verifies the app's own accessibility tree, and
captures only its own content view as `workspace.png`. NSView bitmap capture may omit layer-backed
SwiftUI content; it is not proof of sidebar pixels (accessibility is checked
separately). It stops its private core and verifies all owned
PIDs/socket retirement. Product/source hashes, exact reports and failed stages are
retained. No provider credentials, real agent prompt, global install or user app
replacement is involved. This gate is not OSC8/background qualification: official
0.1.17 still fails the separately retained attributed-rendering gates.

## What the gate proves

Against a pinned official hc 0.1.17 in an isolated home (direct startup via the
`SSH_CONNECTION=owned-fixture-no-launchd` marker, network denied, no launchd):

- attach first paint carries the program's `READY` marker;
- `write("hello\r")` reaches the program and its `GOT:hello` echo returns;
- `resize(100,30)` reaches the terminal record (`terminal.get`), not just a
  local replica;
- closing the attach leaves the program live; explicit `terminal.kill` ends it;
- every owned PID (core, holder, run) and the socket retire on stop.

This is a launch/attach path only: no browser, MCP, credential or authority is
involved, and `launchdLifecycleQualified` stays false.

### Current screen/delivery evidence

- `/private/tmp/hc-screen-final.TtxPl4/unit`: 88 codec/CAS + 32 store + 49
  focus/recovery/attention + 16 lossless-delivery checks in **each** Debug and
  optimized mode, plus iOS Swift 6 typecheck (17 stages).
- `/private/tmp/hc-screen-cleanup.29msb4/run`: 41 real-core workspace/screen-model
  checks, including tab launch/binding, focus persistence, view-close survival
  and all recorded core/holder/program PID retirement.
- `/private/tmp/hc-screen-app.4spxstrb`: eight actual-app checks, rendered-cell
  marker, sidebar/tab accessibility IDs, native terminal bitmap, natural app
  exit and private-core cleanup. Earlier AX-tree readiness failure is retained
  at `/private/tmp/hc-screen-app.kr67q2wq`, not relabeled as a pass.
- Final macOS screen build `/private/tmp/hc-screen-ax.gHcVSE/macos.log`; iOS
  `/private/tmp/hc-screen-final.TtxPl4/ios.log`.
- `/private/tmp/hc-screen-regression.ofHCyB/{attach,board,protocol}` retains
  nine attach, twelve board and seven-stage protocol regression results.

## Current foreground GUI gate is RED (not waived)

The stricter current runner additionally requires actual foreground/key-window
state and the native New Tab menu opening/canceling the human launch form.
Unattended activation is refused in this session, including the owned helper
(`helperActive=false`). Latest retained failure:
`/private/tmp/hc-screen-app.yjim7wn_` (nine renderer/file checks reached, but
**overall passed=false**). Known app/helper/core/holder/program resources and
owned registrations retired. Earlier activation failures are retained too.
No other app's focus, accessibility grants or authority are borrowed to force a
pass. A GUI environment that genuinely permits this owned foreground interaction
must pass the strict gate before window commands/release cutover are qualified.

Older 11-check UI positives below qualify their narrower source/gate only. They
are not current foreground-command qualification. Current source compilation and
fake-OS notification composition are separate evidence, not a substitute.

## hc attention, window commands and remaining cutover

`HcAttentionMonitor` admits actual event sequences one by one, baselines initial/
missed/restarted facts, confirms a candidate on the same RPC epoch after a hold,
and keeps actual viewed/unread state separate from core parent `seen`. An initial
real-core negative caught a real bug: coalescing two contiguous events into a
single sequence jump incorrectly suppressed fresh attention as a gap. The adapter
now admits both notices; genuine gaps still baseline. A missed snapshot at the
same sequence also retires pending candidates (52 lifecycle checks per mode).

`HcNotificationCoordinator` composes bounded independent hc watchers, preferences,
viewed-pane suppression, badge and withdrawal logic, and a native presenter.
Unknown SSH keys are not offered credentials by background watchers. It never
launches/kills a program or derives native/browser authority from a status word.
OS clicks are machine/core/terminal navigation data: they select an existing
fresh origin view, never launch a program or create shared layout automatically.
The coordinator watches up to 32 trusted enabled machine connections.

Actual status adapter: `/private/tmp/hc-runtime.yLDk2O/attention` (18 checks).
App composition: `/private/tmp/hc-checkpoint.1DQZrL/notifications` exercises the
actual coordinator/factory/core with an **in-memory OS presenter boundary**.
No real notifications or permission prompts are used; this is not OS-banner UI
automation or agent-readiness/authentication qualification. The unit suite at
`/private/tmp/hc-runtime.yLDk2O/unit` passes 88+32+52+31=203 checks per mode;
its protocol regression also passes all seven stages.

The staged product root now owns New Tab/Close View/Pane Switcher keyboard
commands and an explicit human launch form (workspace, name, cwd, installed CLI
or shell command). No legacy prefix translation or browser injection is used.
Default macOS root cutover, installer/update behavior, gateway-origin document
routing and final legacy removal remain incomplete; do not mark SHPHRD-153/154
Done from these component/integration gates alone. Mobile root is hc now.

Capture proxy is independent of browser retirement. Its configured lifecycle and
existing route/data are preserved. Old injected-route terminal IDs are **not**
compared against a new core to infer death/revoke credentials; no new capture
route/native-session mapping is inferred from labels or PID. New hc launch capture
and capture-history screen parity still require explicit independent integration.

Current macOS Debug/Release and iOS builds:
`/private/tmp/hc-checkpoint.1DQZrL/{macos,release,ios}.log`. The screen owner now
publishes its exact saved connection identity; the root/commands cannot present
an old live model under a newly selected machine while async teardown catches up.
Local input/drop callbacks check current UI scope too. Native composition tests
also cover identity publication/retirement; no native/browser grant is involved.

## Mobile hc root, snapshot conversation and safe input

Mobile's machine navigation now opens `HcMobileBoardView`, not the old herdr
board/cache. It uses the same product machine factory and workspace model.
`HcMobileCache` stores bounded **display-only** records/layout, scoped to the
exact saved connection. Edits/removal retire it before committing settings;
stale writers and invalid documents are rejected. A cached origin is never
retargeted for actions. No iOS local core install/execution is possible.

`HcConversationModel` reads snapshots without a terminal attach and uses hc's
explicit send/named-key APIs with fresh same-origin terminal confirmation. Input
is never replayed on failure. Generation-1 `terminal.keys` rejects arbitrary
Unicode: the initial real-core negative exposed that limitation. Type-only
Unicode now uses a short input attach at the current grid, without a focus
command, and **flushes its DATA to the transport writer before closing**. Its
unused output is credit-bounded and is not rendered as a VT screen. Control
characters are rejected for type-only input so a hidden newline cannot submit.

`CoreStream.sendAndFlush` does not mean the program processed input. Queued
cancellation/timeout removes only that frame; an in-flight frame finishes intact
and may have arrived. Normal `send` still means bounded writer admission. The
31 stream-delivery checks include held writer, flush-before-close, queued
cancellation/timeout and read-only stream denial in each build mode.

Actual core conversation/cache: `/private/tmp/hc-runtime.yLDk2O/conversation`
(21 checks, real Unicode bytes, send+Enter, disconnect, foreign-origin rejection,
cache retirement and connect-child cleanup). iOS builds pass at
`/private/tmp/hc-mobile-final.SuHGBs/ios.log`; this is **not iOS UI automation** or
provider/authentication/readiness qualification. QR first-connect now uses pinned
hc SSH exec, preserves the resolved numeric address, and checks its range before
credentials are offered. Pairing report v1's `herdrReached` wire field is retained
as core-health compatibility data, not an old-backend request.

Device pairing `/private/tmp/hc-pair-device.AgXdpa/run` passes 117+7 checks; Mac
pairing `/private/tmp/hc-pair-mac.51sBOl/run` passes 279+11+115 checks. No external
SSH server, real keys/accounts, camera or system security configuration is used.

## File/layout integration and release browser retirement

The hc pane now preserves native file gestures and file drops. Direct-origin
file previews reuse the real bounded file/Markdown/image panel; human web/local
HTML links use the default browser. Local drops paste escaped paths through
SwiftTerm's paste encoder. SSH image uploads retain the bounded streaming
uploader and require a pin; both SFTP preview and uploads apply paired-address
range/DNS binding before authenticating.

Workspace UI supports creating a new shell in a split, closing/collapsing a
pane view without killing its program, and explicitly showing a fresh canonical
core terminal in a new tab (not operation-label adoption). Pending store views
are refreshed from current store state before applying to the screen.

The hc release now ignores persisted browser opt-in and refuses re-enabling it;
normal startup/quit hooks cannot revive browser/injection/legacy endpoints.
Preferences/profiles are preserved, old sessions are not adopted or terminated,
and the new root explains the retirement. Only explicitly isolated DEBUG legacy
browser fixtures can exercise the old browser feature. This does not claim that
external CLIs' inherited hooks were edited or removed.

`/private/tmp/hc-screen-app.p3gksodb` passes 11 actual-app checks: live OSC8 file
link in real SwiftTerm, escaped Finder-path bytes arriving in the inert owned
program, and file-content text read by the real preview panel/accessibility tree,
plus original renderer/root/cleanup gates. This live-link check does **not**
replace the still-failing official initial/reconnect OSC8 gates.

`/private/tmp/hc-layout.BrTcfe/{unit,real}` passes 185 checks per build mode and
44 actual-core checks (split/view close/show existing terminal included).
`release-macos.log` and `ios.log` in that directory pass. Release policy/password
preference retirement tests pass at `/private/tmp/hc-retirement.dXIXoV/run`.
File/drop regression gates pass at `/private/tmp/hc-drop.28BpTb/run` and
`/private/tmp/hc-preview.ZTyeJW/run` (including production panel restoration and
native terminal file links). Standalone SwiftUI fixture compilation now passes
an explicit SDK/plugin path matching Xcode, rather than silently mixing SDKs.
The initial attempts are preserved as failures, not counted as passes.
The shared connection owner moved to ShepherdKit for the upcoming iOS root;
mobile root composition is qualified separately.

## Product machine factory and root

`MachineStore.makeHcConnection` is the production factory, separate from private
`HcCoreBootstrap`: normal local `hc connect` (no direct-start fixture marker), or
SSH session/exec with a pinned host key and one allowed paired-address lookup.
Unknown SSH hosts report a fingerprint for explicit approval **without reading
or offering a saved credential**. Stale machine settings retire the connection;
no missing dependency becomes a simulated successful connection.

`HcConnectionPolicy` clears inherited terminal/socket/injected authority, retains
normal user config/SSH-agent scope, and adds usual CLI paths for GUI launches.
Executable detection follows package-manager symlinks but rejects directories,
dangling links and relative PATH entries. Remote POSIX discovery executes hc
from usual locations/PATH without interactive rc, install or legacy fallback.

`HcMachineConnection` owns opening/closing, host-key approval and per-connection/
origin persistence. `HcRootView` adds machine selection, settings, compatibility
help and retry. This is wired into the private actual-app fixture first; it is
not yet the release default. The helper provides the official installer command
for review/manual install; automatic approved installation is not implemented.

Evidence: `/private/tmp/hc-product.xGv3SC/{macos,ios}.log`, its `ssh` gate (39
checks with the retained qualified candidate), and
`/private/tmp/hc-screen-app.ounj3hgv` exercise the product root/factory. The owned
SSH test validates the exact production exec command before relaying to the
private core; the inert detection test executes the real lookup script itself.
No remote user server or user core is accessed. The first expanded SSH run's
old hard-coded exec-count assertion failed after adding one new successful
factory connection; it was corrected to four, with PTY/cleanup checks retained.

## hc detection + bootstrap

```sh
python3 Tests/HcBackend/run-detect-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-detect.XXXXXX)/run"
```

`HcExecutable` finds `hc`/`herdr-core` in the usual install locations first
(`.local/bin`, Homebrew, `/usr/local/bin`), then PATH, requiring an executable
**regular file** (directories are rejected). It only locates; it never runs the
binary. `HcCoreBootstrap` then owns one policy for the app and tests: private
state/config/runtime + a short socket path, a direct-startup environment
(`SSH_CONNECTION=owned-fixture-no-launchd`, never a machine-wide launchd job),
and a `CoreProcessTransport` + `CoreRPCConnection` whose hello verifies version,
generation and required methods. The caller owns the connection and stops the
core it started.

## Launch owner proof

```sh
python3 Tests/HcBackend/run-launch-proof-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-proof.XXXXXX)/run"
```

`HcLaunchProof` proves a program hc launched is the process actually running in
its terminal: hc's own record (live state, PID, exact argv), the kernel
foreground anchor/snapshot (session leader with a controlling tty), and
`proc_pidpath` (the kernel's executable, not argv). It is observation, not
authority — the caller still compares the resolved executable against what it
asked to launch, and PID/start-time continuity alone cannot survive an exec.

## Board

```sh
python3 Tests/HcBackend/run-board-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-board.XXXXXX)/run"
```

`HcTerminalBoard` is the hc replacement for the herdr board's terminal surface:
`list`/`get`/`run`/`read`/`kill`/`remove`/`attach` on one negotiated connection.
`HcTerminalRecord` decodes the core's public terminal record (address, name,
labels, argv, cwd, state, pid, exit, reason, title, cols/rows, timestamps, OSC
status, reported, turn) and treats those facts as presentation-only. `run` takes
exact argv (no shell line parsing), so quoting stays the caller's. The gate
proves list→run→get→read-marker→kill→rm round-trips and that attach leaves the
program live, against a pinned official core.
