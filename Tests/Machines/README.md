# Machine editing checks

```sh
python3 Tests/Machines/run-tests.py --output /tmp/shepherd-machine-edit-FRESH
```

The runner requires a fresh output directory and Xcode's Swift compiler. It uses
private HOME/cache/defaults, an in-memory `MachineSecretStore`, and explicit test
transport/module doubles. It does not access real Keychain items, SSH servers or
vendor accounts. Production model/store/transport-selection/session-protocol and
terminal-view-model sources are compiled unchanged.

- 55 store checks: identity/active row/order preservation, no credential access
  for metadata edits, field/session validation, host/port pin reset, stale pins
  and stale editor/transport rejection, fresh pin lookup, credential rotation,
  failed save preservation, reload, removal, and local-entry protection.
- Terminal factory checks: errors remain visible without preview output,
  fresh retry, acknowledged old-session retirement, and pre-cancel safety.
- Attach command checks (`AttachCommandTests.swift`): `HerdrExecutable` takes a
  new `withoutMouseCapture` argument. Without it, the commands are the same as
  before for the iOS app, for single herdr requests (not attaches) and for herdr
  machine setup. With it, the test runs two commands, the one an SSH host runs
  and the one a herdr machine runs, in each of sh, bash, zsh, csh and tcsh (and
  fish when it is installed). Each run uses a HOME of the test's own, with a fake
  herdr placed first among herdr's usual install locations. The command writes
  `~/.cache/3rdr/herdr-attach.toml` (mode 0600, its folders 0700) when the file
  is missing or has other content, leaves it alone otherwise, and starts herdr
  with the same arguments and `HERDR_CONFIG_PATH` set to that file. When the file
  can't be written, herdr starts without the variable. Also checked: this Mac's
  copy of the file in the app's caches folder, and the program, arguments and
  environment of the three ways `LocalTerminalSession` starts an attach. Source
  checks: the Mac app's attaches pass `withoutMouseCapture`; the iOS app, single
  requests and machine setup don't; nothing sets `XDG_CONFIG_HOME`.
- The session iterator is explicitly MainActor-isolated; Swift 6 strict
  concurrency checks are enabled with the app's supported deployment floor.

UI/full-app compilation and existing managed-runtime regressions are separate
checks. Actual GUI interaction, real Keychain writes and live SSH editing are not
claimed by these synthetic tests.

Credential replacement writes a fresh Keychain tag before publishing the new
metadata and then attempts old-tag deletion. Failure to save the new credential
leaves the original unchanged. This is not a crash-atomic transaction spanning
UserDefaults and Keychain; post-save deletion is best-effort and never rolls back
the newly current credential.
