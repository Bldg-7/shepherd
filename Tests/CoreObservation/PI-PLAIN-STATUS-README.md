# Actual plain Pi native status over official hc

This is ordinary CLI/terminal qualification under the
[plain CLI policy](../../docs/hc-plain-cli-launch.md), not capture or browser work.

```sh
python3 -B Tests/CoreObservation/run-pi-plain-status-tests.py \
  --official-017-archive /absolute/official-0.1.17.tar.gz \
  --products build/DerivedData/Build/Products/Debug \
  --output /private/tmp/<fresh>

python3 -B Tests/HcBackend/run-program-status-presentation-tests.py \
  --output /private/tmp/<fresh>
```

## What actually executes

The checksum-pinned official 0.1.17 core runs with an empty private HOME/XDG,
short private Unix socket, private session and empty private working directory.
The actual installed Pi 1.5.0 executable is resolved by PATH and launched as
**`["pi"]`** through `HcTerminalBoard.run`. No flags, extension, skill, prompt,
MCP setup, session ID/directory, provider override or `PI_*` environment setting
is supplied. In particular `PI_PROGRAM_STATUS` and `PI_OFFLINE` are unset.
Standard terminal/transport/isolation variables are listed in the private plan;
this is not a claim that the CLI uses the user's HOME/configuration.

Installed executable/native-code and package-manifest hashes are checked before
and after. Product SDK/object hashes and source hashes are also retained. The
archive had to be reacquired after the old temporary archive disappeared; its
pinned SHA remains `cedbd4d4d9ba1385588198dd4d3c67d2654478f33add5b6445d4d0eb9da5fcf3`.
No installed core, service or CLI was replaced.

Before Pi starts, the exact inherited sandbox is tested with inert inside/outside
file canaries and an owned TCP listener. Outside reads/writes and TCP access are
denied. Mach credential brokers and external helper execution are denied; only
known code, public OS runtime files and the owned fixture are readable. No user
configuration, Keychain, provider login or model prompt is used.

The live stream uses the product `HcTerminalSession` and vendored SwiftTerm
renderer. Actual VT bytes are fed before CREDIT, bounded renderer replies are
sent as terminal negotiation, and no user text/command is submitted. Core status
is observed via a bounded explicit GET condition and subscribe-before-run status
events, never a quiet-output timeout or fabricated ready flag.

## Proven boundary

Owned evidence root: `/private/tmp/hc-pi-plain.tlpSzG`.

- `run`: first **8-check** actual plain-Pi startup/idle/event/decoder/render/detach
  result before the presentation correction. Preserved as that exact result.
- `status-unit`: **32 checks per mode** in Swift 6 Debug and optimized builds.
  All five native words, missing/unreported/unknown words and rejection of old
  heuristic aliases are checked, without executing a CLI or showing a window.
- `with-presentation` and `product-pi`: **9-check** actual plain-Pi results,
  additionally feeding the real record to the exact `HcProgramStatusPresentation`
  used by the sidebar; `product-pi` consumes the rebuilt platform products.
- `workspace-pi`: current **11-check** result adds an actual `HcWorkspaceModel`
  subscriber on a separate connection. The model receives the Pi status through
  its own production event/list path, not a manually assigned terminal array;
  the same sidebar mapper consumes that model record. This observer performs no
  workspace mutations and uses inert persistence callbacks; durable launch is
  not newly qualified by this read-only observation. Model disconnect reaps only
  its own connect child while the same Pi remains live.
- `integrated`: macOS Debug/Release, iOS Debug, renderer/parser **69**, official
  core **6/80-column** rendering, original UI **16 stages** (launcher **81**), and
  source-wiring **28** pass with natural bounded retirement.
- `notifications`: actual-core coordinator **28** checks with an explicit fake
  OS presenter/permission source; not real OS notification delivery.
- `mobile-screen`: actual shared screen/input/cache model **21** checks; not an
  iPhone/iPad runtime or structured API-message capture. The mobile terminal's
  status label was also corrected to honor `reported`, matching the board/cache
  rather than showing an unreported word as current status. `ios-followup` builds
  that final iOS source; source wiring covers the guard. No device UI is inferred.
- `/private/tmp/hc-screen-app.nmgk_rry`: current actual hc-root native UI **74**
  checks pass through original launcher/sidebar/Preview/close/end/Retry and native
  fullscreen layout. All owned processes/socket/staged apps retire. This is not
  a Pi/provider foreground UI, direct-SSH profile rerun, physical edge/IME/drag,
  whole-UI approval or release cutover.

The sidebar previously recognized `needs_input` but omitted native `blocked` and
`error`. It now consumes the official OSC 7501 vocabulary: `working`, `blocked`,
`done`, `error`, `idle`. `error` uses the existing board's blocked/needs-attention
category; no new UI layout or AgentState wire case is introduced. Missing or
unknown reports remain unavailable rather than guessed idle/ready. Legacy alias
words (`running`, `active`, `needs_input`) are not substituted for native words.

Actual Pi produces `reported=true`, `status=idle` and a real status event without
forcing protocol support. The private screen also shows CLI-owned fd/ripgrep
bootstrap downloads failing because networking is denied. This does not block
that status observation and is explicitly **not** tool/model readiness; no app
flags or helper installation are added to hide the warnings. The production attention decoder/feed accepts that
record without a startup notification. Detaching preserves the same known Pi
PID/incarnation and status. Cleanup issues at most one kill for the exact known
run receipt after a fresh incarnation check, then stops only the private core,
reaps the connect child and verifies every recorded owned PID/socket retired.

Cleanup: `build/cleanup/hc-pi-native-status-cleanup.json` records **49** exact
owned executable/resource/cache removals (~**1.288 GiB** allocated). The native
runner separately removed both staged app bundles. All owned core/Pi/model
connect children and sockets retired first; unrelated cargo builds observed
during checks exited naturally and were not stopped. Source, logs, raw VT,
rendered startup screens, hashes, private state, native geometry/screenshots and
the pinned archive/manifest remain, as do current app/platform products.

## Explicitly not qualified

- Real Pi `working`, `blocked`, `done` or `error` under a provider workload:
  **NOTRUN**. Their mapping tests and synthetic core-event coordinator tests are
  not real provider execution. No extension or login flow is introduced just to
  generate these states.
- Actual foreground **Pi** sidebar/OS notifications: **NOTRUN** here. A real
  record reaching the production model/mapper is not a rendered-Pi-window receipt;
  the separate 74-check native run exercises the existing owned fixture programs.
- Native-session identity, input/kill/credential authority from status: never
  granted. Cleanup authority comes from the known isolated run receipt, not idle.
- User provider/account readiness, physical IME/gestures, mobile device runtime,
  installed service lifecycle, GUI-quit survival and release/default cutover.
  `SSH_CONNECTION=owned-fixture-no-launchd` is a fixture isolation bypass, not
  production launchd evidence.

The old candidate-core `run-cli-startup-capture.py` remains historical. Its Pi
observer/flags are deliberately **not** reused to claim plain execution.
