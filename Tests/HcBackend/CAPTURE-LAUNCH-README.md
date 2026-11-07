# hc capture launch — secret transport gate (NOT integrated)

The peer-verified control/forwarder/recorder composition is implemented; the
launcher does not yet call it. A durable route reservation must precede any
program dispatch and bind only the exact known receipt. Never retry uncertain
run/create/bind or adopt a label/PID/native session.

## Standard terminal.run env is not a safe capability handoff

The official0.1.17 source assigns caller overrides to `restart_env`, then queues
its registry snapshot before spawning (`api/run.rs`). The serialized Terminal
includes that map (`terminals.rs`). A private official-binary probe confirms the
risk; this is not inferred solely from source or a candidate core.

`hc-launch-env-probe.U8y5CQ` uses the checksum-pinned official0.1.17 binary, a
private HOME/XDG/session/socket, denied TCP canary, and one owned `sleep` program.
It passes only a random synthetic canary, NOT a route URL/provider credential.
The canary is present in the owned `state/herdr-core/owned/terminals.json`.
Neither the run reply nor fresh exact-terminal GET exposes it. The known program
is killed once via its exact owned core receipt; the owned core stops, connect
child is reaped, both known PIDs exit and the private socket disappears.

`passed:true` in the probe means the investigation ran and retired correctly.
The actual safety verdict is **environmentPersistenceSafe:false** and
**launchCaptureQualified:false**. It is not provider/service/launch qualification.
The runner now prints that distinction explicitly for this optional suite.
`hc-launch-env-report.8U3dfp` repeats the probe with that explicit reporting,
again observing the canary on disk and false safety/qualification. Both stages
exit naturally with zero runner signals. Cleanup removes only the six retired
owned binaries/caches and preserves the negative state/report/provenance.

```sh
python3 -B Tests/CoreProtocol/run-real-core-tests.py \
  --official-017-archive /tmp/shepherd-official-hc-0.1.17.tar.gz \
  --launch-env-probe --output /private/tmp/<fresh>
```

Do not inject a capture URL/token into `terminal.run.env` (or argv/labels/docs),
even for a normal non-kept launch. Do not waive persistence merely because the
core's state is private. No product environment API or launcher injection was
added by this probe.

## Required next gate

A prospective handoff must keep the route capability memory-only and out of
core metadata, disk files, transcript output and logs. Consider a bounded,
private same-UID one-shot IPC handoff to an owned bootstrap that execs the exact
verified CLI, with no provider credentials, browser/AgentRuntime injection or
service startup. That design is NOT implemented/qualified here. Cancellation,
wrong nonce/peer, timeout, owner replacement, receipt/binding failure and cleanup
must fail closed; no uncertain delivery or program dispatch replay. Local-only
scope must be explicit; a local Unix path/127.0.0.1 proxy is not a remote profile
or gateway capability. Preserve actual argv/cwd/UI behavior and distinguish
bootstrap receipt from provider readiness/native-session authority.

Before the launcher receives any usable route, also separate hc reservations
from the legacy proxy service's sweep/off/restart policy. A fresh route-list
snapshot is not a retirement/configuration lease. Production service/install/
handover still needs the approved disposable macOS namespace.
