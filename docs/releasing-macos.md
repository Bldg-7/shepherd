# macOS release procedure

Source and release assets live in `Bldg-7/shepherd`. The app reads
`https://github.com/Bldg-7/shepherd/releases/latest/download/appcast.xml`.
Publishing a release as Latest changes the update feed for existing installations.

## Credentials

Use the existing Developer ID Application identity for team `SYZS4D43Z6`,
`shepherd-notary` notarytool profile, and Sparkle EdDSA key. Never export or commit
private keys. The embedded Sparkle public key is
`skarCPyq1WUb5+GXaPSGInNaV2UsVa7VVnG8vheDZ8U=`.
Keychain prompts require the operator; do not silently approve prompts or weaken validation.
The release script uses only the selected GitHub account (default `ESnark`), with no
fallback or persistent account switch. It does not pass its GitHub token to build plugins.

## Prepare

1. Keep a clean, reviewed macOS-only source tree. Prepare pinned CEF, Node and Swift dependencies.
2. Approve only the exact SwiftTerm 1.20.0 build plugin if Xcode requires approval.
3. Update the marketing version and numeric build number. **Do not use Git commit count:**
   this public history differs from the earlier private source history. 0.1 used build 21;
   **0.2.0 uses build 22**. Future builds must exceed the latest published appcast.
4. Retain the prior published `build/updates` directory for delta generation, or download
   the prior release archives and appcast. These are ignored build inputs, not Git sources.
5. Commit the exact source before making the release candidate. Do not force-push history.

## Build and verify without publication

```sh
SHEPHERD_BUILD_NUMBER=22 SHEPHERD_SKIP_PUBLISH=1 scripts/release-macos.sh 0.2.0 notes/0.2.0.md
```

The script archives, exports/signs, notarizes, staples the app and DMG, runs Gatekeeper
checks, and signs the Sparkle feed. Existing output is not deleted: preserve failed
receipts and set `SHEPHERD_RELEASE_WORK` to a fresh directory for a retry.
`SHEPHERD_SKIP_NOTARIZE=1` also prevents publication, and is not a distributable release.
An unsigned/local build or `BUILD SUCCEEDED` is not signing/notarization acceptance.

Verify version/build, architectures, Developer ID team, hardened runtime, every nested
CEF/helper signature, notarization/staple, third-party notices, bundled runtime integrity,
and absence of development credentials/profiles/evidence. Use owned private profiles for
any runtime smoke tests. Do not restart or operate a user's running app.

## Publish

Push the reviewed source and an annotated `v0.2.0` tag pointing to the exact built commit.
Upload a **draft** release with these assets:

- `Shepherd-0.2.0.zip` (Sparkle update archive)
- `Shepherd-0.2.0.dmg` and `Shepherd.dmg` (installation image)
- `appcast.xml` and any delta files it references

The script's publishing path creates a draft only, targets the exact already-pushed source
commit, and does not change Latest or the published-update cache. Alternatively upload the
already-verified candidate manually; do not rebuild under the same tag.

Download the draft assets, compare hashes/sizes and verify the ZIP's Sparkle signature,
app/DMG notarization and Gatekeeper acceptance. Check that all appcast URLs refer to the
same release tag. Only then publish the draft and explicitly mark it Latest. Verify the
public feed and downloads again. After success, copy the verified updates directory into
`build/updates` without removing older archives needed for future deltas.

The repository's Pages workflow/site are independent and are preserved. Historical 0.1
assets remain available. Source publication and application release are separate operations;
a successful push does not mean deployment succeeded.
