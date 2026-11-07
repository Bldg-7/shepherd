# hc capture launch provenance — staged, NOT live capture parity

**Deferred by operator scope decision.** Capture-based message collection and
mobile structured conversation display are excluded from this migration, like
in-app browser/runtime injection. Keep the implementation and historical evidence,
but do not continue launcher/token/bootstrap/provider-session work or require
capture parity for hc cutover. The follow-up sequence below applies only if this
feature is explicitly brought back into scope. Existing archives/user services
remain untouched. See [current scope](../../docs/hc-migration-scope.md).

The existing live route/control API requires legacy herdr session/pane/terminal fields.
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

## Explicit conversation namespaces and receiver integration

The staged recorder receiver now understands separate legacy/hc Open and
supervisor RouteSnapshot fields. Exactly one namespace is required; HC authority
on an existing route ID can advance only from the same pending intent to its
exact binding. Downgrade, terminal rebind, origin change, legacy adoption and
mixed envelopes fail closed without acknowledgement. Opens require the exact
current snapshot, while an already-admitted pending response can finish and
persist after a forward-only binding. Its historical context remains pending;
no retrospective terminal provenance is fabricated.

Conversation keys use byte-exact tagged herdr/hc origins. On one core, native
session identity can outlive a launch route; the context retains that route's
real launch/pane UUID and optional terminal. Schema2 archives accept v1 only in
its legacy namespace. SQL schema2 migrates v1 in one transaction, retaining its
IDs/item bodies/legacy scope; pending hc uses NULL terminal and explicit bounded
metadata. Foreign-key failure rolls back version/schema/items, and contradictory
hc agent/binding/terminal records are refused before insertion. No user archive
has been opened or migrated by these tests.

The read API adds explicit hcCoreID/launch filters; mixed scope queries fail.
Legacy terminal/native-only filters cannot adopt hc records. Legacy DTO encoding
still omits hc fields. Read protocolVersion remains1: updated clients validate
explicit hc metadata; older strict clients may reject an unfiltered archive
containing hc summaries rather than invent a session/terminal. This is fail-closed,
NOT deployed old-peer archive compatibility qualification. The shared client
selects hc only with an exact known binding or explicit scoped native ID; capture
metadata remains distinct from provider-native/input authority.

Mobile explicit archive selection now follows the listed epoch + opaque record
ID + tagged key, not a second terminal/native lookup. An epoch reset refuses a
replacement with the same native ID and asks to reopen history. This preserves
read-only archive navigation without borrowing live hc terminal authority.

Current staged evidence (not provider/launch/control parity):
- `hc-capture-authority-core-fixed.aFBI0W/run`:5862 checks/mode, plus iOS typecheck.
- `hc-capture-authority-package-fixed.V6E4Jt`: actual package,26 forwarder and13
  process cases,154 actual recorder socket checks, SSH line pass;423 retained
  non-source files contain none of the sent secrets. Trusted synthetic fd3 hc
  snapshots cover namespace isolation, pending response completion after bind,
  and invalid authority rejection. The final SQL FULL-durability source repeats
  all stages at `hc-capture-package-durable.pobLaU` with the same counts and
  natural/zero-signal retirement.
- `hc-capture-sql-rollback-fixed.g6mtwT`:56 checks/mode, network denied. Failed FK
  migration leaves v1 schema/version/items intact; explicit fixture repair and
  pending/bound hc close/reopen preserve the original logical records.
- `hc-capture-client-archive-fixed.OQMOXe`:27 client and11 model checks/mode,
  iOS typecheck. Actual iOS app/runtime qualification remains separate.
- `hc-capture-v1-upgrade.EExkoz`: an actual retained schema1 recorder binary
  writes its own private archive; the current binary migrates it and preserves
  all common row/item bytes and IDs, then restores the exact legacy native key
  and appends a new response. Both programs exit naturally, their socket is
  removed, and IP bind/connect canaries are policy-denied. Binary/script SHA256
  receipts are retained. This is not an operator database upgrade.
- `hc-capture-platforms-bound.iIJb0t`: actual macOS Debug/Release and iOS Debug,
  renderer69, official-core 6/80 render, original UI and wiring25 pass naturally,
  zero runner signals. No GUI/physical/mobile-runtime gate was rerun or inferred.
- The first receiver build failed because nested `AgentProxyTeeFrame.Decoder`
  shadowed Swift.Decoder; explicit qualification fixed the type, not diagnostics.
- The first app composition failed because the bundled Xcode tool target listed
  only main.swift and omitted ForwarderLifecycle.swift. The target now explicitly
  includes the source; no Swift language/concurrency setting was lowered. Later
  stages of that failed app run were NOTRUN.

## Peer-verified hc control and whole forwarding/recorder path

The separate `hc.routes.create`, `hc.routes.bind`, `hc.routes.list` and
`hc.routes.remove` methods now reach the journal. New methods verify the bound
control socket and actual same-UID peer; requests are bounded/duplicate-key
checked through the existing public decoder. NIO callbacks access handler/context
through NIOLoopBound on their owning loop, not a widened unchecked conformance.
Creation takes a pending AgentProxyHcRouteState and returns its capability only
after durable acknowledgement. Bind takes an exact route UUID + received binding;
identical replay is refused. List contains non-secret pending/bound state and
subscription rejection, never token/hash/URL. Removal synchronizes recorder
revocation when a child exists. A failed acknowledgement can be post-commit;
inspect the exact origin/launch, do not replay a mutation.

CaptureRouteRegistry feeds both tagged metadata cases into the existing fixed
upstream forwarding rules and ordered supervisor publication. No hc ID enters
legacy identity fields. Legacy writers remain during staged cutover and the
combined authority count stays bounded. Subscription rejection is monotone and
durable; older staged journal entries lacking that flag decode as not rejected.
Capture admission/persistence does not queue or gate the raw provider stream.
Unknown-route forwarding retains the prior fixed-upstream/no-copy behavior, not
an invented identity or a new upstream capability.

Evidence:
- `hc-control-product.YTHB0R`: build failed on private Core helper access. The
  internal API was not made public; subsequent stages were NOTRUN.
- `hc-control-product-fixed.yqCgzI`: product modules compiled; test build failed
  on Data vs byte-array secret-scan input. Runtime stages were NOTRUN.
- `hc-control-product-scan-fixed.cNrLWn`:27 actual forwarder +13 process cases,
  read-socket/SSH line stages,427-file secret scan all passed naturally.
- `hc-control-recorder-sql.PyDrFq`: build passed, forwarding27 pass/1 fail.
  The new harness reused a one-query read connection and got EOF. The protocol
  was not changed to hide the failure; later stages were NOTRUN.
- `hc-control-recorder-reads-fixed.lorPn9`:28 actual forwarding +13 process
  cases,154 recorder socket checks, SSH line stages and434-file secret scan pass.
  New coverage runs peer-verified control→private TLS upstream→actual recorder→
  bounded conversation output and an independent read-only SQLite connection
  observes a committed bound hc row. Pending records have no legacy session or
  terminal; binding retains the native conversation ID, and removal waits for
  the real child then retires live capture state. This uses synthetic trusted
  intents/receipts/CLI headers, NOT a real CLI/core launch or native-session proof.
- `hc-control-journal.SWQkxg`:39 checks/mode with durable subscription rejection
  and old staged-entry compatibility. `hc-control-platforms.FzVA2S`: current
  macOS Debug/Release, iOS Debug, renderer69, official-core6/80, original UI and
  wiring25 pass naturally/zero signals. `hc-control-core.5Qe6DW/run` repeats5862
  checks/mode and iOS typecheck with the current protocol sources. No new
  physical/GUI gate is inferred. Cleanup retires47 exact owned targets/~3.971GiB
  after process/build checks; source, failed runs, private archives and current
  control Products/Debug for the next launch gate remain retained.

## Deferred follow-up sequence — not current migration acceptance

1. Integrate the durable launch ticket/route reservation/exact known run receipt
   without replay/adoption after uncertain dispatch. Pending historical metadata
   must not acquire a fabricated past terminal. Same native ID on two cores must
   remain separate; a new route is not itself a native-session proof.
2. Only an explicitly opted-in, verified existing proxy may receive configuration;
   no auto-install/restart of operator services or copied provider credentials.
   Browser/AgentRuntime injection remains deferred; unknown CLI/native metadata
   fails closed.
3. Qualify app/SDK/forwarder/recorder plus actual core and private fake upstreams,
   then provider/session and UI gates as separately authorized. Token secrecy and
   record-before-mutation failure receipts remain mandatory. Unit success is not
   permission to mark the migration complete.

The launcher is NOT yet connected to these hc control methods. In particular,
the old service's legacy route sweep/off/restart policy must not govern hc launch
reservations: a route-list snapshot is not a service-retirement lease. Service
and handover qualification remains blocked on the approved disposable namespace.
AgentProxyControl protocolVersion1 retains its legacy methods unchanged; new
methods have an explicit hc namespace and an old peer refuses them. No user
route, service, capture database, account setting or installed tool was mutated
by this staged work.
