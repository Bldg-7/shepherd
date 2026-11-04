# Explicit saved-operation review (SHPHRD-152/153)

The hc sidebar offers **Review tracking** for unfinished operations and a
**Completed operation history** disclosure. Completed metadata was otherwise
invisible while still consuming the bounded 64-record journal; nothing is now
automatically evicted to reclaim that quota.

## Human flow and safety

1. **Review** performs a fresh subscribed document read, then reconciles metadata
   only. Orphaned in-flight bookkeeping becomes uncertain, not evidence that a
   server RPC failed/cannot still arrive. A completed layout action is not
   reinterpreted as unfinished when a later user edit removes it.
2. The sheet freezes the operation, model generation and exact reviewed UInt64
   version. Layout commands/settings/switcher are disabled while it is open.
   A changed document cannot silently substitute a newer baseline for consent.
3. **Apply reviewed layout once** is offered only for a known successful run
   receipt whose original pane remains unbound, or a close whose tab still has
   exactly the reviewed members. It persists a new current-epoch layout attempt
   before one CAS. Conflict/uncertainty requires another read and human review.
4. **Forget tracking only** requires a separate confirmation and removes only
   journal metadata. It does not terminate, restart or adopt a program. It is also
   how a person explicitly releases completed journal quota.

No launch or stop is replayed, no run is inferred from labels/PIDs/status/screen,
no native/browser authority is minted, and no unknown run gets a binding ticket.
Shared/changed target fields are never overwritten by a rebased metadata edit.
Old tickets remain stale after reconnect; only explicit reviewed layout intent
is rebound to the new journal session/epoch. Failure to persist yields no attempt.

## Evidence and limits

- `/private/tmp/hc-review.9auGWf/unit`: **88+32+66+31+40 = 257/mode**, strict
  Swift6 Debug/optimized, 21 stages plus iOS17 typecheck. Includes rollback floor,
  cross-epoch reviewed CAS, persistence failure, exact run receipt, no completed
  replay, unknown-run rejection and concurrently changed close members.
- `real-final`: **56 actual private-core checks**. A restored model reviews an
  intentionally uncertain layout record with an earlier owned run receipt;
  concurrent rename invalidates the first review; only another explicit fresh
  review binds it. Completed/forgotten/canceled plans do not replay and program
  count/liveness is unchanged. Own connection children/core/holders/programs
  are tracked and retired by the fixture. The lost metadata outcome is a
  controlled bookkeeping fixture, not a claimed transport-loss injection.
- `macos-final.log` / `ios-final.log`: Debug Swift6 builds pass. Native
  recovery-sheet interaction has **not** been UI-automated; the independent
  foreground/key-window gate is still required, not replaced by model tests.

Retained failures include a real-test enum argument label typo and a Swift
compiler crash while diagnosing assignment to the implicit `catch error` rather
than the state property. The property assignment is made explicit; isolation,
Swift6 and compiler diagnostics are not weakened or suppressed.
