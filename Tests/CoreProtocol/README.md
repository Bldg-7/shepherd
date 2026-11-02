# hc framed protocol and RPC foundation (SHPHRD-149 / SHPHRD-150)

```sh
python3 Tests/CoreProtocol/run-tests.py --output /tmp/shepherd-hc-wire-FRESH
```

The output directory must not exist. The runner uses a private HOME, temp and
module cache; it does not launch `hc`, herdr, the app, an agent, SSH or a browser.
It neither installs packages nor reads account credentials. Xcode is required.
Each subprocess has a deadline using the existing owned-stage runner. The local
transport tests launch only `fixture-core.py` with isolated Python and explicit
environment/cwd, over real non-PTY pipes, inside a network-denying sandbox.

## Production code

`ShepherdKit/Sources/ShepherdKit/CoreKit/` is independent of the legacy backend:

- `CoreWire.swift`: generation-1 constants, immutable frames, bounded incremental
  encoder/decoder. Little endian 9-byte headers; 16 MiB payload limit enforced
  before copying a body; fixed-size controls and focus values checked. Unknown
  frame kinds fail closed. A consumer exception poisons the parser as well.
- `CoreHandshake.swift`: JSON-RPC hello request, reply ID/version/envelope shape,
  core identity, framed mode, API generation and required method checks. Keeps
  bytes after the hello newline, even when they contain several binary frames.
  A 64 KiB hello limit prevents an unterminated stdout banner growing forever.
  Server error messages and terminal contents are not included in codec errors.
- `CoreEventLines.swift`: bounded newline framing inside event DATA streams;
  line and UTF-8 boundaries need not align with wire frames. It preserves bytes
  and leaves JSON/event validation to the future event reducer.

- `CoreRPC.swift` (SHPHRD-150, first slice): exact UInt64 JSON-RPC IDs and typed
  result decoding, request/response correlation, caller-supplied deadlines,
  cancellation tombstones and connection epochs. Bounds both outstanding slots
  and admitted payload bytes. Late replies retain their original method so a
  future connection owner can clean up a late attach without guessing ownership.

- `CoreByteTransport.swift`: single-use byte transport contract and errors.
- `CoreProcessTransport.swift`: macOS POSIX-spawned local pipe child with bounded
  nonblocking writes, demand-driven reads, separately discarded stderr, and
  confirmed fd retirement/child reaping. Write admission is locked BEFORE GCD
  enqueueing. No PTY, global signal policy or process-group kill. Close signals
  only the owned, unreaped child (PID/start evidence), not a core daemon.
- `CoreRPCConnection.swift`: actor-owned live hello/RPC loop, continuations,
  deadlines, a separately bounded serialized writer, local cancel and teardown.
  Never starts an expired queued request; never interrupts an in-flight frame
  for an individual RPC cancellation. No automatic reconnect or mutation retry.
- `CoreRPCStreams.swift` / `CoreStream.swift`: atomic channel registration before
  open replies are exposed, bounded per-stream queues and initial credit,
  explicit post-consumption receipts, DATA/RESIZE/FOCUS/FACTS/CLOSE, read and close
  deadlines, observer protection and late-open cleanup. Channel IDs are tracked
  as bounded intervals rather than an unbounded retired-ID set.
- `CoreSSHTransport.swift`: pinned-host-key SSH authentication and exec through
  SwiftNIO/NIOSSH, without a PTY or unbounded Citadel AsyncStreams. autoRead=false
  and a synchronous bounded byte queue provide backpressure. Cancellation guards
  in channel initializers prevent late connect/exec publication. Remote environment
  and executable values are quoted, with inherited core terminal identity removed.

These types are not yet wired into the app UI. The existing app backend is unchanged.

## Coverage

- Python `struct.pack('<IBI', ...)` independently generates vectors for all six
  frame kinds; Swift encoder output is unpacked and checked again in Python.
- Binary payloads (including invalid UTF-8), large channel IDs, every split of a
  representative frame, byte-at-a-time input, coalesced and empty frames.
- Seeded fragmentation of 200 multiplexed frames, with nonzero Data indices.
- Exact 16 MiB body, oversized header rejection, aggregate input larger than a
  frame limit delivered incrementally rather than accumulated in a result array.
- Bad kind/channel/control length/focus value, EOF at every incomplete position,
  parser retirement after error/EOF, and consumer errors.
- Event lines split inside Korean/emoji UTF-8, CRLF, empty lines, exact/overflow
  byte budgets, aggregate batches and incomplete EOF.
- Every split across hello and two frames; hello must be delivered first, once.
- Wrong RPC ID/type/version, malformed JSON/UTF-8/banner, error envelope, both
  result and error, missing methods, unsupported generation, framing refusal,
  custom request IDs, optional unknown features and exact/oversized hello.

The runner compiles the real sources in Swift 6 with the package's
upcoming-feature flags and default MainActor isolation. It rejects first-party
package or Xcode target settings that drift to another language mode.
It also typechecks the production sources against the iOS Simulator SDK for
an iOS 17 deployment target. `validation.json`, source hashes and stage logs are
retained in the output directory. This is not a full package/app build.

## RPC coverage (SHPHRD-150)

`CoreRPCTests.swift` checks out-of-order replies, null results, remote failures,
unknown/duplicate IDs, stale connection epochs, deadlines before the timer fires,
cancellation and exactly-once close drainage. Canceled/expired requests retain
bounded tombstones until a late reply or connection close; a cancellation flood
cannot grow an unbounded retired-ID list. Python independently unpacks the Swift
request and verifies UInt64.max survives in both its request ID and params.

`CoreRPC.swift` remains pure routing state; `CoreRPCConnection` now supplies the
live connection owner for channel-0 calls. Neither cancellation nor timeout
implies that a remote command was rolled back. No mutating command is retried.

## Local connection coverage

`CoreConnectionTests.swift` talks to an independent Python protocol peer over
real process pipes. It covers split hello, reversed/coalesced replies, late
cancel/timeout replies, method admission, stderr floods, the last reply before
exit, malformed replies, partial EOF, missing executables, stdin EPIPE without
SIGPIPE, and a non-reading peer. Closing must retire fds and reap the connect
child. A fixture ignoring both EOF and SIGTERM exercises SIGKILL escalation;
no unrelated PID or process group is signaled. A fresh connection uses a new
epoch. Writer quotas remain charged for timed-out but still-writing frames.

## Opt-in real core smoke

Download the **0.1.16 macOS ARM64 archive** from
`https://releases.herdr.dev/core/0.1.16/herdr-core-macos-aarch64.tar.gz`, then run:

```sh
python3 Tests/CoreProtocol/run-real-core-tests.py \
  --archive /tmp/herdr-core-macos-aarch64.tar.gz \
  --output /tmp/hc-real-FRESH
```

The runner pins archive SHA-256
`698d8f0c44f4e4b15fec174d52a39d57a014cfd71added44b53a0753b469d0fd`,
extracts only the regular `herdr-core` member to a private temp directory and
runs no installer. This checks integrity against the release manifest, **not**
an independent signature. It uses explicit private HOME/XDG/HC_SESSION/HC_SOCKET
and a sandbox allowing network operations only under its private Unix-socket
folder. It does not use installed `hc`, user settings, agents or SSH.

The smoke verifies real hello/status/list, doc CAS/conflict, UInt64 values above
Double precision, and a new connection to the same still-running core after
closing the first connect child. It stops only that isolated core, confirms
stop acknowledgement, connect-child reaping, daemon exit and socket removal.
`provenance.json`, `core-report.json`, source hashes and `validation.json` retain
the evidence; no binary is added to the repository.

## Owned SSH and native SwiftTerm integration

After building the macOS Debug app/package products:

```sh
python3 Tests/CoreProtocol/run-ssh-stream-tests.py --archive /tmp/herdr-core-macos-aarch64.tar.gz --products build/DerivedData/Build/Products/Debug --output /tmp/hc-ssh-FRESH
```

This runner creates a fresh ephemeral loopback SSH server with generated host
key and a random per-run password kept only in memory. It accepts only its precomputed command, executes
that quoted command against a private pinned core, and rejects PTY requests.
No saved keys, SSH configuration, external machines or user core are used.
The native SwiftTerm view is in a never-shown window. The workload is a small
owned Python terminal program, not a real agent. Failures preserve logs and
attempt cleanup of only the explicitly private core/socket.

`CoreStreamTests.swift` independently exercises same-read reply+initial DATA,
CREDIT withheld until ACK, duplicate/cross-channel receipts, stalled-stream RPC
progress, >256 KiB output, late timed-out/canceled opens, observer protection,
resize negotiation, stream limits, invalid/reused/pre-reply channel IDs and
missing CLOSE acknowledgement. The live SSH runner exercises the real core and
native terminal alongside authentication, cancellation and reconnect.

## Qualification blocker: SHPHRD-157

The official 0.1.16 first paint drops OSC8 link metadata for cells whose hyperlink
was closed before attach. The label is present but the URI is absent from raw
DATA. Live OSC8 works through the same SSH/core/SwiftTerm path. This cannot be
recovered from the label without inventing a URL or changing the link policy.

The pinned Ghostty formatter explicitly supports per-cell links only for HTML:
[formatter.zig](https://github.com/ghostty-org/ghostty/blob/1e5cdb865807abc990181efb8ebfa9122955cce2/src/terminal/formatter.zig#L1471-L1510).
Its VT `extra.hyperlink` restores the cursor's active hyperlink, not all cell
links. A fix must include VT hyperlink transitions, open/close encoding and the
ASCII-run fast path, with safe URI/id handling and wrapped/selected row tests.

The integration test continues after recording this failure to exercise IME,
kitty keys, mouse, resize, display queries, >256 KiB CREDIT flow, events,
reconnect and cleanup. It **still exits nonzero** at the end. The runner writes
`validation.json` with `passed: false` and `blocker: SHPHRD-157`; this is not an
expected-failure success or permission to cut over the app. A patched/upgraded
core and a complete passing run are required before closing SHPHRD-150.

The test extracts text via SwiftTerm's character provider and skips wide-cell
continuations. Its simpler `getBufferAsData()` helper does not resolve stored
graphemes; it is not a valid emoji/CJK rendering oracle. Input uses the real
`TerminalViewDelegate`, not the terminal-engine response callback.

## Protocol baseline and remaining work

Reference: herdr-core `5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2`,
`schema/README.md` and `crates/herdr-core/src/wire.rs`. The implementation is
written against the documented protocol, not copied from the Rust client.
The HEAD-only observer resize option is not assumed to exist in 0.1.16.

- `terminal.attach` and `events.subscribe` use `openStream`, not generic `call`.
  The reader actor installs the channel before resuming the opener, including
  when DATA immediately follows the reply in the same read. Actual pre-reply
  DATA violates the core wire contract and fails closed instead of being cached
  without an owner. Late successful opens are closed even after the caller left.
- Reconnect is explicit: create a fresh connection/epoch and reattach using the
  latest terminal identity. Old handles cannot send input to the replacement.
  No mutating request or credential/browser authority is automatically replayed.
- UI backend cutover, agent authority, workspace document synchronization and
  mobile conversation behavior belong to SHPHRD-151–154, not this transport layer.
- CREDIT must be sent after consumer processing, not at decoder receipt or
  AsyncStream enqueue time. This codec emits no automatic CREDIT.
- A complete frame callback is not proof of initial-screen completion, and a
  valid hello is not proof of authentication to a browser or a particular agent.
- Every connection owns new decoder instances; never reuse old stream IDs or
  decoder state after reconnecting.
- The endpoint must keep stderr separate. No scanning past stdout banners or
  malformed bytes to guess a new frame boundary.
- Each event stream owns its own `CoreEventLines`; sharing one across channels
  would splice unrelated JSON. Slow-consumer policy belongs to its owner.

See `docs/hc-connect-migration-review.md` for the full migration and safety gates.
