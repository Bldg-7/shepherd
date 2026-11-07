# hc installation and macOS lifetime qualification

## Still a release gate, not completed by private connect tests

The selected product baseline remains official **0.1.17**. No installed user app,
core, package-manager binary or service was replaced/restarted by these tests.
The operator has separately directed the [default macOS source root switch](hc-default-backend-cutover.md)
to hc. This does not qualify deployment/service lifetime; remaining legacy
target/dependency removal and release gates stay explicit.

| Boundary | Current evidence | Not implied |
| --- | --- | --- |
| Manual command policy | `HcReleasePolicy`; pinned `HC_VERSION` on the shell side | Installer execution/approval |
| Fresh installer component | `Tests/HcBackend/INSTALLER-README.md`;15 isolated checks, pinned script/binary, file mirror, disclosed owned-mktemp wrapper | Native default temp, HTTP/TLS, update/handover, package ownership |
| Ordinary hc client reconnect | Current actual-root Retry; same programs, workspace, reaped prior connect child | GUI quit/core coalition survival |
| Private core shutdown | Official attach9 and repeated actual-root resource receipts | Production launchd startup/lifetime |
| Production macOS startup and GUI quit | **Not exercised** | No service/quit survival or release approval |

## Why fresh HOME alone is not a production launchd fixture

The selected source at commit
[`ce87721557176f6cddaac1c7aefbf76929923263`](https://github.com/herdrdev/herdr-core/blob/ce87721557176f6cddaac1c7aefbf76929923263/crates/herdr-core/src/platform/macos_launchd.rs)
uses a one-shot launchd job to move the core outside the launching app's
coalition. This is not simply a persistent LaunchAgent plist under HOME.

The actual source was inspected without executing its service path:

- `SSH_CONNECTION` bypasses the launchd path. The private fixture's
  `SSH_CONNECTION=owned-fixture-no-launchd` is therefore an explicit limitation,
  not production service qualification.
- `launch()` addresses `gui/<uid>` and calls `remove_stale()` before creating
  its new job. It lists launchd labels and may boot out older inactive labels
  matching `dev.herdr.core.*`, outside this test's newly created namespace.
- It also enumerates `/tmp` and may recursively remove older, same-UID,
  matching `hc-launchd-*` directories after its PID/age checks. A fresh HOME/XDG
  does not confine those housekeeping effects to an owned test root.
- Its fallback explicitly warns the directly started core may die with the app.
  Observing a successful socket/hello alone cannot distinguish a qualified
  detached startup from this fallback.

Do **not** remove the SSH fixture bypass and run this path in the operator's
current GUI namespace merely to get a green test. Do not patch the selected
binary, grant privacy permissions or suppress fallback warnings to qualify it.

## Required isolated-host gate

Use an explicitly approved disposable macOS VM/test-user GUI namespace, not the
operator's existing core/account or a borrowed credential/signing identity.
Before execution, document the exact binary hash, launcher/app hashes, fresh
HOME/XDG/session/socket, job labels and owned executable/PID/start identities.

Qualify startup without the SSH bypass; capture actual launchd handshake/job
and fallback evidence. Start an owned program, quit the actual owned GUI app
(including a transient sheet), then reconnect from an independent owned client
and verify the same core/program identity and state. Explicitly end that owned
program/core, retire only the test's exact jobs/directories, and verify absence
of remaining children/sockets. Qualification must cover current Debug/Release
composition as appropriate, not transfer a component/client result to GUI quit.

Network/provider login, user privacy grants, existing service replacement and
Shepherd deployment remain outside this gate's authority. A CI trigger/push or
new VM/global-tool setup requires its own applicable approval.
