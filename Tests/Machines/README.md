# Machine editing checks

```sh
python3 Tests/Machines/run-tests.py --output /tmp/shepherd-machine-edit-FRESH
```

The runner requires a fresh output directory and Xcode's Swift compiler. It uses
private HOME/cache/defaults and an in-memory `MachineSecretStore`. It does not
access real Keychain items, SSH servers or vendor accounts. Production
model/store sources are compiled unchanged.

- Store checks: identity/active row/order preservation, no credential access
  for metadata edits, field/session validation, host/port pin reset, stale pins
  and stale editor/lookup rejection, fresh pin lookup, credential rotation,
  failed save preservation, Keychain read failures surfaced, reload, removal,
  and local-entry protection; and, for a Mac paired by QR code, its address
  kind, key and pin kept, a new address saved without touching the key, the pin
  or the Keychain, an edit keeping the kind, and the kind saved.
- Swift 6 strict concurrency checks are enabled.

UI/full-app compilation is a separate check. Actual GUI interaction, real
Keychain writes and live SSH editing are not claimed by these synthetic tests.

Credential replacement writes a fresh Keychain tag before publishing the new
metadata and then attempts old-tag deletion. Failure to save the new credential
leaves the original unchanged. This is not a crash-atomic transaction spanning
UserDefaults and Keychain; post-save deletion is best-effort and never rolls back
the newly current credential.
