# macOS release procedure

Source and release assets live in `Bldg-7/shepherd`. The app reads
`https://github.com/Bldg-7/shepherd/releases/latest/download/appcast.xml`.
Publishing a release as Latest changes the update feed for existing installations.

A release goes through four steps:

1. Prepare the source, the version and the release notes.
2. Build a release candidate: the signed and notarized app, its disk image and its update
   files, uploaded as a **draft** release. This is done by the `Release (macOS)` workflow on
   a GitHub-hosted runner, or by `scripts/release-macos.sh` on a Mac. The workflow runs the
   same script.
3. Verify the candidate.
4. Publish the draft and mark it Latest. This step is always done by hand.

The workflow needs a one-time setup: a `release` environment and its secrets, described
under "Build with the workflow".

## Credentials

A release is signed with three keys: the Developer ID Application certificate of team
`SYZS4D43Z6` that the published releases are signed with, a credential for Apple's notary
service, and the Sparkle EdDSA key. The embedded Sparkle public key is
`skarCPyq1WUb5+GXaPSGInNaV2UsVa7VVnG8vheDZ8U=`.

The keys are kept in two places and nowhere else: the Keychain of the Mac that releases are
built on, and the secrets of this repository's `release` environment, which only the
workflow reads. Never commit a private key. A key file exported to set a secret is deleted
as soon as the secret is set.

Keychain prompts on the Mac are answered by the person running the release; nothing may
approve them automatically or weaken validation. The release script uses only the selected
GitHub account (default `ESnark`), with no fallback or persistent account switch. It does
not pass its GitHub token, or the keys the workflow gives it, to build plugins.

## Prepare

1. Keep a clean, reviewed macOS-only source tree. Commit the exact source and push it
   before building the candidate. Do not force-push history.
2. Choose the version (the marketing version, like 0.3.2) and the numeric build number.
   **Do not use Git commit count:** this public history differs from the earlier private
   source history. 0.1 used build 21; 0.2.0 used build 22; 0.2.1 used build 23; 0.3.0 used
   build 24; **0.3.1 uses build 25**. A new build number must be higher than the one in the
   published appcast.
3. Write the release notes as `notes/<version>.md`. They are embedded in the appcast.

## Build with the workflow

### One-time setup

Create an environment named `release` (Settings → Environments). Limit its deployment
branches to `main`, and add yourself as a required reviewer, so that a run waits for your
approval before it can read the secrets. Then set these as secrets of that environment:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate with its private key, exported as a `.p12` file and base64-encoded. The file must hold exactly one certificate. |
| `DEVELOPER_ID_P12_PASSWORD` | The password the `.p12` file was exported with. |
| `NOTARY_APPLE_ID` | The Apple ID that notarizes: a member of the team. |
| `NOTARY_APP_PASSWORD` | An app-specific password of that Apple ID. |
| `SPARKLE_ED_PRIVATE_KEY` | The Sparkle private key, as `generate_keys -x <file>` writes it. |

None of these is a new key. The certificate and the Sparkle key are the ones in the
Keychain, exported. Do not make a new Sparkle key: installed copies accept only updates
signed with the key whose public half is embedded in them.

Export the certificate from Keychain Access: My Certificates → the Developer ID Application
certificate → Export, as a `.p12` file, with a password. If the Keychain has more than one
certificate of that name, export the one the published releases are signed with;
`security find-identity -v -p codesigning` lists the SHA-1 fingerprint of each.

Apple shows an app-specific password only when it is created. If the text of the one made
for notarizing on the Mac was not kept, create another at account.apple.com (Sign-In and
Security → App-Specific Passwords); the earlier one keeps working. Changing the Apple ID's password revokes every app-specific password, and
the secret then has to be set again.

```sh
export GH_TOKEN="$(gh auth token --user ESnark)"
set_secret() { gh secret set "$1" --env release --repo Bldg-7/shepherd; }

base64 -i DeveloperID.p12 | set_secret DEVELOPER_ID_P12_BASE64
set_secret DEVELOPER_ID_P12_PASSWORD          # asks for the value
set_secret NOTARY_APPLE_ID                    # asks for the value
set_secret NOTARY_APP_PASSWORD                # asks for the value
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key
set_secret SPARKLE_ED_PRIVATE_KEY < sparkle-private-key
rm DeveloperID.p12 sparkle-private-key
```

An App Store Connect API key can notarize in place of the Apple ID. Set `NOTARY_API_KEY`
(the text of the key's `.p8` file), `NOTARY_API_KEY_ID` and, for a team key only,
`NOTARY_API_ISSUER_ID`, and leave the two Apple ID secrets unset. Such a key is created in
App Store Connect (Users and Access → Integrations), and its `.p8` file can be downloaded
only once.

### Run

Start `Release (macOS)` from the Actions tab on `main`, or:

```sh
gh workflow run release-macos.yml --repo Bldg-7/shepherd -f version=0.3.2 -f build_number=26
```

Approve the run when GitHub asks. It uploads a draft release. It also keeps the disk image,
the update archive, the appcast and Apple's notarization results (`notarize-*.json`) as a
workflow artifact for 14 days. The repository is public, so anyone signed in to GitHub can
download that artifact.

Add `-f upload_draft=false` to build, sign and notarize without creating a draft. Use this
for the first run, and whenever the workflow or the secrets change. Such a run does not
need the version's release notes to exist yet.

### Steps only the workflow has

- It downloads the published appcast and the full update archives of the five latest
  releases into `build/updates`. The script checks the build number against that appcast and
  makes the delta updates from those archives.
- It downloads Xcode's Metal toolchain, which the runner's image comes without and a Mac
  that builds the app already has.
- It approves the SwiftTerm build plugin without a prompt, by writing the record that Xcode
  writes when the plugin is approved by hand. The record names one revision of SwiftTerm,
  the one pinned in `Package.resolved`. Plugin validation is not turned off. After a
  SwiftTerm update, put the new revision in the workflow file.
- It makes a keychain for the run with the Developer ID certificate in it, and removes it at
  the end.
- It gives the script the notarization credential and the Sparkle key as environment
  variables.
  The script removes them from its environment before it builds anything, so the build and
  its plugin cannot read them.

## Build on a Mac

1. Prepare pinned CEF, Node and Swift dependencies.
2. Approve only the exact SwiftTerm 1.20.0 build plugin if Xcode requires approval.
3. Keep the `build/updates` directory from the last release, which holds the update
   archives and the appcast as they were published, or download the earlier releases'
   archives and the published appcast into it. The script makes the delta updates from
   them. These are ignored build inputs, not Git sources.

```sh
SHEPHERD_SIGN_IDENTITY=<certificate-SHA1> \
SHEPHERD_BUILD_NUMBER=<build> SHEPHERD_SKIP_PUBLISH=1 scripts/release-macos.sh <version> notes/<version>.md
```

`<certificate-SHA1>` is the fingerprint of the certificate the published releases are
signed with, as `security find-identity -v -p codesigning` lists it. The notarytool profile
in the Keychain is `shepherd-notary`. With `SHEPHERD_SKIP_PUBLISH=1` the script stops
before uploading; without it, the script uploads the draft release itself.

With `SHEPHERD_SKIP_NOTARIZE=1` the script neither notarizes nor uploads, and what it
builds cannot be distributed. An unsigned local build, or a `BUILD SUCCEEDED`, does not
show that signing and notarization will pass.

## What the script does

The script signs the CEF libraries, framework and helpers that `scripts/cef.sh` prepared,
inside-out, with the exact Developer ID certificate before Xcode validates embedded
applications; the app uses the same certificate. The helpers keep the entitlements in
`CEFHelper/`, and none are added. No `--deep` signing or plugin-validation bypass is used.

It archives, exports/signs, notarizes, staples the app and DMG, runs Gatekeeper checks, and
signs the Sparkle feed. It stops if the update in the appcast came out unsigned, which is
what happens when the Sparkle key it was given is not the one the app trusts.

Existing output is not deleted. On a Mac, keep what a failed attempt left in
`build/release/<version>`, and set `SHEPHERD_RELEASE_WORK` to a fresh directory for the
retry. A workflow run starts from nothing each time.

## Verify the candidate

Verify version/build, architectures, Developer ID team, hardened runtime, every nested
CEF/helper signature, notarization/staple, third-party notices, bundled runtime integrity,
and absence of development credentials/profiles/evidence. Use private profiles of your own
for any runtime smoke tests. Do not restart or operate a copy of the app that someone is
using.

## Publish

The draft release holds these assets:

- `Shepherd-<version>.zip` (Sparkle update archive)
- `Shepherd-<version>.dmg` and `Shepherd.dmg` (installation image)
- `appcast.xml` and any delta files it references

The draft targets the exact already-pushed source commit. Creating it changes neither
Latest nor `build/updates`. A candidate that was built without uploading and then verified
can be uploaded as a draft by hand instead; do not build again under a tag that already has
a release.

Download the draft assets, compare hashes/sizes and verify the ZIP's Sparkle signature,
app/DMG notarization and Gatekeeper acceptance. Check that all appcast URLs refer to the
same release tag.

Then push an annotated tag `v<version>` that points to the exact built commit; without it,
GitHub creates a lightweight tag when the draft is published. Do not create the tag before
the build: the script stops if the tag already exists in the checkout. Only after that,
publish the draft and explicitly mark it Latest. Verify the public feed and downloads again.

After a release built on a Mac, copy `build/release/<version>/updates` into `build/updates`,
keeping the older archives that are there: later releases make deltas from them. The
workflow keeps no such directory; it downloads the published files on every run.

The repository's Pages workflow and site are independent of this procedure. Historical 0.1,
0.2.0, 0.2.1 and 0.3.0 assets remain available. Pushing source and releasing the app are
separate operations; a successful push does not mean the app was released.
