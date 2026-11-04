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

## hc detection + bootstrap

```sh
python3 Tests/HcBackend/run-detect-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-detect.XXXXXX)/run"
```

`HcExecutable` finds `hc`/`herdr-core` in the usual install locations first
(`.local/bin`, Homebrew, `/usr/local/bin`), then PATH, requiring an executable
**regular file** (directories are rejected). It only locates; it never runs the
binary. `HcCoreBootstrap` then owns one policy for the app and tests: private
state/config/runtime + a short socket path, a direct-startup environment
(`SSH_CONNECTION=owned-fixture-no-launchd`, never a machine-wide launchd job),
and a `CoreProcessTransport` + `CoreRPCConnection` whose hello verifies version,
generation and required methods. The caller owns the connection and stops the
core it started.

## Launch owner proof

```sh
python3 Tests/HcBackend/run-launch-proof-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-proof.XXXXXX)/run"
```

`HcLaunchProof` proves a program hc launched is the process actually running in
its terminal: hc's own record (live state, PID, exact argv), the kernel
foreground anchor/snapshot (session leader with a controlling tty), and
`proc_pidpath` (the kernel's executable, not argv). It is observation, not
authority — the caller still compares the resolved executable against what it
asked to launch, and PID/start-time continuity alone cannot survive an exec.

## Board

```sh
python3 Tests/HcBackend/run-board-tests.py \
  --official-017-archive /absolute/herdr-core-macos-aarch64.tar.gz \
  --output "$(mktemp -d /tmp/hc-board.XXXXXX)/run"
```

`HcTerminalBoard` is the hc replacement for the herdr board's terminal surface:
`list`/`get`/`run`/`read`/`kill`/`remove`/`attach` on one negotiated connection.
`HcTerminalRecord` decodes the core's public terminal record (address, name,
labels, argv, cwd, state, pid, exit, reason, title, cols/rows, timestamps, OSC
status, reported, turn) and treats those facts as presentation-only. `run` takes
exact argv (no shell line parsing), so quoting stays the caller's. The gate
proves list→run→get→read-marker→kill→rm round-trips and that attach leaves the
program live, against a pinned official core.
