# Independent capture history during the hc migration

This restores **explicit read-only archive browsing** from the production mobile
hc board, without connecting to legacy herdr or guessing a native session from
an hc terminal ID, status, title, PID or screen. The account's existing capture
endpoint/data remain separate from the terminal backend. No proxy, provider,
AgentRuntime, browser or global configuration is started or installed by reading.

## Implementation and scope

- `ConversationClient` now depends only on `ConversationLineTransport`, not the
  legacy terminal transport. Its explicit `list()` returns bounded validated
  archive metadata; old `herdrSession` wire fields/data stay compatible.
- `ConversationLineConnection` owns at most eight pending/active byte streams.
  Each request is one <=64KiB NDJSON line; each response line is <2MiB with at most
  two queued lines. Overflow/partial EOF is an error, never a dropped delta.
  The 15-second first-reply deadline includes startup/write. Quiet subscriptions
  have no post-reply idle timeout. Owner close/cancel/deinit retire their own
  transports; late factories cannot start/authenticate after retirement, and
  cleanup failures are visible and fail closed.
- `MachineStore+Conversations` uses a fixed UNIX capture socket on the selected
  account. The local bridge is an owned `/usr/bin/nc -U` child. Paired Macs use
  the existing pinned non-PTY SSH byte transport with a fixed nc command and
  `$HOME` quoted as data, never arbitrary caller shell/path text. Local nc gets
  only HOME/PATH/LANG; remote nc runs under `env -i` and never inherits agent
  sockets, provider tokens or injected client configuration.
- Remote history preserves the existing paired-Mac-only contract. Missing
  approval and invalid paired-address ranges fail before reading a credential;
  DNS is resolved once and bound to the validated address. It does not reuse a
  gateway's SSH identity to assume ownership of a different account's captures.
- `CaptureHistorySource` serializes retirement, validates current saved machine
  identity and prevents a late cleanup from retiring a newer refresh.
- The mobile archive list selects a stored native key explicitly. Detail has
  paging/follow but **no terminal composer/input**. Changed/removed profile scope
  hides stale content immediately and closes the owned read connection.
  Scene changes/disappearance retire streams. Korean/Japanese UI text is added.

**Not complete capture parity:** newly launched hc CLI capture configuration,
route provenance and its live-terminal conversation association are not yet
integrated. This does not infer native/browser authority, automatically associate
an old archive with `t7`, or claim a real provider/session was qualified. Mobile
SwiftUI is compiled, not iOS UI-automated.

## Gates and exact evidence

```sh
python3 -B Tests/HcBackend/run-conversation-line-tests.py --output /absolute/fresh/run
python3 -B Tests/AgentProxy/run-core-tests.py --output /absolute/fresh/core
python3 -B Tests/AgentProxy/run-client-tests.py --core /absolute/fresh/core --output /absolute/fresh/client
python3 -B Tests/HcBackend/run-conversation-ssh-tests.py \
  --products build/DerivedData/Build/Products/Debug --output /absolute/fresh/ssh
```

- `/private/tmp/hc-capture-lines-final.VP7mJR/run`: **25 checks per mode**,
  strict Swift 6 Debug/optimized, Foundation-only mocks, no network/core. Covers
  framing/Unicode, overflow/partial EOF, capacity, invalid requests, late canceled
  factories, owner deinit and visible cleanup failure.
- `/private/tmp/hc-capture-integration.QhyQrI/core-final`: **5,837 per mode**
  capture-core tests; iOS 17 typecheck, external network denied.
- Same root `client-final`: **19 client + 9 model checks per mode**, iOS 17
  typecheck; synthetic real Core read-API values, no provider/SSH.
- `/private/tmp/hc-capture-current.uUbLCm/ssh`: **11 checks**, actual ephemeral pinned loopback SSH executes
  the actual nc command against an owned UNIX peer. Wrong pin/credential fail,
  Unicode arrives, no PTY/core/herdr handshake, exactly one child PID is recorded
  before close and verified reaped, socket removed, external TCP canary denied.
  This tests SSH plumbing with an in-memory password, **not real paired-device
  Secure Enclave authentication** or a real user's archive.
- `/private/tmp/hc-capture-current.uUbLCm/source`: **28 combined app notification/history-source checks**
  over an owned actual core and fake OS presenter. Includes stale profile/late
  refresh rejection, zero credential reads during preparation, and approval/range
  rejection before credential access. No native alert/permission UI is exercised.
- `/private/tmp/hc-capture-current.uUbLCm/{macos,ios}.log`: Debug builds pass. They do not replace GUI qualification.
- `nc-eof-probe.json`: macOS nc maps stdin EOF to UNIX socket EOF and exits 0
  once the private peer closes. No OpenBSD `-N` assumption (Apple uses that flag
  for another option).

Earlier failures remain: strict actor-initializer test setup; an initial parallel
compiler stage exited 0 but its process inspection timed out (overall nonzero),
then a serial/j2 run passed; SSH fixture actor/NIO setup; attempted removal of a
socket already removed by NIO; PID capture taken too late after reap. Final SSH
records the actual child before exec ACK and keeps the nonempty-PID assertion.
No cleanup assertion or Swift 6 check was disabled to manufacture a pass.

## Disk retention

At the user's request, obsolete compiler caches/intermediates/toolchains and
retired app copies were removed: local audit
`build/cleanup/hc-artifact-cleanup.json` records 159 directories, 16.99GiB allocated
and 15.02GiB measured free-space gain. Sources, receipts/logs/screenshots, the
original official archive, qualified backport archives/binary and current Debug
products remain. Removed compiler caches are reproducible, not retained evidence.
Do not recursively search all of `/private/tmp` to locate results; use the exact
owned output root. Tests may rebuild necessary intermediates during development.
