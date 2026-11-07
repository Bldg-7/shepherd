# hc UI preservation audit — operator must not be the regression finder

## Gate

The original `ContentView`, `AgentBoardView`, terminal/preview/launcher components
and their existing interaction regressions define the baseline. A backend swap
must not redesign the product. Passing a component or a subset of a new screen's
controls is not this gate. The operator is not responsible for finding each gap.

Statuses below distinguish a source correction from exercised component behavior
and actual product/physical GUI approval. No row marked open is implicitly waived.

| Area | Original contract / evidence | Audit finding and current work |
| --- | --- | --- |
| Information hierarchy | Original toolbar/sidebar; `hc-ui-parity-contract.md` | Replacement global machine/diagnostic header and CRUD/journal sidebar removed. Shared original row/search/tab-mode presentation now used. Source guards cover the rejected composition. |
| Fullscreen sidebar | `WorkspaceSidebarState`, `SidebarPeekREADME.md` | Same shell is necessary but not sufficient. Initial native restoration, reveal without pin, pin while revealed, dragged collapse, one-click reopen, width constraint and real terminal identity/grid must all hold. Shared native component positives/four negatives pass. Actual hc fullscreen failure was then reproduced (1714→1354pt,212→167 columns) and corrected with the public native inline-sidebar threshold only while fullscreen/unpinned. One historical actual-root7-check pass did not survive edge-retention repeats. Current separate native-toggle fullscreen run `.7e0p4a6j` passes initial and three repeated overlays with360pt sidebar and unchanged212×63 terminal, then fails later at title-target lookup (22 partial checks). `.a9i7hvii` reaches28 after the exact toolbar-owned title locator correction, then fails Preview AX dispatch. Neither is a whole pass or edge-hover proof. With scoped title targeting and Preview's native item ID, `.z297kt8j` subsequently passes69 fullscreen/native-layout checks through Preview, multi-pane/split, explicit end and Retry; repeated native-toggle overlays remain stable. Physical edge-retention remains **RED/open**, not waived by that distinct native API gate. |
| Detail hosting topology | `ContentView.workspace(on:)`, `WorkspaceDetailSplitView` | Found preview split inside each hc pane instead of beside the whole tab. Moved one native preview split to the detail root. Current two-pane ordinary-window audit measures non-overlapping pane frames and detail-level preview; no persistent pane header. Fullscreen topology remains open. |
| Terminal gutter/focus | `TerminalPaneFrame`, original pane/tab terminal views | Found missing7pt gutter and different1pt focus border. Reuse original frame; focus indication now follows actual keyboard focus, not persisted last-pane selection. Needs current app geometry/focus proof. |
| Pane/tab mode | `ContentView.onChange(showsTabs)` | Found old selection retained instead of cleared. Presentation state now clears the UI selection and prevents unchanged model focus from resurrecting it. Pure rules and current ordinary-window mode/selection clearing checks pass; fullscreen interaction remains open. |
| Row activation | `BoardRowActivation`, original focus request path | Found same-row click had no way to return keyboard to an already mounted terminal. Added typed epoch/pane/token request; no force activation of another app/window. Current ordinary-window audit exercises same-row activation returning keyboard from the filter; fullscreen interaction remains open. |
| List navigation | Original binding vs explicit row activation | List selection must not steal keyboard while moving in the list. Explicit activation is separate and can restore keyboard. Pure presentation rules cover this separation. |
| Selection removal | Original board reconciliation | Closing selected view must not immediately display a reconciled fallback. New state suppresses that stale UI restoration; closing an unselected view must not clear the selected view. Exact event/race coverage still open. |
| Split/zoom controls | Original pane framing/layout | Removed extra hc-only persistent pane header. Explicit new-shell/zoom actions stay in secondary pane actions, not new visible header geometry. Current ordinary-window native context menus exercise zoom/unzoom and New shell to right: correct1/2/3-view topology and exactly one new shell, without ending existing programs. Fullscreen/physical divider behavior remains open. |
| Preview placement | Original detail-level adjacent panel | Preview is beside the whole terminal/tab, not squeezed into an individual pane. Side minimum320/ideal560. One native host and divider proportion persist. Shared split component proves host stability; current ordinary-window63-check root measures the whole-tab/two-pane placement. Fullscreen preview/multi-pane geometry then passes in `.z297kt8j` after the scoped native toolbar route correction; physical divider/hover remains open. |
| Preview expansion | Original covering panel | Expanding must cover rather than destroy/reparent live terminal. Root covering host retained; terminal hiding is accessibility/hit-testing only. Needs current attach-count/input/PTY proof. |
| Preview history | Existing per-selection preview state | Found per-pane-only state in tab mode and close discarding its request. Restored typed pane/tab selection caches, one shared preview per tab, original Show/Hide Preview toolbar, hide retaining file but retiring read, and return at side with source/find/scroll retained. Exact source UUID+core/terminal membership controls invalidation; unavailable reads are not missing proof. Actual store/request/model23 per mode and platform builds pass; current native toolbar/tab navigation/geometry remains open. |
| New Tab | Original `NewTabLauncher` | Actual original launcher used; separate CmdN/CmdT intent. Standalone CLI mode is not browser permission. Private inspection now Shell-only; real installed CLI integration is not inferred from a menu choice.69 actual launcher component checks pass. |
| Failed launch | Existing launcher handling plus durable hc recovery | Public stable failure formatting, no internal NSError name. Unsupported inspection intent rejected before workspace/placeholder creation. Uncertain prior run never auto-deleted/adopted/replayed. Missing real CLI/race error UX remains separately reviewed. |
| Title editing | Original title double-click/IME field/native toolbar | Same real field/toolbar implementation with typed hc target, epoch/version guard. Component tests cover simulated composition, stale callbacks and geometry. Current actual-root ordinary-window audit exercises native title-label double-click/local event monitor, real editor/Unicode submit, Escape without metadata change, title restore and no window zoom/layout replacement. Actual competing-CAS refusal also passes: the old title session cannot overwrite a newer layout snapshot. Current fullscreen/native-layout run `.z297kt8j` exercises owned auxiliary-toolbar title double-click, Unicode edit/Escape and competing-CAS refusal. Physical IME remains open. |
| Switcher | Original deferred onDismiss navigation | Found selection/focus applied before sheet dismissal. Defer with exact epoch/pane/terminal reference check; reject stale retarget. Shared original switcher presentation used. Current ordinary-window audit exercises Cancel and Return/dismissal/keyboard return; stale-scope dismissal remains a separate gate. |
| Closing | Original command/context confirmations | Explicit view close keeps programs; current selection required, cover disables close. Current ordinary-window63-check root observes real default Return close preserving all program incarnations, selection clearing, competing-CAS refusal, and unselected native-context close without navigation. Current fullscreen/native74-check run `._35qrzu0` also proves Cancel has no document/version/journal/program effects, and an exact before-dispatch close delay cannot overwrite a newer real row selection. Physical post-dispatch pointer-focus races remain separate gates. |
| Explicit program ending | Original Close confirmation can end programs | Source now keeps view-only close as default and declares a separate explicit close/end-unshared choice. Schema2 partial close + durable stop, old-schema read, fresh direct facts, shared/foreign protection and no uncertain replay pass SDK274/mode and actual-core76. Current ordinary-window63-check root executes the separate native end action, confirms only its consented Shell finished and recovery confirmed, and preserves other programs; native default Return stays view-only. Cancel/pending-stop UI and fullscreen ending remain separate gates; no full UI qualification. |
| Quit with sheet | Original presentationPreventsAppTermination(false) | Added original behavior to transient settings/switcher/origin/tracking/install sheets. Needs actual CmdQ/owned service survival gate. |
| Viewed/attention | Original key-window + actual selected pane/tab | Found hidden tab siblings marked viewed in pane mode and app-active used without key-window check. New policy uses actual rendered mode/zoom/selection + key window. Pure rules covered; OS notification behavior remains unqualified. |
| Scope changes | Existing exact machine identity / connection provenance | Clear overlays and deferred navigation; typed epoch/reference keys for previews, focus, switcher. No alias/PID/label is native authorization. Native Retry is exercised; exact current owner-model identity now joins profile/epoch guards at board actions, attach/input/drop/upload and title submission. Current78-check distinct-origin UI gate uses real Settings/approval controls, verifies no credential access before approval, old-model retirement, distinct remote output without the old preview, local return and both programs' survival. Physical cross-window interactions remain open; direct profiles are not gateway authority. |
| Existing native terminal discovery | Original board/switcher lists registered programs | Restored board/switcher initially hid externally created canonical hc terminals without saved views. Existing CmdP now offers explicit typed canonical choices, fresh read + exact-version view-only CAS after dismissal. A known-missing document gets workspace/view in one CAS; closing that view keeps the program. Native empty-board flow passes55, with an empty-state shortcut hint; no diagnostic sidebar, fake IDs, native-session inference or uncertain-run adoption. |
| Multi-origin groups | Original host/remote grouping, folding, ordering | Still incomplete in hc product. ID-shadow bug in0.1.17 means no unsafe remote mutation or alias fallback. Do not hide this parity gap behind the read-only directory or claim full migration. |
| Drag/drop | Original row-ID drag + terminal file drag | Scoped row-reference providers and the original terminal text-drop/highlight pipeline are now wired using real workspace node UUIDs, not fake legacy identities. Policy25/mode and actual-core native-destination component integration pass; physical List/Finder gestures remain unqualified. |
| Empty/loading/error | Original board overlays/search/retry | Actual initially empty board, multi-term/no-results filter and client-failure banner/program survival pass in the current root. Native Retry dispatch also passes32-check current-root audit; loading and stale-target transitions remain open. No diagnostic/editor sidebar substitutes for these. |
| Application entry/service | Existing root plus hc lifecycle requirements | Default root/legacy removal/install/update/service survival/cutover still open. UI work does not authorize deployment or user-core replacement. |

## Current integrated results and remaining boundary

- `.aw1r8cn5` passes23 actual-root ordinary-window checks, adding a real two-pane
  tab and retained detail-level preview. Native pane rectangles do not overlap;
  whole-tab preview expand/return preserves both terminal identities/frames/grids.
- `.0saulfin` passes25 checks, adding actual filter typing/no-results overlay,
  clearing the filter/restoring rows, and selected-terminal preservation while
  its row is filtered out. Pure presentation/search rules24 pass. Search now
  matches every whitespace-separated term across workspace/tab/title/directory
  fields; empty/loading/error/retry overlays use original presentation patterns.
  Error/loading transition E2E and full parity remain separately open.

- `.9awxx30v`: ordinary-window14 checks, including real file contents, preview
  expand/return retaining exact terminal/frame/grid and keyboard return.
- `.4impfiyo`: native switcher Cancel and Return selection/dismissal also pass.
- `.havbsoi1`/`.1wpah6ma`/`.hxdah4wm` expose a real integrated launch-field focus
  failure: the field is in the key window but has no editor; the terminal stays
  first responder. One-shot focus tokens alone did not remove the repeat failure.
- Focus intents now acknowledge once, deferred terminal landing/preview keyboard
  restoration honor a live overlay/sheet gate, and the original launcher waits
  for actual native field landing rather than a single makeNSView callback.
- `.x0j1awvs` and `.lij0r0ag` then pass20 checks **consecutively** with the same
  source/products: launcher real editor/step/Esc with no document/program change;
  actual CmdW/confirmation closes only duplicate view; selection stays clear;
  explicit remaining-row selection works; real program PID/creation/liveness
  retained. All owned identities/sockets/registrations/staged apps retire.
  Component launcher69 checks pass at `/private/tmp/hc-launcher-landing.HO4x0t`.
  These ordinary-window results do not close the repeated-fullscreen boundary.
- Repeating the first shield still failed at `.fda621si`; do not treat its
  preceding successful iteration as a stable fix. The launcher's original
  one-shot makeNSView callback could precede native window landing. The actual
  `LauncherLandingTextField` now owns a bounded, once-successful editor request
  from viewDidMoveToWindow/superview, invalidated on teardown, with no text
  replacement or composition reset. `.x0j1awvs`/`.lij0r0ag` above are the later
  final landing-source consecutive passes, not retroactive passes for the first
  shield alone.
- `/private/tmp/hc-focus-landing-regression.OEDiqX`: final optimized presentation21,
  original title rules/IME field/native toolbar6 stages, window-minimum geometry,
  shared sidebar136, iOS Debug and source-wiring8 checks pass. Actual global
  keyboard/physical IME/physical divider drag remain separately unqualified.

- `/private/tmp/hc-screen-app.33ge5kte` passes10 actual hc-root ordinary-window
  checks, including actual mode toggle clearing the terminal selection, actual
  tab-row click selecting it again, and same-row activation returning keyboard
  from the real filter field. Program identity/liveness and all owned cleanup
  remain checked. This is not full UI preservation approval.
- `/private/tmp/hc-post-fullscreen.JCUJLW` passes the post-change component batch:
  presentation19 per Debug/optimized, sidebar136, four expected negative child
  failures, window minimum geometry, selection appearance48, iOS Debug and8
  source-wiring guards. Negative receipts keep passed=false.
- `.vt5xj195`, `.5p68laxf`, `.5gnt84w3`, `.9yif5i2b`, `.4vu1fbuv` retain later
  fullscreen repeat failures. The tiling/terminal-grid regression did not recur,
  but the drawer can close/return to its collapsed140pt state after reveal.
  Native event trace keeps pin intent false and the360pt width constraint active;
  pointer requests match observed positions. Do not infer that one seven-check
  pass establishes stable physical hover behavior. Fullscreen repeated-hover
  qualification is **reopened/pending**, not waived.
- `.lcdhqqvc` fails at owned foreground readiness before preview tests. It does
  not prove preview behavior failed or passed. Preview integration assertions
  remain pending. No more unattended foreground retries are running.

- `.ewfgknjn` passes26 ordinary-window checks, adding current-layout production
  file-drop callback with an owned path containing a space/apostrophe and exact
  escaped bytes verified at the owned program. This is **not** a physical Finder
  drag qualification. All known owned programs/core/socket/staged bundles retire.
- `/private/tmp/hc-board-state-regression.B5ae9k`: final optimized UI/search24,
  original launcher69, iOS Debug and source-wiring8 regressions pass. Loading/
  failure transitions remain source-wired, not falsely labeled exercised E2E.

- `.alhq9684` passes29 current-source ordinary-window checks. Before seeding any
  workspace it observes the actual No Panes board. At the end it closes only the
  app's owned `hc connect` transport, observes model failure and the real board's
  connection-failure/Retry banner, and uses a separate live control connection to
  verify the original program's same PID/creation/live state. Retry **dispatch**,
  loading transition, physical pointer/IME/Finder drag and whole UI approval are
  not inferred from these checks. Core, programs, socket and staged apps retire.

- `.5oghpa8b` passes32 ordinary-window checks including the actual enabled Retry
  button, a new connected model/transport, identical workspace metadata and
  unchanged terminal addresses/PIDs/creation/state. The previous connect child
  is reaped. Private transport injection now creates a fresh instance per attempt;
  production still uses `MachineStore.makeHcConnection`, never a fixture binary.
  The failed `.a8fmph9t` (29 checks, Retry AX identity absent) remains a failure:
  the banner identifier was moved to its text, away from the child button, and
  native enabled readiness is checked before one dispatch. `.gyisx1qu` failed
  foreground readiness before feature tests. Earlier two build failures remain
  in `hc-native-retry.zHcSgc` / `hc-native-retry-fixed.IywIXs`.
- `/private/tmp/hc-retry-regression.gK0rkn`: macOS Release / iOS Debug, launcher69,
  wiring9 and artifact cleanup rejection tests pass. This preceded the last AX
  label placement; the latest Debug build is `hc-retry-controls.c3QmUi`.

- `.4lo3n1qx` passes35 ordinary-window checks, adding actual title-label hit
  target and double-click events through this app's own queue/local monitor, real
  field-editor Unicode typing/Return, Escape without mutation and original title
  restoration. The label double-click does not zoom the window or replace the
  pane layout. No direct rename closure/model action substitutes for these UI
  gestures. Physical IME and fullscreen title editing remain unqualified.

- `.mo8wutwv` passes37 ordinary-window checks. While the real title editor owns
  keyboard, a separate subscribed store on the independent control connection
  commits a competing workspace CAS. The editor retains its text; Return shows
  the actual Rename unconfirmed alert instead of rebasing/retargeting the old
  session. Its real enabled OK button dismisses without replay/document change.
  Program/reference preservation and native Retry remain exercised afterward.
- `hc-title-current-regression.yvFUq8`: title/IME/toolbar6-stage component tests,
  macOS Release, iOS Debug, wiring9 and artifact rejection tests passed before
  the final alert-button identifier. Current wiring10 pass separately. Physical
  IME, non-title system double-click zoom and fullscreen title handling remain
  separate; current Debug build is `hc-stale-title.SZgOea`.

- Fullscreen stimulus diagnostic `.74mkr9k4` (one bounded `--pointer-warp-only`
  run): pointer positions matched requests but no native edge reveal occurred.
  This is neither a product-regression attribution nor a fix; no retries were
  looped. Earlier self-window-event retention failures remain open. That run's
  `pointerAtFailure` was sampled after restoration; only its movement trace can
  establish stimulus positions. Current source captures failure/restored points
  separately and names the stimulus in receipts.
- Passive manual `.5hbevcg5` ended after its600s bound and verified cleanup. Its
  JSONL observer sent no events/warp/activation/model actions;581 samples, no
  truncation, **zero fullscreen samples**. It supplies no physical/fullscreen
  qualification. No additional automated fullscreen retries are justified by it.
- `hc-full-migration-regression.DKaJXq`: SDK workspace92 + store32 + lifecycle66
  + delivery31 + gateway40 checks in each Debug/optimized mode (261/mode),
  21 stages including iOS typecheck; official0.1.17 attach9 pass with owned
  core/socket/process retirement. These do not qualify launchd or UI parity.

- `.rrvo2dnm` passes42 current-root checks, adding scoped row-reference **component
  integration** on the actual renderer/owned PTY. An explicitly synthetic
  NSDraggingInfo/owned named pasteboard exercises the production destination,
  external-source rejection, File Drop OFF independence, exact UUID-plus-space
  bytes and retired-source refusal after native Retry. It is not physical List
  dragging; receipt has `physicalRowDragQualified=false`.
- `hc-row-drag.RU1p0a/policy`:25 strict policy checks per Debug/optimized mode.
  `hc-row-drag-regression.YXBnFl`: existing actual-SwiftTerm/native owned-PTY
  item-drop2-stage component tests, macOS Release, iOS Debug, wiring11 and
  artifact rejection tests pass. See `Tests/HcBackend/ROW-DRAG-README.md` for
  metadata-ID semantics and qualification boundaries.

- `.09ejp5g7` passes43 actual-root checks. A separate subscribed CAS changes the
  workspace while the native Close view confirmation is open; one real confirm
  shows refusal and preserves the exact document/selected duplicate. Dismissal
  and a fresh CmdW/confirm then close only that view, with programs preserved.
  Deferred close/split now retain the original epoch/core/version; current-owner
  identity is checked synchronously even before previous-model teardown ends.
- `hc-close-intent.fV3j0p/presentation`:39 rules/mode including exact large UInt64
  revision comparisons and newer explicit row-selection preservation after a
  pending close. `hc-close-intent-regression.EsV0Mx` macOS Release / iOS Debug,
  wiring12 and artifact rejection tests pass. This is not physical pointer-focus-race proof.
- See `hc-install-service-qualification.md` for the actual pinned source's shared
  launchd/tmp housekeeping and why private HOME alone cannot qualify production
  service/GUI-quit survival in the operator's current namespace.

- Native pane menus now resolve the actual row CellHostingView, open its real
  NSMenu, observe tracking, and perform one enabled item action. No forced flags,
  substitute model closures or global events. The first posted-event route did
  not open a menu (`.a1gj8qmc`); it is retained as failed, not replayed.
- `.imz4ty_f` passes48 checks including zoom/unzoom, grouped1/2-pane effects,
  native New shell to right, exactly one new shell and three rendered terminals.
  Its 16-column original view wraps the ASCII marker. DEBUG weak pane/reference/
  epoch bindings replace screen-text lookup, never confer native-session authority.
  `.f4cp_4dv`'s prior marker lookup failure remains a test failure, not a core-loss
  attribution. Initial notification/AX diagnostic compiler errors remain in logs.
- The pre-fix repeat `hc-screen-app._yyrmefu` passed48
  but `hc-screen-app.hcixk8_t` failed at35: filter value still NO_MATCH, old editor delegate nil,
  actual first responder FocusReportingTerminalView. This is a real reproduced
  ownership regression, not retroactively waived by another pass.
- **Final input-ownership source**: `.g3t2dc7w` and `.181q2zcl` consecutively pass49.
  Native control begin/change/end notifications update ignored ownership metadata;
  older terminal requests fail their input-generation/token guard, passive focus/
  preview restore yields, and late focus callbacks must match the actual responder.
  Both receipts show the actual filter editor retained and all three passive-focus
  gates false. `hc-text-ownership.Z75x8l/presentation`:44 rules/mode plus7 owned,
  never-shown-window notification-seam checks; `hc-input-ownership-release.vAjnZT`
  macOS Release / iOS Debug, wiring13 and artifact rejection tests pass. Physical gestures,
  whole parity and cutover remain false.
- Runner readiness now distinguishes UI_FOCUS_REQUIRED from UI_RUNNING_NO_INPUT;
  current active/key readiness is still mandatory. A late delivered request does
  not justify another click after the running signal or process completion.

- `.xm9fdig6` passes54, then current hint/source `.4e7zeclc` passes55. Real CmdP
  on a missing version0 document offers an acknowledged external fixture program;
  actual Return creates workspace/view in one CAS, preserves PID/creation/live
  state and fabricates no launch receipt. Native CmdW removes its view but not
  the program. Empty state exposes the same shortcut; subsequent49 checks remain
  exercised. No direct switcher/model closure substitutes for selection.
- `hc-discovery.wsQaMa`: canonical-candidate12/mode, official0.1.17 actual-core
  workspace integration61. `hc-discovery-regression.9JgR6K/workspace`:261/mode,
  21 stages including iOS typecheck. That batch then failed obsolete legacy menu
  source guards after all16 native component stages; it is retained as failed.
- `hc-original-ui-current.WsjlyC/run`: all16 original UI component stages and
  corrected command-host + legacy binding/shortcut source checks pass. The
  harness now uses a fresh environment/matching SDK and checks source hashes
  before/after, not inherited provider environment. Physical GUI remains NOTRUN
  for this component suite. `hc-discovery-final.7LR6tm`: current Debug/native55,
  macOS Release, iOS Debug and wiring14 pass. See `DISCOVERY-README.md`.

- `.dv03ndx6` passed57 on the pre-end-UI source: actual CmdT original launcher,
  one real Return creates exactly one Shell and hands keyboard to its bound
  FocusReportingTerminalView. This is not transferred to newer end UI.
- Unselected context close extension `.9pzx86x2` failed owned foreground readiness
  before feature actions; no active/key window was borrowed or forced. Actual
  unselected/end UI now waits for operator readiness rather than blind retries.
- `hc-end-reconcile.GAwbIP` final headless:274 SDK checks/mode (92+32+79+31+40),
  21 stages, presentation48/mode + ownership7, actual official-core76,
  macOS Debug/Release, iOS Debug, wiring15. Failed durable stop reservation sends
  no kill; failed confirmation leaves uncertain, then explicit review confirms
  only by same-origin terminal.get. Unknown/live/done/list absence never means
  ended and no kill is replayed. Schema2 adds partial-pane close while reading
  schema1 old plans without reinterpretation. See `ENDING-README.md`.
- Selected close now immediately retires its input surface and holds model
  fallback hidden during pending work. Newer explicit row intent wins. Stale
  confirmation is refused before UI projection changes. Default native Return
  is declared on view-only close; its actual new-button GUI proof is pending.

- Working-directory regressions were reproduced on official0.1.17:
  `hc-cwd-negative.C0B5Ww` (new current-workspace tab fell back to core HOME)
  and `hc-split-cwd-negative.hud8oy` (default split did likewise). Both negative
  receipts stopped the owned core and reaped clients; neither is reclassified.
- `hc-cwd-origin.0Y8fJR`: actual-core84, SDK274/mode across21 stages,
  macOS Debug/Release, iOS Debug, wiring16 pass. Explicit cwd then saved workspace
  cwd takes precedence; otherwise a same-origin canonical pane GET supplies cwd
  before placeholder CAS changes focus. Imported views preserve workspace cwd.
  Foreign split/end and implicit foreign-context local launch are refused before
  metadata/run/stop changes. No path/label inference, interactive rc or scans.
  UI split no longer passes a cached cwd; dead rejected-header split helpers were
  removed. This is headless/platform evidence, not new native/physical UI approval.

- Recovery review now distinguishes partial-pane/full-tab layout plans and lists
  bounded per-target stop outcomes. Pending/in-flight/uncertain/shared/foreign
  never display as ended. View-only history states no termination was requested;
  known launch layout does not imply restart. `hc-recovery-text.71Slem`:13 pure
  rules/mode, macOS Debug/Release, iOS Debug pass; wiring17 pass. The ScrollView
  is height-bounded and adds no dispatch authority. Actual new review-sheet GUI
  remains part of the foreground qualification gate, not this text-policy pass.

- `hc-preview-history-fixed.aP7AdM`: actual hc preview store/request/model23
  per Debug/optimized mode, macOS Debug/Release, iOS Debug and wiring17 pass.
  Pane/tab histories are separate; tab siblings share one preview. Hide keeps
  its request for original Show Preview, retires its read and resets expansion;
  following a file link within the panel preserves expansion. Source/scroll/find
  survive selection. Exact membership/ref changes invalidate; confirmed missing
  document differs from unavailable data. At128 retained histories one explicitly
  warned transient current slot keeps rendering functional, without evicting
  visited entries. No preview file, credential, network, core or native UI actions
  were used by the component. GUI geometry/attach/control proof is still pending.
  `hc-preview-history.T8ZWOr` failed at component compilation (missing CoreGraphics
  import in test); later platform stages did not run and are not counted.

- Product owner retirement now serializes close/open and repeated replacements,
  tracks pending/initializing RPCs/models, and guards late close phase changes.
  Model disconnect shares one cleanup job. Cleanup uncertainty blocks later
  dispatch. `hc-owner-negative-local.98VrFO` reproduces early replacement/stale
  close inconsistency; `hc-owner-boundaries.WKwFI1` retains the later failed
  initialization boundary (fixture ordering also changed, not a single-fix
  attribution). Final `hc-owner-idempotent.zPStVX`: owner24, workspace84 official
  core, SDK274/mode/21 stages, macOS Debug/Release, iOS Debug and wiring18 pass.
  This is controlled local transport/product-owner evidence, not physical
  host switching, SSH/mobile GUI, production launchd or cutover. See
  `Tests/HcBackend/OWNER-README.md` for exact composition and failure limits.

- `hc-current-compositions.GhRYC7` at c0e13f6: actual product SDK notification
  coordinator28 (OS presenter/permissions remain in-memory seams), conversation
  + mobile cache21, core terminal attach9, original UI component16 stages pass.
  Each actual-core suite confirms owned core/socket/process retirement and denied
  external network. The original UI component uses actual SwiftTerm/owned PTY,
  but none qualifies current whole-app GUI, physical gestures, provider/native
  association, real OS permissions or launchd lifetime.

- Preview read identity follow-up: original `ContentView.previewPanel` gives
  each read model its own view identity. hc now likewise applies
  `previewExpansion` before `.id(previewModel.id)` and isolates the panel in a
  typed view helper. Actual store/model/owned local reader25 per mode pass at
  `hc-preview-panel-split.OEnSpM/component`; that exact component source is
  unchanged by the final modifier-order correction. Final macOS Debug/Release,
  iOS Debug and wiring18 pass at `hc-preview-panel-order.M66qKN`.
  The next bounded native audit now contains actual Show/Hide Preview controls
  and owned-file rewrite/reopen checks, but these new actions are **NOTRUN**.
  `hc-preview-identity.TIie6S` stopped after Debug25 due to runner variable
  shadowing; `hc-preview-identity-fixed.xbUVUu` then failed macOS Debug type
  checking; `hc-preview-panel-split.OEnSpM` isolated the actual error (calling a
  FilePreviewPanel-only method after `.id` changed its type). None of those
  unexecuted Release/iOS stages are counted as passing.

- The pending default-close native audit now sends one actual Return key event
  after resolving the real enabled visible button in the owned key window/sheet
  and checking its Return key/default-cell association. It does not invoke a
  substitute closure/performClick or retry an uncertain key. Fresh before/after
  canonical address/PID/creation/state facts must prove all programs unchanged.
  `hc-default-return-audit.C6fbUY`: macOS Debug/Release, iOS Debug, wiring19 pass.
  The native Return event itself remains **NOTRUN** until foreground readiness;
  neither the explicit end action nor this new Return gate is GUI-qualified.

- Current native `.vf0929fp` failed30 at searched external-view selection.
  It had already exercised the preceding preview Show/Hide/re-read actions;
  this is partial success, not NOTRUN for everything or overall approval.
  Pure `hc-switcher-submit-negative.c2AiZ5` then reproduces submit losing the
  choice when current filtered results no longer contain the old highlight.
  Submit now resolves only current available results (current highlight or
  first available), retaining all parent scope/reference/version guards.
  `hc-switcher-submit-fixed.Mciepe`: original UI16 stages, wiring20, macOS
  Debug/Release and iOS Debug pass.
- Corrected native `.h_45eof_` progresses47: searched canonical discovery,
  unselected context close, stale close refusal, actual default Return view-only
  close with unchanged program incarnation/state, preview re-read and multi-pane
  expansion, native zoom/unzoom/split and filter ownership were exercised before
  failure. `native-default-return.json` confirms the owned enabled key/default
  button and one dispatched Return. It fails at the subsequent raw-drop peer
  readiness marker with the original renderer only6 columns wide. Core input
  loss vs fixture/rendering cause is not established. File/row drop, later native
  launcher handoff, end-programs button and Retry in this exact composition are
  not qualified by this run. Both native attempts retired owned programs/socket
  and staged apps. No further unattended foreground retries are running.

- The47-check raw-drop failure is now isolated headlessly: current product
  SwiftTerm1.20.0 at5d144068 receives the full raw bytes and core text at6/80
  columns, but6-column rendering overwrites the right edge (`HC-DRY`). DECSTR
  resets savedWraparound=false, then normal-screen1049l restores it. Priming an
  earlier saved cursor does not help because DECSTR resets that saved state.
  A separate candidate changing only Buffer's two saved-wrap defaults to true
  passes6/80 while preserving explicit wrap-OFF/alternate restore. There is no
  application VT filtering/extra transport input or core fork. Final
  `hc-wrap-final.3iYpFx`: default attach9 pass, expected renderer negative
  explicitly confirmed, candidate2 viewport cases pass, owned scopes retired.
  At that checkpoint this was a current renderer blocker, not a GUI pass;
  the app dependency had not yet changed. See the resolution checkpoint below
  and `Tests/Terminal/SwiftTermWrap/{README.md,recipe.json}` for retained negatives.

- **Integrated renderer resolution (`298e1bb`, provenance `807cdf7`):** approved
  `Vendor/SwiftTerm` binding pins the same1.20.0 base with just the two saved-wrap
  defaults changed. All151 copied upstream files are sealed; added static build
  identity truthfully names the modified renderer instead of the parent app's
  Git commit. Unrelated working project changes remain unstaged; retained remote
  dependency versions are unchanged. `hc-renderer-direct.Ts3ya4`: selected
  renderer/parser69 (8 new parameter cases), actual product6/80 core/rendering,
  macOS Debug/Release, iOS Debug, original UI component stages and wiring20 pass.
  Each stage exits naturally with zero signals. Earlier compile-success but
  helper-retirement failures remain failed: executable-only attribution found
  `ibtoold`. Final private build env uses this pinned Xcode's direct-exec
  `IBToolNeverDeque=1`, without changing global settings or relaxing teardown.

- **Current native root (`hc-screen-app.j2n293qq`):63 checks pass**, natural exit,
  no runner signals, owned processes/socket/staged apps retired. The narrow raw
  peer marker now renders, so the audit reaches file/row drop, actual launcher
  Return/terminal input handoff, default Return view-only close preserving all
  programs, the separate explicit end button (only consented Shell finishes,
  recovery confirmed, other incarnations preserved), and one enabled Retry with
  fresh model/transport and exact metadata/program preservation. Preview fresh
  read/multi-pane placement, switcher search, context actions and native filter
  input ownership also pass in this current composition. File/row drag here
  exercises production callbacks/provider/destination, NOT physical Finder/List
  drag. `wholeUIParityQualified=false`: repeated fullscreen, physical divider/
  drag/IME, host/profile/remote/mobile/provider identity, and installed service/
  update/handover gates remain open. Core baseline is still official0.1.17;
  legacy default/cutover/removal and release have NOT occurred.

- **Fullscreen/native layout resolution (`ea2a34e`, `192cf7d`, `56f9a44`):**
  `.7e0p4a6j` is failed/22 partial checks (title lookup assumed the main window).
  `.a9i7hvii` is failed/28 partial checks (Preview AX route returned false).
  `.z297kt8j` passes69 through the actual current fullscreen root: three native
  overlay open/close repeats, terminal frame/grid/identity retention, native
  toolbar-owned title editing/refusal, Preview fresh read/expand/two-pane layout,
  controls, launcher, view-only/default Return, separate end action and Retry.
  `fullscreenNativeLayout=true`, `fullscreenSpaceAndEdgeReveal=false`,
  `wholeUIParityQualified=false`. No pointer warp/global event injection/physical
  gesture claim; owned fullscreen exit, processes/socket/staged apps retire.
  Title locator's11 never-shown composition checks and original rename suite8
  stages pass at `hc-fs-title-gates.bbFaSA/title`, including warnings-as-errors
  for the new locator. Platform/renderer/original-UI gates pass at
  `hc-preview-native-gates.zZCCVO`; wiring23. The previous edge-event failures
  remain unresolved. No additional edge-event retry was looped or relabeled.

- **Current native74 (`605eb4a`, `._35qrzu0`):** keeps every previous69
  assertion, adds actual Cancel with unchanged document/version/journal/program
  facts, and a separate view-only close whose exact doc.set bytes are held before
  dispatch. The old selection's input/detail disappears while the document is
  still unchanged; another real row is selected; releasing the original write
  once preserves that newer selection and every program incarnation/state.
  Independent default Return receipts are retained; no cancel/kill/run replay.
  Fullscreen/native layout, exit, owned retirement all pass; edge/physical/whole
  UI/release flags remain false. `hc-close-composed-gates.vggp5Z` platform,
  renderer69, actual6/80, original UI and wiring24 pass. Gate component13 passes
  with the real product SDK at `hc-close-product-sdk.6Wli99`, strict Swift6 and
  network denial. Earlier source-composed gate positives did not catch the
  imported protocol's MainActor isolation: `hc-close-native-gates.EFmphU` retains
  the actual Debug compilation failure, later stages NOTRUN. Fixed with a
  nonisolated Sendable facade/internal actor, not weaker SDK isolation; the
  component now imports the actual product SDK. No source action closure
  substitutes for real dialog/default-key/row actions.

- **Direct SSH/product owner current-source checkpoint:**
  `hc-ssh-current.dd56aQ`39, `hc-ssh-discovery.oYJDse`40 and
  `hc-ssh-owner.7kPVHd`45 functional checks complete with owned retirement;
  each overall validation remains passed=false for the unchanged official0.1.17
  initial/reconnect OSC8 loss (live link works). The strengthened server now
  executes the exact production discovery script, rather than substituting the
  explicit-binary exec. A private selected executable proves inherited terminal/
  socket/config authority was cleared and requested session kept exact.
  Product HcMachineConnection local -> approval -> SSH -> local -> close verifies
  actual old-model retirement, no credential read during discovery/local phases,
  fresh approved pinned connection and unchanged owned program incarnation.
  These are transport/profile tests to the SAME private origin, not multi-origin
  cache isolation or actual profile-switch GUI. See SSH-PROFILE-README.md.
  Read-only2026-11-07T02:32:38Z upstream check still finds PR117/118 OPEN/unmerged;
  gateway alias/permanent-ID ambiguity remains fail-closed. No released fix or
  baseline change is inferred from the failed latest-release lookup.

- **Native distinct-origin78 (`072d304`, `2c846d9`, `c5e0001`, `25d09a2`):**
  `.2_78xs23` passes all previous74 plus real Settings Make Active and exact
  host-key approval to a distinct owned loopback-SSH core, its actual native
  row/rendered marker without the old preview, local return and both origins'
  program survival. This uses production SDK factory/owner; the local fixture
  override is no longer incorrectly offered on remote profiles. App/sidecar
  exit naturally with no signals; both sockets/programs, temporary credential
  and staged apps retire. `directSSHProfileUI=true`, wholeUIParityQualified=false.
  `.ll0ckext` preflight policy syntax failure and `.l7ud19wa`74-then-row failure
  remain failed. Stronger headless pane/live metadata and a native Show Sidebar
  readiness path precede the later pass; no forced visibility/model selection.
  `SSH-PROFILE-README.md` documents fixtures, limitations and exact evidence.
  No physical, gateway mutation, real SSH-account/service/provider qualification
  or release/default-backend cutover is inferred.

## Evidence retained

- `/private/tmp/hc-ui-behavior-audit.KpGlYF`: presentation rules19 per Debug/optimized;
  shared native sidebar136 checks, minimum-size cases and selection-style48 checks.
  Real fullscreen/pointer is explicitly NOTRUN by these never-shown-window gates.
- `sidebar-{legacy,restoration-red,collapse-red,width-red}` in that root retain
  deliberately failing child tests. Each negative validation stays passed=false;
  the controller only confirms the expected failure and owned cleanup.
- Matching Xcode SDK/plugin and fresh environment are used; no Swift5 fallback,
  concurrency weakening, privacy grant, other-app activation or full-disk scan.

## Actual hc-root driver results and retained failures

A dedicated `--layout-audit` now seeds only the owned official core and uses the
real hc root/terminal, rather than a replacement UI. It measures terminal native
frame/grid/identity, native sidebar width, explicit pin/collapse/reopen and program
PID/creation/liveness. `--fullscreen-audit` is a separate opt-in for an owned
fullscreen Space and public pointer/self-event edge reveal, with bounded cleanup
and pointer restoration; it never posts global input or borrows another app's AX
or activation. Its existence is **not evidence it passed**.

- `.ly5w_e8z`: failed at identifying the actual sidebar toolbar control; retained.
- `.91bt_q27`: failed before a qualified native-action result; retained.
- `.rnad0nwy`: helper/app never become active, no activation-yield receipt. Actual
  foreground readiness failed before toolbar geometry/actions. No automatic
  foreground retry continues; never remove that guard to make this green.
- `.olimvpha`: actual hc root/native toolbar7-check ordinary-window audit passes.
- `.a80de2wh` and `.k4nmh32a`: **real fullscreen failures**, not toolbar/readiness
  failures. Edge reveal tiled the sidebar: terminal moved360pt, width1714→1354,
  columns212→167. Same root controller; real program retained. Geometry/grid/
  resize receipts retained; cleanup returned from fullscreen.
- `.osvbwg79`: corrected actual fullscreen audit passes7 checks. Before/after
  terminal frame `[7,59,1714,1018]`, grid212×63, **zero** resize events during
  reveal. Actual edge reveal, pin/collapse/one-button reopen, exact program
  liveness/PID/creation, fullscreen exit and pointer restoration verified. Source
  `/private/tmp/hc-fullscreen-overlay.9lrMpl/macos.log`. No global event posting,
  borrowed grants, private APIs or forcing enabled state.
- The fix uses public `minimumThicknessForInlineSidebars`: while fullscreen and
  unpinned, keep the inline threshold just above current window width; AppKit can
  reveal the native sidebar as an overlay. Explicit pin, exit, detachment and
  teardown restore the previous threshold. No replacement drawer/reparenting.
- All known owned app/core/holder/program/connect identities, sockets,
  registrations and staged copies retire. Controller failures are not silently
  reclassified as successful GUI qualification. Matching-source Debug builds
  succeed. One historical fullscreen pass does not qualify repeat reliability; retention failed on later runs. This is not the full
  UI audit: physical divider drag, multiple panes and preview/other workflows
  remain **open**.

Toolbars can be hosted outside content/inside auxiliary fullscreen windows. The
driver now finds its own native NSToolbarItem by stable identifier and chooses a
public native button/action/hosted-AX route before a single dispatch. These routes
are scoped to the fixture app's actual active/key window and visible/enabled
native item, without forcing flags or retrying an uncertain action. The native toolbar route was subsequently executed in the successful ordinary
and fullscreen actual-root audits. No earlier failed run is reclassified.

Do not give an overall UI preservation or release approval until open rows have
actual evidence or an explicit operator-approved scope decision. Run the audit as
one inventory, not as a sequence of issues for the operator to discover.
