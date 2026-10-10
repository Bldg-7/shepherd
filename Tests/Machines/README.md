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
