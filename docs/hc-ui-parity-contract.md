# hc migration: preserve the existing product UI

## Current scope

[hc-migration-scope.md](hc-migration-scope.md) is authoritative: the operator has
excluded both in-app browser/injected runtime and capture-based structured
conversation collection/mobile display from this migration. Existing archives
and staged code/evidence are preserved. Capture launcher/token/bootstrap/provider
session integration and capture UI parity are deferred, not cutover gates.
Terminal/screen/mobile terminal flows and ordinary CLI execution remain in scope.

## Correction after manual inspection

The operator rejected the hc inspection screen because its layout is completely
different from Shepherd's existing interface. This is a product regression, not
a request for an additional redesign. The migration must replace the backend
while preserving the existing interface and workflows, except for the explicitly
deferred browser/injected-runtime and capture-conversation features.

The 18-check native result at `/private/tmp/hc-screen-app.xnb0j6qo` remains evidence
of its exact command/input/modal/cleanup behavior. It does **not** establish visual,
information-architecture or interaction parity with the existing application.
Do not use that result to approve product cutover or legacy UI deletion.

## Existing source is the reference, not HcRootView's new composition

| Area | Existing reference | Required preservation |
| --- | --- | --- |
| Window and sidebar | `Shepherd/ContentView.swift`, `Shepherd/Hosts/Views/WorkspaceNavigationSplitView.swift` | Native sidebar placement, pin/collapse, persisted sizing, existing window minimum calculation and stable detail identity. Reuse the existing shell rather than a new plain NavigationSplitView with unrelated minimums. |
| Toolbar | `ContentView.workspace(on:)` | Settings, New Tab and pane-switcher controls belong in the existing sidebar toolbar. No new full-window machine/action/diagnostic header. Preserve selected terminal/tab title and title rename behavior. |
| Sidebar | `Shepherd/Hosts/Views/AgentBoardView.swift` | Existing machine/workspace grouping, row hierarchy, selection styling, search/workspace filtering, folded/reordered groups and pane/tab mode. Do not replace the board with raw core terminals and operation journal sections. |
| New Tab | `Shepherd/Hosts/Views/NewTabLauncher.swift` and its step views | Preserve the existing window-wide launcher and selection/creation flow; a different modal form is not equivalent UI. Keep exact new-backend routing/operation safety underneath it. |
| Terminal detail and preview | `ContentView.terminalColumn(on:)`, `Shepherd/Hosts/Views/WorkspaceDetailSplitView.swift` | Preserve terminal/pane identity, split behavior, keyboard focus, adjacent/expanded preview placement and return behavior. Do not redesign the detail as a side effect of transport replacement. |
| Commands and selection | `ContentView`, existing board, switcher and title-rename components | Preserve shortcuts, context menus, selection/focus, close confirmation and switching semantics; explicit hc operation safety still applies. |
| Error/recovery/diagnostics | Existing error/banner/menus; new durable hc recovery model | Necessary new recovery must be discoverable without turning bookkeeping/raw IDs into the normal workspace's primary information hierarchy. Any necessary new product surface must be explicitly reviewed, not silently introduced as a redesign. |

## Implementation boundary

- Extract/reuse existing presentation components and feed them explicit hc-backed
  state/actions. Keep terminal references and machine/epoch scoping typed and exact.
- Do not revive legacy transport, fabricate legacy session/TTY identities, or
  infer native authority merely to reuse presentation models.
- Do not retain two permanent backend products. Existing UI is the presentation
  reference; legacy backend code retires only after hc-backed UI parity is proven.
- Do not restore browser/runtime or capture injection under the name of layout parity.
- Deferred capture must not require a legacy terminal backend fallback at cutover;
  preserve stored archives without claiming new hc/provider association.
- Keep existing dirty/unrelated source and user data intact. No installed app/core
  replacement, running-user-core restart, or deployment is authorized by this UI fix.

## Acceptance evidence before another product approval claim

1. Inventory each existing in-scope control and workflow against the hc-backed
   implementation. Missing behavior is a gap, not an approved simplification.
2. Use matched deterministic content/window geometry for original presentation
   and migrated presentation. Compare native layout frames, screenshots and actual
   control behavior; a bitmap alone can omit layer-backed content.
3. Retain framed-protocol, scope, durable-before-dispatch, no-replay, program
   survival and cleanup gates. Visual parity must not weaken backend safety.
4. Obtain operator inspection of the restored layout. The previous 18-check
   functional composition gate cannot substitute for this approval.

## Restoration implementation in progress

The hc surface now uses the existing `WorkspaceNavigationSplitView`, sidebar
metrics/pin/collapse and its toolbar placement, rather than the replacement
header/plain split. `WorkspaceBoardPresentation.swift` extracts actual original
row/status/search/workspace-label/tab-mode-bar bodies; both `AgentBoardView` and
the hc-backed board call those components. No legacy transport identity is
fabricated. Normal board rows no longer contain raw core lists, CRUD forms or
operation journals; recovery is a secondary sheet/context action and pending
outcomes use a compact review notice.

The hc root now instantiates the existing `NewTabLauncher`, not a replacement
launch form. Its explicit standalone-program mode is separate from browser
permission. CmdN/CmdT have separate intents and workspace selections are checked
against the current typed UUID document and current model scope before dispatch.
The existing switcher body is shared via backend-independent typed items.

Title editing reuses the existing `TitleRenameField`/IME/toolbar/double-click
implementation through a presentation editing protocol. The hc edit captures
origin epoch and document version, retains exact pane/tab target and rejects a
changed layout instead of blindly rebasing. Pane renames preserve their terminal
reference and do not rename the containing tab. Preview uses the existing native
`WorkspaceDetailSplitView`, including its draggable width and covering mode;
covering no longer removes the live terminal. Preview requests/readers are kept
in a bounded cache scoped by transport epoch, pane UUID and exact reference.

Current status: **UI parity blocker still open pending validation and operator
inspection**. Initial macOS compilation and core schema/CAS tests pass (261 per
Debug/optimized mode,21 stages including iOS typecheck). Title-field component
regression harness needed explicit generic coordinator casts and matching
SDK/plugin paths; checks are not disabled. Full original UI workflows, layout
frames/manual comparison and updated end-to-end automation still require review.
The prior 18-check result belongs only to its earlier, rejected composition.
Do not describe the restoration as fully approved solely from source wiring or
component tests.

Current evidence: `/private/tmp/hc-restored-layout-final.gwiZUB` has macOS/iOS
Debug build success, title editing's complete6-stage rule/real field/native-toolbar
component suite,18 command-owner checks in both Debug/optimized modes, and4
source-wiring regression tests (including rejection of the previous header and
editor-sidebar composition). The component suite explicitly records physical
keyboard/IME/fullscreen/resize gestures as NOTRUN; it does not substitute for
operator inspection. The earlier standalone macro failure was fixed with matching
SDK/plugin paths, not lower Swift/concurrency diagnostics. Core schema/CAS:
`/private/tmp/hc-ui-preservation.NybyIt/workspace`,261 checks per mode/21 stages.

`/private/tmp/hc-screen-app.jlbjkcqo` is the currently opened20-minute manual hc
inspection instance of the restored composition. It is not an automated GUI pass
or deployment. The previous manual instance `dqiumsbg` ended with owned cleanup
confirmed. Source changes preserve unrelated dirty project/package/user files.
