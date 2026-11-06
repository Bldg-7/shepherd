# hc product connection ownership

`HcMachineConnection` owns its connect client/model, not the core daemon or its
programs. Every open/close joins one retirement tail before replacement can
start. Pending factories, connected-but-initializing RPCs and preparing models
remain tracked. Late close completion cannot change a newer owner's phase.
`HcWorkspaceModel.disconnect` shares one cleanup job across concurrent callers.
An unconfirmed cleanup tail blocks further dispatch rather than guessing it is
safe to retry. SSH host-key classification is conditional on the actual SSH
modules; the local-only composition does not substitute a fake SSH error type.

Run the real product owner with an explicitly isolated official core:

```sh
python3 -B Tests/CoreProtocol/run-real-core-tests.py --machine-owner-tests \
  --official-017-archive /tmp/shepherd-official-hc-0.1.17.tar.gz \
  --output /private/tmp/<new-owned-root>
```

This uses private HOME/XDG/session/socket, denied external network with a loopback
canary, no credential operations, no installer or user service changes. A known
owned sleep program must retain its PID/creation/live facts through replacement.
Transport gates control owned cleanup/initial metadata, not application callbacks
or terminal-output readiness. Cleanup-confirmation failure is injected **after**
the fixture's client is actually reaped; it tests fail-closed policy, not a real
OS supervision failure. No stop/run/input replay is permitted by this fixture.

## Evidence and limits

- `hc-owner-negative.I82cGZ`: compile failed because the local-only composition
  referenced the SSH-only error type. No core or runtime scenario executed.
- `hc-owner-negative-local.98VrFO`: original lifecycle after that compile-only
  correction fails: replacement starts before retirement, and stale close leaves
  the new owner inconsistent. Failure receipt confirms owned cleanup/core stop.
- `hc-owner-fixed.nwecwj`: first two scenarios/platform builds pass, before the
  extra initialization/failure boundary scenarios and model cleanup change.
- `hc-owner-boundaries.WKwFI1`: expanded test fails at initializing-model
  replacement. The fixture initially withheld all reads including CLOSE ACKs.
  Both model cleanup idempotency and fixture ordering were subsequently corrected;
  this is **not** an isolated before/after attribution to only one change.
- `hc-owner-idempotent.zPStVX`: final owner24 and workspace84 official-core
  checks, SDK274 per mode /21 stages, macOS Debug/Release and iOS Debug pass.
  The four owner cases cover close/open, repeated replacement, initializing-model
  retirement and blocked replacement after cleanup confirmation failure.
  All clients/core/programs/socket retired; no user core/config touched.

These do **not** qualify physical host switching, actual GUI focus, SSH/host-key
approval interaction, mobile UI, production launchd, GUI-quit survival or release
cutover. The SSH bypass remains explicit; no user GUI namespace is borrowed.
