# hc backend replacement (SHPHRD-153)

The app backend moves from legacy herdr (`HerdrClient` + `herdr terminal attach`
over an SSH PTY) to hc (`CoreRPCConnection` + `terminal.attach` framed streams).
The experimental browser/`3rdr-browser` injection layer is out of scope for this
first slice; it is deferred until after the core launch path ships.

```sh
python3 Tests/HcBackend/run-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-attach.XXXXXX)/run"
```

## HcTerminalSession

`ShepherdKit/CoreKit/HcTerminalSession.swift` is the hc replacement for the
herdr `TerminalSession`. It attaches interactively (`observe=false`) to one
terminal on an already-negotiated connection and exposes:

- `start(columns:rows:) -> AsyncStream<Data>` — first paint then live bytes as
  DATA frames; the stream is bounded (`bufferingNewest(1024)`, oldest dropped
  when the UI stalls, terminal scrollback semantics).
- `write(Data)` — keys as DATA on the stream.
- `resize(columns:rows:)` — a RESIZE frame, not a shell command.
- `stop()` — a CLOSE frame; idempotent and safe before/during/after `start`.

CREDIT is returned only after each DATA chunk enters the bounded buffer. The
session never stops the core or the terminal; the caller owns the connection.
Output is raw `Data` (the core's rendered VT/ANSI), so CoreKit stays
Foundation-only (no NIOCore); the UI layer owns SwiftTerm/ByteBuffer adaptation.

## What the gate proves

Against a pinned official hc 0.1.17 in an isolated home (direct startup via the
`SSH_CONNECTION=owned-fixture-no-launchd` marker, network denied, no launchd):

- attach first paint carries the program's `READY` marker;
- `write("hello\r")` reaches the program and its `GOT:hello` echo returns;
- `resize(100,30)` reaches the terminal record (`terminal.get`), not just a
  local replica;
- closing the attach leaves the program live; explicit `terminal.kill` ends it;
- every owned PID (core, holder, run) and the socket retire on stop.

This is a launch/attach path only: no browser, MCP, credential or authority is
involved, and `launchdLifecycleQualified` stays false.
