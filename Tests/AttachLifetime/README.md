# Local attach lifetime regression (SHPHRD-57)

```sh
# Fresh review preflight: verifies supplied SwiftTerm provenance and compiles
# normal, pre-fix, and fcntl-failure hosts; it never starts a host or fake.
python3 Tests/AttachLifetime/run-tests.py \
  --compile-only \
  --output /private/tmp/shepherd-attach-lifetime-compile-FRESH \
  --swiftterm-products /private/path/to/DerivedData/Build/Products/Debug

# Run only after that preflight receives fresh review.
python3 Tests/AttachLifetime/run-tests.py \
  --output /private/tmp/shepherd-attach-lifetime-FRESH \
  --swiftterm-products /private/path/to/DerivedData/Build/Products/Debug
```

Before compiling a host, the runner rejects anything except a clean checkout
and resolved SwiftTerm revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`.
It compiles and runs a small probe linked to the supplied `SwiftTerm.o` and
module; `SwiftTermBuildInfo.commit` must be that exact revision and
`hasUncommittedChanges` must be `false`. It records the verified build-info
values plus SHA-256 hashes of the supplied object and module tree in
`swiftterm-provenance.json`.

The runner compiles the production `LocalTerminalSession.swift` and both
output-only variants with that verified SwiftTerm product and a private
`NIOCore` test module before starting any host or fake. Its only executable
child is a C fake attach built into the supplied output directory. The fake
records its terminal/session/mask state and all terminal descriptors, then
writes and fsyncs `ENUMERATED`; no record is accepted before that completed
snapshot.

Twenty bounded runs start eight sessions concurrently. Every completed fake
must have only its own terminal device after exec. The runner captures the
owned host's PID/start identity/process group immediately before it SIGKILLs
that host; it never signals a fake child by PID. Each completed fake must then
record its natural SIGHUP exit within three seconds.

For explicit `stop()`, the host records the eight completed fake PIDs before
stopping them and observes each exact direct child only with public
`waitid(P_PID, WEXITED | WNOHANG | WNOWAIT)`. It never reaps them itself:
`ECHILD` within the bounded observation proves the production reaper consumed
the owned child. This preserves the stop/zombie regression claim without a
broad `waitpid(-1, ...)` cleanup scan.

A separate private pre-fix fixture removes only the production `FD_CLOEXEC`
block while retaining the lock; its later fork deterministically inherits an
earlier master, so the completed descriptor assertion must fail before its
explicit-stop evidence is recorded separately. The output-only fcntl-failure
fixture waits for an fsync-backed `fault-first` completion marker before
returning `EIO`. It also records every private fixture `startProcess` entry:
the runner requires exactly one first launch, an owned first-fake HUP exit,
and no second-fake log. This proves the sticky failure gate denied the second
start before fork rather than merely observing a late or missing log.

The runner uses a fresh HOME, cache and temporary directory under `--output`;
it does not run herdr, SSH, a user shell, a user configuration, or network
operations. It requires a previously built private SwiftTerm product and is a
parent heavy gate, not a short worker validation.
