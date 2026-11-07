# hc capture launch provenance — staged, NOT live capture parity

The existing capture API requires legacy herdr session/pane/terminal fields.
Putting a core ID or an hc terminal into those fields would fabricate legacy
identity and merge namespaces. The new Foundation-only hc values deliberately
use separate explicit wire fields instead.

## Implemented value boundary

- AgentProxyHcCaptureIntent: schemaVersion1/kind=hc, bounded ASCII originCoreID,
  real launch UUID and pane UUID. No terminal exists until a known run receipt.
  Legacy session/herdrSession or premature terminal fields are rejected.
- AgentProxyHcCaptureBinding: exact intent + canonical generation1 terminal ID;
  construction requires the receipt's origin and rejects a different origin.
  Syntax validation does NOT establish that a real receipt occurred.
- AgentProxyHcRouteState: kind/version + pending intent, then one exact bind.
  Another origin/launch/pane cannot bind; repeated identical bind is rejected,
  not silently rebased or replayed. None of these values grants provider-native,
  PTY input, browser, MCP, credential or process-kill authority.
- HcCaptureRouteJournal: serialized bounded metadata store, maximum512 records/
  1MiB, unique origin+launch even across different panes. Returns a generated
  capability only after file acknowledgement; persists only its SHA256, never
  the token/URL. Actual StateDirectory0600 atomic file+fsync plus directory fsync.
  Any persistence error latches the instance unavailable, including lookup,
  because the file might have committed. Explicit reconstruction validates the
  stored state and cannot replay a committed create/bind/remove. Damaged/unknown
  schema, duplicates and excessive count fail closed; no silent reset/eviction.

## Qualification and limits

`hc-capture-state.3jvbE4` passes pure intent/binding/state gates in Swift6
Debug/optimized plus iOS typecheck; thousands of generated terminal syntax
cases compare against the real SDK CoreTerminalID source. The original legacy
control DTO roundtrip remains byte/field separate. `hc-capture-journal.NsJMxB`
passes initial journal tests in both modes with real linked Crypto product and
private file persistence. Strengthened `hc-capture-journal-final.tDRwtt` passes35
checks/mode including possibly committed bind/remove errors and fresh reload
without replay. Scope/state gates pass6040/mode plus iOS typecheck. Both are no-network/no-service/no-CLI unit gates,
NOT real proxy, launch, recorder, provider, native-session or GUI qualification.

```sh
python3 -B Tests/HcBackend/run-capture-scope-tests.py --output /private/tmp/<fresh>
python3 -B Tests/HcBackend/run-capture-journal-tests.py \
  --products build/DerivedData/Build/Products/Debug --output /private/tmp/<fresh>
```

## Existing capture process regression repaired

`hc-capture-forwarder.ZqaQLc` builds and passes in-process forwarding, then
fails process lifecycle (8 pass/4 fail). The strengthened old-binary negative
adds immediate-stop coverage:8 pass/5 fail; termination receipts show SIGTRAP-5,
not default SIGTERM-15. Do not claim the publication gap alone explains it.

The executable now constructs its signal callback inside a nonisolated lifecycle
object before listener publication and serializes startup/shutdown on one queue.
It removes the unsafe mutable top-level server reference, cleans partial startup,
and cannot turn startup failure into a queued successful stop. This changes both
callback isolation context and lifecycle ordering; neither diagnostics nor exit
criteria were loosened. No user daemon was restarted/replaced.

`hc-capture-lifecycle-fixed.lJ0WhU`: fresh actual package build,26 forwarder cases,
13 process cases (including10 immediate published-status/SIGTERM repeats), read
socket and SSH line stages all pass naturally/zero runner signals. The secret
scan finds none of the sent secrets in413 retained non-source files. This is a
regression of existing capture plumbing, NOT hc route/read/native-session parity.

## Required integration sequence — no shortcut by relabeling

1. Add hc-specific control/authority envelopes; do not place values in legacy
   session columns or invent legacy terminal IDs. Preserve reading old archives.
2. Thread hc origin namespace through request classification, conversation keys/
   context, recorder authority and persistence/read APIs. Same native ID on two
   cores must remain separate; a new route is not itself a native-session proof.
3. Explicitly handle requests arriving while a launch intent is still unbound.
   A pending capture must not be shown as a terminal-bound conversation. Preserve
   forwarding independence; capture admission cannot block the provider stream.
4. Integrate the durable launch ticket/route reservation/exact known run receipt
   without replay/adoption after uncertain dispatch. Only an explicitly opted-in,
   verified existing proxy may receive configuration; no auto-install/restart of
   operator services or copied provider credentials. Browser/AgentRuntime
   injection remains deferred; unknown CLI/native metadata fails closed.
5. Qualify the whole app/SDK/forwarder/recorder composition with private fake
   upstreams and actual core, then provider/session and UI gates as separately
   authorized. Token secrecy and record-before-mutation failure receipts remain
   mandatory. Unit success is not permission to mark the migration complete.

The journal is currently NOT exposed by live control/forwarding methods. Existing
AgentProxyControl protocolVersion1 and legacy writers are unchanged. No user
route, service, capture database, account setting or installed tool is mutated by
this staged work.
