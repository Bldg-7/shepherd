# hc backend replacement (SHPHRD-153)

Default macOS Debug/Release source entry now uses hc through the shared
`ShepherdHcContent → HcRootView` composition; missing/failed hc never selects
legacy. See [source cutover boundary](../../docs/hc-default-backend-cutover.md).
This is not installed-app deployment or completed service/release qualification.

The app backend moves from legacy herdr (`HerdrClient` + `herdr terminal attach`
over an SSH PTY) to hc (`CoreRPCConnection` + `terminal.attach` framed streams).
The experimental browser/`3rdr-browser` injection layer and capture-based API
message collection/mobile structured conversation display are out of scope.
[Current migration scope](../../docs/hc-migration-scope.md) governs acceptance:
capture launcher/token/bootstrap/provider association and capture-history parity
are deferred follow-up, not hc cutover gates. Preserve existing data/code/evidence;
ordinary CLI execution, mobile terminal/screen behavior and other safety/UI gates
remain in scope.

[Plain CLI execution policy](../../docs/hc-plain-cli-launch.md) additionally excludes
automatic app extension/plugin/MCP, prompt/skill, browser-blocking and managed Pi
session injection. The common launcher takes explicit program offers; normal
startup does not start the deferred capture proxy. Codex's existing `--no-daemon`
is an explicit process-isolation exception pending shared-daemon qualification.
Basic native OSC status is independent of the old Pi app bridge; actual plain-Pi
end-to-end and physical/OS gates remain separate. Current scoped evidence and
retirement details: [PLAIN-CLI-README.md](PLAIN-CLI-README.md).
Actual plain-Pi startup/idle without flags or status overrides, and the corrected
native `blocked`/`error` sidebar mapping, have their own
[scoped evidence](../CoreObservation/PI-PLAIN-STATUS-README.md). This does not
qualify real provider workloads, OS notification delivery or a foreground Pi UI.

```sh
python3 Tests/HcBackend/run-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-attach.XXXXXX)/run"
```

## Current official release baseline

The user selected **official hc 0.1.17** with known non-fatal repaint limitations,
not a maintained app-managed fork. This resolves the former artifact-choice
blocker, not the independent red foreground GUI/product-cutover gates. Initial
OSC8/blank-background negative controls remain nonzero and are not waived as
passing fidelity checks. See [release policy](../../docs/hc-official-release-baseline.md)
and [upstream hc #117](https://github.com/herdrdev/herdr-core/pull/117).

`HcReleasePolicy` pins the manual help command's installer version on the sh side
of the pipe, warns about updates/handover and macOS privacy, and never executes an
installer. New detect/bootstrap34 and Debug macOS/iOS builds:
`/private/tmp/hc-official-policy.LZ7qAr`. No global core was changed.

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

## Manual inspection is Shell-only, not an installed-agent launch environment

The private core deliberately has `PATH=/usr/bin:/bin` and fresh HOME with network
blocked. It does not inherit installed Claude/Codex/Pi executables or credentials.
Showing those program choices in the first inspection build was incorrect:
`hc-screen-app.5abryr19`'s owned `holder.log` records Claude missing (`os error 2`).
A placeholder and uncertain operation were retained; they are not a running agent
and are never automatically deleted, adopted or replayed.

The inspection host now explicitly supplies Shell-only launcher choices, and its
root rejects any other program **before** workspace/placeholder creation. The
existing launcher takes a caller-specific safe failure formatter rather than
showing `ShepherdKit.CoreRPCRemoteFailure error 1`. Ordinary product CLI integration
is separate; this mode does not borrow the real account to make a test appear to
work. `/private/tmp/hc-launcher-mode.tXFo6x/run`: **69 actual launcher component
checks** in owned never-shown windows, including single Shell segment, Tab/ShiftTab
unable to select a hidden CLI, and Return requesting Shell only. No real CLI or
provider account was run. Five source-wiring guards also pass.

The first full-app rebuild failed because Xcode27.2 lacked Metal Toolchain
(`/private/tmp/hc-inspection-launch-policy.904Mtl/macos.log`). After explicit
operator approval, `xcodebuild -downloadComponent MetalToolchain` installed the
Apple component; Metal32023.922 / targetdarwin27.2 was verified. The macOS Debug
app then builds and all69 launcher checks pass again at
`/private/tmp/hc-metal-toolchain.8tFfZE/{macos.log,launcher}`. No user core/CLI account
was replaced or restarted. This is a rebuilt-app/component result, **not** a
foreground product GUI pass. Already running inspection instances keep their
previous code until a separate relaunch; no live instance is silently replaced.

## Current native New Tab foreground gate passes (limited scope)

`/private/tmp/hc-screen-app.6zgntub_` passes **12 checks** on the exact retained
source/product hashes: real active/key window, **actually opened native File menu
with New Tab enabled**, native Cmd+N handled, actual launch form AX controls,
Cancel, unchanged core terminal count, rendered cells, live explicit file preview,
exact drop bytes, owned bitmap and full PID/socket/registration/bundle retirement.
`visible-menu-probe.json`: inspectedWhileOpen/enabledWhileOpen=true;
`native-key-equivalent.json`: handled/isActive/isKey=true. No forced enable,
Swift closure invocation, borrowed app privilege or foreground bypass is used.

The earlier cached disabled/action=nil menu snapshot was not sufficient to
conclude functional menu unavailability: SwiftUI populates its menu on actual
native opening/key-equivalent handling. The fixture now opens that native menu,
observes enabled **while open**, closes only that menu with a bounded own timer,
and dispatches Cmd+N through public AppKit. Form/cancel and program survival still
must pass. The first new API build caught its Swift argument label; that failed
attempt is retained at `/private/tmp/hc-visible-menu.S6A5BS`, not waived.

This does not qualify other native command/modal flows, every pixel/layer of the
bitmap, initial/reconnect OSC8, product gateway UI, or default backend/release
cutover (`releaseCutover=false`). Source compilation/gates for future changes
must be rerun. [Build log](/private/tmp/hc-native-menu-api.1s16Vj/macos.log).

### Expanded native commands also pass

`/private/tmp/hc-screen-app.sgmo28fn` passes **15 checks** on its exact source /
product snapshot, including the preceding 12 plus native Cmd+P switcher search /
Done, native Settings / Done, and native Cmd+W removing a second explicitly
created view while the exact terminal remains live and total program count is
unchanged. `paneSwitcherVerified`, `settingsVerified`, `closeViewKeepsProgram`
are required true by the runner. No menu flags are forced and callbacks dispatch
through the native menu. Build: `/private/tmp/hc-native-commands.LusAcp/macos.log`.
The runner now hashes all macOS Swift sources, including the settings view.
These are actual modal/command checks, not component-only mocks; native recovery
review/forget and full product cutover remain separate work.

### Current 18-check recovery/origin gate passes (exact scope)

`/private/tmp/hc-screen-app.xnb0j6qo/validation.json`: **passed=true, 18 checks**.
The actual origin sheet/core ID/Done, history button, Review/Cancel/reopen,
separately confirmed Forget tracking and all preceding native checks pass.
`native-forget-tracking.json` proves only the tracking record was removed and
program count, PID and creation time stayed unchanged with the program live.
Actual foreground/key-window requirements remain mandatory. All owned
processes/sockets/registrations/staged bundles retire, reports remain.
Build log: `/private/tmp/hc-alert-window-ready.lnivYd/macos.log`.

NSAlert exposes the confirmation identifier on `_NSAlertButtonCell`: its AX
Press returned false in `.ztf048sx`. The fixture now chooses the exact associated
own NSButton **before any dispatch**, using AppKit's cell/control association or
bounded exact-cell view traversal, not labels/coordinates. It waits at most five
seconds for that button's own window to be visible/key, app active, button
visible/enabled. It dispatches `performClick` **once**, never falls back/replays
a false/uncertain AX action, never forces enabled state, and still requires real
sheet dismissal, bookkeeping change and unchanged live program identity.
`native-alert-button-preflight.json` and `last-accessibility-press.json` retain
that public native UI path. No direct model/Swift closure substitutes for the
confirmation. This does not qualify native Apply of an unconfirmed layout,
full gateway actions, every bitmap layer, service/installer lifecycle or release
cutover (`releaseCutover=false`). Those remain separate gates.

### Retained failed extension checkpoints (not retroactively passed)

The runner additionally requires the actual read-only origin sheet, completed
history, Review / Cancel and separately confirmed Forget tracking with unchanged
live programs. Do not apply the preceding 15-check pass to this newer source/gate.

- `.i9o7jydz`: actual origin sheet/content/Done passes, then history expansion
  fails; the identifier resolves to **AXHeading**, not a disclosure control.
- `.jede4ayl`: bounded nearby disclosure search also fails; no control was forced.
  Earlier `.1q9ajoli`/`.l189ai4r`/`.byx48ay5` failures remain retained too.
- The product now has an ordinary explicit Show/Hide completed history **button**,
  collapsed by default, with accessible label/value and unchanged record content.
  Tests press that actual button; no SwiftUI state is assigned by the fixture.
  The unsuccessful disclosure-selector/ancestor workaround has been removed.
- `.yy6eksrp`: list node appeared before its core ID text; that immediate check
  failed. The runner now waits at most five seconds for the actual text and saves
  `directory-accessibility-text.txt`; the required content assertion is unchanged.
- `.ylj4sihv`: **overall false, 16 assertions reached**. Origin sheet/content/Done,
  explicit history and actual Review / Cancel passed within this failed run.
  Reopening Review then found the real button disabled. Presence alone is not
  actionable readiness: the current helper additionally waits (bounded five
  seconds) for the actual AX-enabled state, never sets it, and checks Press's
  enabled/supported/handled values separately. Confirmation controls also require
  enabled state. This is not evidence that Forget tracking passed.
- `._miz2a05`: that source compiles, but the human-activation run never obtains
  foreground (nine assertions, helper/app inactive, 150-second handoff deadline).
  The enabled-state wait and final Forget flow were **unverified at that checkpoint**.

All named roots are under `/private/tmp/hc-screen-app`; each owned process/socket,
registration and staged bundle retires, logs/reports remain. No automatic GUI
retry is running. Confirm readiness before another foreground attempt; do not
waive active/key-window, actual controls, content or program-survival requirements.
Compilation/partial assertions are not an overall native UI or release pass.
Later `.ztf048sx`, `.xa5gl12m`, `._4dn9c47` also remain overall false: the last
found the exact native button but its window was not yet key, so no click was
sent. Waiting for actual native window presentation fixes this readiness race;
only the later exact-source 18-check gate above is passed.

## Retained earlier foreground failures (not retroactively passed)

The stricter current runner additionally requires actual foreground/key-window
state and the native New Tab menu opening/canceling the human launch form.
Actual attempt at that checkpoint: `/private/tmp/hc-screen-app.lu550__x` used the explicit
human-activation wait, reached nine earlier assertions and ended **passed=false**.
This time `helperActive=true` was observed: the person's activation did reach the
owned helper. `targetActive=false`/own app `isActive=false,isKey=false` remained,
and no handoff/focus/menu stage was recorded. Earlier `.9zpk1e_h` never observed
an active helper. Neither result qualifies foreground/menu interaction.
Known app/helper/core/holder/program resources, socket, both owned registrations
and staged bundles retired; reports remain. Earlier failures are retained too.
No other app's focus, accessibility grants or authority are borrowed to force a
pass. A GUI environment that genuinely permits this owned foreground interaction
must pass the strict gate before window commands/release cutover are qualified.

Older 11-check UI positives below qualify their narrower source/gate only. They
are not current foreground-command qualification. Current source compilation and
fake-OS notification composition are separate evidence, not a substitute.

### Explicit human activation, without a bypass

When a person is ready to click an owned window, the existing command accepts
`--human-activation`. It gives bounded time (270s controller, 150s handoff wait),
keeps the private peer alive and shows instructions in only its owned helper.
A person may click either the helper or the actual child. The helper may yield
only to that exact child; a genuinely already-active/key child can proceed
without an unnecessary helper-active prerequisite. The final active/key-window,
native menu, form/cancel and unchanged-program assertions remain mandatory.
`targetActive`, direct-activation and pre-handoff focus observations are logged.
No other app, accessibility permission, screen capture grant or provider account
is used. Neither a marker nor the mode flag makes the test pass.

A subsequent harness bug was reproduced: Foundation compares a bundle URL's
**directory hint/trailing slash** as well as its file path, so two URLs for the
same owned `.app` compared unequal. Both helper/child checks now share a strict
canonical **local file path** comparison, rejecting nil/nonfile/nonlocal/other
paths. It does not authorize a process: ownership and tested executable hashes
are checked separately. Diagnostics now include `bundleMatches`, exact bundle
URLs and child process-running state. Native active/key/menu checks are unchanged.
`FixtureBundlePathTests.swift` reproduces the old false negative and passes seven
cases in Debug/optimized after correction. Evidence:
`/private/tmp/hc-bundle-path.8EroFS/{before,after,optimized,helper,macos}.log`;
helper and macOS build pass. This is **not a successful GUI run**. The previous
helper/macOS compile evidence is `/private/tmp/hc-ui-handoff-check.aqOHfM`.
Retry only after confirming a person is ready; failures are not silently promoted.

### Native command state publication

The next actual run `/private/tmp/hc-screen-app.aovolzks` reached active/key-window
state but New Tab was disabled. A bounded four-second diagnostic run
`/private/tmp/hc-screen-app.rhppg5ac` confirmed **ownerCanLaunch=true** while the
native menu retained initial disabled items (`action=nil,target=nil`) and even
the initial legacy Add herdr branch. This was not fixed merely by waiting.

`HcWindowCommandState` now publishes on the main actor via `ObservableObject` /
`@Published`, and the **Commands hosts explicitly subscribe** with `@ObservedObject`
and pass current snapshots to their menu content. Dispatch checks the latest
owner/enablement, not a captured stale menu action; root callbacks also recheck
current machine/model/tab scope before metadata actions. No menu item is forcibly
enabled and no foreground/form/cancel assertion is skipped.

`WindowCommandStateTests.swift`: 15 checks per Debug/optimized mode at
`/private/tmp/hc-command-owner.dqMcZ2`; publication, stale owner/release,
replacement, disabled dispatch and all current handlers. macOS Debug build:
`/private/tmp/hc-command-build.vtvp1S/macos.log`. **Native verification at that
checkpoint was not complete:** its bounded automatic run
`/private/tmp/hc-screen-app.1m8mfgjj` never obtained foreground activation, so
it did not reach the menu stage; both staged bundles/resources were retired.
Do not call the component tests a GUI pass. The later actual-menu-opening gate
above is the separate native evidence; it also corrects the earlier assumption
that cached menu state alone diagnoses the Commands publication mechanism.

## Artifact retention after owned GUI tests

The strict runner now removes its staged app/helper copies **only after** known
app/helper/core/program PIDs and socket retire and both owned LaunchServices
registrations are removed. Reports, source/product hashes and screenshots remain.
Missing identities/uncertain retirement preserve the copies for inspection;
symlinks, other roots or failed registration cleanup are never accepted.
`test_ui_artifacts.py` has six positive/negative tests. Actual latest red GUI run
`/private/tmp/hc-screen-app.lu550__x/artifact-cleanup.json` confirms both owned
copies removed, registrations exited 0, while the GUI verdict remains false.
This prevents repeated ~447MiB bundle copies accumulating; it does not waive the
foreground gate or retain immutable copies of every historical test executable.

## Independent capture history — retained, deferred from migration acceptance

The following records existing implementation/evidence, not a current completion
gate. No new capture integration or provider/native association is required for
this migration under the operator's updated scope.

The production mobile hc board now offers explicit read-only archive browsing,
without a legacy terminal connection or automatic core/native ID association.
See [capture scope, gates and remaining work](CAPTURE-README.md). This is not new
hc-launch capture/native-session binding or iOS UI automation.

## Explicit saved-operation review

The hc sidebar now exposes pending and completed operation history. Human review
reads fresh layout metadata; reapply keeps the exact reviewed version, never
reruns/kills/adopts an unknown program, and forgetting only removes bookkeeping.
This also exposes explicit quota release for the 64-record journal. See
[review scope and evidence](RECOVERY-README.md): unit257/mode, actual private
model/core56, Debug macOS/iOS builds. Native review-sheet UI is not automated;
the independent foreground gate remains unpassed.

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

Capture proxy is independent of browser implementation, but both features are
now explicitly deferred from this migration. Its configured lifecycle and
existing route/data are preserved; this is not permission to stop a user service. Old injected-route terminal IDs are **not**
compared against a new core to infer death/revoke credentials; no new capture
route/native-session mapping is inferred from labels or PID. New hc launch capture
and capture-history screen parity belong to separate deferred integration, not
current backend migration acceptance. Do not add a token handoff/bootstrap now.

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
