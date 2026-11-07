# Plain CLI execution in the hc migration

## Product rule

The operator chose ordinary CLI execution and observation over app-managed agent
integration. Do not require automatically injected CLI options for a feature in
this migration. Do not replace an excluded option with hidden environment,
config-file, wrapper, hook or global-registration injection.

This refines [the current migration scope](hc-migration-scope.md), not the
terminal transport, ownership or UI safety requirements. Existing archives,
settings, staged implementations and positive/negative evidence are preserved.
User-installed extensions, MCP servers, instructions and provider settings belong
to the user; the app neither disables nor rewrites them.

## Ordinary execution contract

The hc launcher uses one `HcWorkspaceModel.launchTab` path for all four choices:

| Choice | argv | Meaning |
| --- | --- | --- |
| Shell | empty | Use the core's default shell. |
| Claude | `claude` | No app plugin, settings, tools or instructions. |
| Codex | `codex --no-daemon` | Explicit, temporary process-isolation exception below. |
| Pi | `pi` | No app extension, skill, instructions, session ID or session directory. |

`LaunchProgram.terminalArguments` is the single checked argument mapping. The
shared `NewTabLauncher` accepts offered programs and optional explanatory text;
it does not decide browser compatibility or prepare an agent runtime. Offered
lists are deduplicated in canonical order, always retaining Shell. `nil` hides
the picker. A selection withdrawn/hidden before submission cannot reach the
creation callback; this is not cancellation or replay of an already requested run.
Private UI inspection still offers Shell only and rejects agent requests before
workspace/placeholder creation. Legacy nested-herdr targets remain Shell-only;
this change does not authorize ambiguous gateway execution.

The common launch path retains exact origin/cwd resolution, the durable operation
journal, known run receipt, workspace CAS, no uncertain replay and model/selection
checks. A successful run/attach is not provider login or model readiness.

### Codex exception is not implicit approval for other flags

The existing `--no-daemon` avoids attaching to Codex's shared background server.
Removing it changes process ownership and lifetime, not merely UI behavior.
Keep it explicit until disposable actual-CLI evidence qualifies the shared-daemon
case; do not silently remove it or claim it can never be removed. This is not an
exception for MCP, prompt, approval/sandbox bypass or provider configuration.

Explicit user-requested operations such as Resume are different from hidden
startup injection, but are not newly implemented or qualified by this change.

## Not part of ordinary launch

- App plugin/MCP registration, skill or system/developer-instruction additions.
- Competing/external-browser blocking and user-command/child-CLI rewriting.
- Pi app bridge, native-session association, session-file placement and internal
  session-name synchronization. App tab/pane rename remains independent.
- Capture route/token/provider overrides, bootstrap/helper and automatic capture
  service installation/start/reconciliation.
- App-managed CLI/Node/plugin capability checks as a prerequisite for ordinary
  execution. The CLI owns its dependencies and reports its startup errors.

The normal app-start branch no longer calls `AgentProxyService.start()`. This
neither stops an existing service nor removes its routes/settings/archive. Legacy
browser/runtime startup remains reachable only through the existing explicitly
isolated DEBUG fixture gate. Deferred Settings do not evaluate runtime diagnostic
or credential-onboarding paths just to open the page; Terminal File Drop remains
an independent control. The ordinary machine-change callback also skips legacy
runtime/browser updates, and the paired-device/add-device pages receive no capture
service control in the product path. Their pairing flow remains enabled; isolated
legacy fixtures can still exercise the retained capture implementation.

This is not installed-service retirement or handover qualification. Do not stop
user programs/services, delete existing data, or use legacy terminal fallback to
keep excluded features alive at cutover. The default root is still legacy until
the remaining in-scope gates authorize its replacement.

## Basic status does not need the Pi extension

Pi's own Program Status Protocol (OSC 7501) reports `working`, `blocked`, `done`,
`error` and `idle`. Installed Pi documentation/changelog records support from
1.1.0; the inspected installation was 1.5.0. Default reporting depends on terminal
support negotiation. Do not automatically force `PI_PROGRAM_STATUS` or infer
`idle`/ready when reports are absent. The app's hc attention feed already consumes
reported statuses; status is presentation data, never native-session/input/kill
or credential authority.

Synthetic OSC/core tests and source/document inspection do **not** qualify an
actual plain-Pi → official hc → app run. That end-to-end gate remains separate.
The pre-existing official initial/reconnect OSC8 limitations are also unchanged.

## Validation boundaries

The launcher component gate compiles the complete actual view under Swift 6 and
uses AppKit key-downs in never-shown owned windows. It checks canonical program
offers, argument mapping, Tab/Shift-Tab, composition preservation, Return,
pending creation, nested target restrictions, inspection and live offer
withdrawal. It does not execute installed CLIs, use accounts or qualify physical
IME, full foreground GUI parity or release cutover.

```sh
python3 -B Tests/HcBackend/run-launcher-mode-tests.py --output /private/tmp/<fresh>
python3 -B Tests/HcBackend/test_ui_preservation_wiring.py
```

Source-wiring tests separately guard the common hc launch path and absence of
automatic deferred-service startup. Platform builds and the original UI suite
remain required; no safety or physical/OS gate is removed by this simplification.
