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
| Fullscreen sidebar | `WorkspaceSidebarState`, `SidebarPeekREADME.md` | Same shell is necessary but not sufficient. Initial native restoration, reveal without pin, pin while revealed, dragged collapse, one-click reopen, width constraint and real terminal identity/grid must all hold. Shared native component positives/four negatives pass. Actual hc fullscreen failure was then reproduced (1714→1354pt,212→167 columns) and corrected with the public native inline-sidebar threshold only while fullscreen/unpinned. One actual-root7-check pass preserved grid/pointer/Space, but repeated drawer-retention checks failed afterward. Fullscreen reliability remains **RED/open**, including multi-pane/preview/physical-drag cases. |
| Detail hosting topology | `ContentView.workspace(on:)`, `WorkspaceDetailSplitView` | Found preview split inside each hc pane instead of beside the whole tab. Moved one native preview split to the detail root. Current two-pane ordinary-window audit measures non-overlapping pane frames and detail-level preview; no persistent pane header. Fullscreen topology remains open. |
| Terminal gutter/focus | `TerminalPaneFrame`, original pane/tab terminal views | Found missing7pt gutter and different1pt focus border. Reuse original frame; focus indication now follows actual keyboard focus, not persisted last-pane selection. Needs current app geometry/focus proof. |
| Pane/tab mode | `ContentView.onChange(showsTabs)` | Found old selection retained instead of cleared. Presentation state now clears the UI selection and prevents unchanged model focus from resurrecting it. Pure rules and current ordinary-window mode/selection clearing checks pass; fullscreen interaction remains open. |
| Row activation | `BoardRowActivation`, original focus request path | Found same-row click had no way to return keyboard to an already mounted terminal. Added typed epoch/pane/token request; no force activation of another app/window. Current ordinary-window audit exercises same-row activation returning keyboard from the filter; fullscreen interaction remains open. |
| List navigation | Original binding vs explicit row activation | List selection must not steal keyboard while moving in the list. Explicit activation is separate and can restore keyboard. Pure presentation rules cover this separation. |
| Selection removal | Original board reconciliation | Closing selected view must not immediately display a reconciled fallback. New state suppresses that stale UI restoration; closing an unselected view must not clear the selected view. Exact event/race coverage still open. |
| Split/zoom controls | Original pane framing/layout | Removed extra hc-only persistent pane header. Explicit new-shell/zoom actions stay in secondary pane actions, not new visible header geometry. Split geometry/resize/current program survival need integrated tests. |
| Preview placement | Original detail-level adjacent panel | Preview is beside the whole terminal/tab, not squeezed into an individual pane. Side minimum320/ideal560. One native host and divider proportion persist. Shared split component proves host stability; current tab composition still to measure. |
| Preview expansion | Original covering panel | Expanding must cover rather than destroy/reparent live terminal. Root covering host retained; terminal hiding is accessibility/hit-testing only. Needs current attach-count/input/PTY proof. |
| Preview history | Existing per-selection preview state | Bounded hc cache keys epoch + pane UUID + exact reference; stale/removed reference pruned, no silent eviction of another visited pane. Return from another pane must restore at side, not fullscreen. Further tab-level comparison open. |
| New Tab | Original `NewTabLauncher` | Actual original launcher used; separate CmdN/CmdT intent. Standalone CLI mode is not browser permission. Private inspection now Shell-only; real installed CLI integration is not inferred from a menu choice.69 actual launcher component checks pass. |
| Failed launch | Existing launcher handling plus durable hc recovery | Public stable failure formatting, no internal NSError name. Unsupported inspection intent rejected before workspace/placeholder creation. Uncertain prior run never auto-deleted/adopted/replayed. Missing real CLI/race error UX remains separately reviewed. |
| Title editing | Original title double-click/IME field/native toolbar | Same real field/toolbar implementation with typed hc target, epoch/version guard. Component tests cover simulated composition, stale callbacks and geometry. Current actual-root ordinary-window audit exercises native title-label double-click/local event monitor, real editor/Unicode submit, Escape without metadata change, title restore and no window zoom/layout replacement. Actual competing-CAS refusal also passes: the old title session cannot overwrite a newer layout snapshot. Physical IME/fullscreen rename is open. |
| Switcher | Original deferred onDismiss navigation | Found selection/focus applied before sheet dismissal. Defer with exact epoch/pane/terminal reference check; reject stale retarget. Shared original switcher presentation used. Current ordinary-window audit exercises Cancel and Return/dismissal/keyboard return; stale-scope dismissal remains a separate gate. |
| Closing | Original command/context confirmations | Explicit view close keeps programs; current selection required, cover disables close. Current native CmdW/confirmation closes only the selected duplicate view and leaves selection clear/programs live. Competing-CAS close refusal/reopen passes43 checks; unselected/context-menu close and post-dispatch pointer-focus races remain separate gates. |
| Quit with sheet | Original presentationPreventsAppTermination(false) | Added original behavior to transient settings/switcher/origin/tracking/install sheets. Needs actual CmdQ/owned service survival gate. |
| Viewed/attention | Original key-window + actual selected pane/tab | Found hidden tab siblings marked viewed in pane mode and app-active used without key-window check. New policy uses actual rendered mode/zoom/selection + key window. Pure rules covered; OS notification behavior remains unqualified. |
| Scope changes | Existing exact machine identity / connection provenance | Clear overlays and deferred navigation; typed epoch/reference keys for previews, focus, switcher. No alias/PID/label is native authorization. Native Retry is exercised; exact current owner-model identity now joins profile/epoch guards at board actions, attach/input/drop/upload and title submission. Full host switching and physical cross-window interactions remain gates. |
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
  succeed. Single-pane actual-root/fullscreen checks are now proven, not the full
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
