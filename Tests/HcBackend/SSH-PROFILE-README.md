# Current product SSH / profile-owner qualification

Core remains official0.1.17; no installed app/service/credential/SSH account is
used. The real pinned SSH transport connects to a per-run loopback NIO server
with in-memory key/password and a private actual core. Native SwiftTerm windows
are never shown. This is not macOS/iOS profile-switch UI qualification.

## Results — keep overall failures

- `hc-ssh-current.dd56aQ/run`:39 functional checks finish and owned core/socket/
  processes retire, but passed=false: initial/reconnect snapshot OSC8 is lost,
  live OSC8 works. This repeats the selected baseline's known limitation.
- `hc-ssh-discovery.oYJDse/run`:40 checks, including actual production executable
  discovery; same retained OSC8 negative, overall passed=false.
- `hc-ssh-owner.7kPVHd/run`:45 checks, including actual product
  HcMachineConnection local -> host-key approval -> SSH -> local -> close.
  Retired models are closed before the next exact profile is published; approval
  discovery reads/offers no credential; explicit approval makes a fresh pinned
  connection. Local transitions read no credential. An owned sleep program
  retains address/PID/creation/live state through the transitions and owner close.
  Owned service/core/socket/process retirement and no late EventLoop work are
  checked. Overall **passed=false**, with functionalChecksCompleted=true,
  factoryDiscoveryExecuted=true, productOwnerProfileSwitch=true,
  productOwnerHostKeyApproval=true. No negative has been reclassified as a pass.

The local and SSH profiles deliberately address the SAME owned core. These
checks prove transport/profile ownership, not independent-origin cache isolation,
real remote-machine service operation, GUI approval, native-provider association
or gateway routing authority.

## Actual discovery, not an exec substitution

Previously both accepted exec strings were routed to the direct explicit-binary
command. The fixture now maps each exact allowed string to its own configuration.
Production HcConnectionPolicy.remoteCommand therefore executes in /bin/sh under
an explicit private environment, and really discovers `.local/bin/hc` under the
private HOME (whose path contains a space).

The owned executable shim asserts that poisoned inherited HC_TERMINAL_ID,
HC_TERMINAL_SOCKET, HC_SCOPE, HC_SOCKET and HERDR_CONFIG_PATH are UNSET and the
requested HC_SESSION is exact. Only AFTER those checks does it select the known
private socket and exec the unmodified pinned core. Receipt contains booleans,
not credentials. It retains SSH_CONNECTION's explicit fixture/no-launchd bypass;
this is not service installation qualification. Unknown SSH execs/PTY requests
remain rejected. No arbitrary client command text is executed.

```sh
python3 -B Tests/CoreProtocol/run-ssh-stream-tests.py \
  --official-017-archive /tmp/shepherd-official-hc-0.1.17.tar.gz \
  --products build/DerivedData/Build/Products/Debug --output /private/tmp/<fresh>
```

A nonzero outcome is expected while official0.1.17 loses snapshot OSC8. Read the
individual functional fields and cleanup receipts; do not call the whole suite
passing or weaken the snapshot assertions.

Read-only upstream check at2026-11-07T02:32:38Z: PR117 and PR118 are OPEN/unmerged.
The release lookup failed and does not establish a newer released fix. Permanent
ID/alias gateway mutation remains fail-closed; a fresh directory is not a lease.
No application-maintained core fork, unapproved upgrade or public push occurred.
