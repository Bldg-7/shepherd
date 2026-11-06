# Explicit close/end boundary — GUI qualification pending

Default `closeTab` / `closePane` remains **view-only**. A separate explicit
`endPrograms: true` action closes the selected view(s) then makes at most one
first stop attempt per eligible canonical program. It is not native-session or
PID-derived authority. The actual native end button/default Return behavior must
still be exercised with genuine owned active/key-window readiness.

## Ordering and scope

1. Caller retains current owner/profile/epoch/core/document-version confirmation.
2. The journal saves the exact close membership/targets before layout dispatch.
3. One exact-version layout CAS must be acknowledged before any stop reservation.
4. Fresh direct-origin metadata and canonical terminal facts are checked. Known
   shared views are kept; foreign-origin end requests fail before layout change.
5. `beginStop` durably marks in-flight before returning its one dispatch ticket.
   Failed persistence yields no ticket and no kill. Another record's uncertain
   stop cannot be replayed by reopening the same program under a different tab.
6. A fresh matching finished read confirms completion. Timeout/cancellation/lost
   confirmation stays uncertain; review performs only GET/reconciliation, never
   another kill or adoption from an operation label.

These reads are **not** atomic shared-view/configuration/process-incarnation
leases. The confirmed action targets the current logical terminal on the selected
core; stopping it can affect other clients viewing the same program. The selected
0.1.17 local terminal resolver parses IDs before mutable names; this does not fix
its separate gateway core-ID/name shadow issue, and no unsafe remote action is
inferred from this local operation.

## Journal and UI

Journal schema2 adds partial-pane close membership. Schema1 full-tab/launch
records remain readable without reinterpreting old pane fields. Per-record limits,
origin scoping and persistence-before-ticket are retained; uncertain outcomes are
not quota-evicted or silently reset on reconnect.

The first confirmation action remains `Close view`, with the declared default
keyboard action. The separate destructive end action is offered only for known
local canonical running references. Selected-close UI intent hides the closing
input surface and suppresses reconciled fallback while asynchronous work ends;
a newer explicit row intent wins. Stale confirmation is refused before that
projection changes. Shared/foreign/unknown outcomes are never presented as a
confirmed process stop.

## Test boundaries

- SDK lifecycle tests cover partial close, exact-member/ref validation, schema2
  crash restore, schema1 compatibility, shared siblings, failed durable stop mark,
  cross-ticket uncertain-stop blocking and live/done not meaning finished.
- Actual official-core tests create only owned sleepers and verify explicit end,
  sibling survival and shared-view survival. Extra injected persistence failures
  distinguish no-dispatch from post-kill uncertainty; an ended read resolves the
  latter without another stop. Owned PID receipts precede termination.
- Base evidence: `hc-end-sdk-fixed.ttwGWU`273 checks/mode,21 stages and actual-core68.
  Final headless `hc-end-reconcile.GAwbIP`:274 checks/mode,21 stages, UI-intent48/mode
  plus7 unshown ownership checks, actual-core76, macOS Debug/Release, iOS Debug and
  wiring15 pass. Reservation-save failure leaves the same owned program live;
  confirmation-save failure leaves uncertainty until direct finished read review.
  No signal is replayed. Native controls remain a separate unqualified gate.
- Earlier failures remain failures: `hc-end-sdk.bk0h51` (test inline actor Data
  crossing; fixed by isolating its value), `hc-end-boundaries.0AJoiQ` (missing
  explicit test saveFocus callback), `hc-end-boundaries-fixed.yxOcwH` (review did
  not reconcile stop outcomes; caught by actual-core assertion). The last exposed
  a real missing model path, now corrected with current-origin GET only.
- Native launcher creation had passed57 at `.dv03ndx6`; unselected-close extension
  `.9pzx86x2` failed **foreground readiness before feature actions**. Neither that
  nor SDK tests qualify the new native end button, physical gestures, service
  lifetime, whole migration or release cutover.
