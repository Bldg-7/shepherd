# Mobile agent-list cache integration checks

`run-agent-list-cache-integration-tests.py` is a source-contract runner for the
iOS composition around the separately tested `AgentListCache` storage actor and
`MachineMonitor.refresh()` completion seam. It uses an owned output directory
and performs no simulator, network, SSH, Keychain, user-defaults, or live herdr
operation.

It verifies that the mobile composition is explicitly Application-Support-only;
loads only the selected Board's exact identity before its access refresh; uses
the monitor's awaited coalesced refresh for pull-to-refresh; records only
successful host/nested publication boundaries; retains failed nested groups;
and exposes cached rows without a `PaneDestination` navigation link. It also
checks precommit MachineStore invalidation and the coordinator's identity plus
lease guard for late writers.

Run it with:

```sh
python3 Tests/Mobile/run-agent-list-cache-integration-tests.py --output /owned/output
```

The real `Shepherd Mobile` target build is the compilation evidence for the
SwiftUI composition. The storage and monitor runners remain responsible for
their synthetic behavior (restart/corruption/atomic writes and coalesced
refresh/failure/cancellation respectively).
