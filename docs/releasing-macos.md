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
   build 24; 0.3.1 used build 25; 0.3.2 used build 26; 0.3.3 used build 27; 0.4.0 used build 28; 0.5.0 used build 29; 0.5.1 used build 30; 0.5.2 was built as a draft with build 31 and not published; **0.6.0 uses build 32**. A new build number must be higher than the one in the
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
gh workflow run release-macos.yml --repo Bldg-7/shepherd -f version=0.6.0 -f build_number=32
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
  releases into `build/updates`. Archives of releases before 0.5.0 are named
  `Shepherd-<version>.zip` and archives from 0.5.0 on `hrdrhrdrhrdr-<version>.zip`; the
  workflow downloads archives under either name. The script checks the build number against that appcast and
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

1. Prepare the pinned Swift dependencies. hc Release needs neither CEF nor Node.
2. Verify the local renderer with `python3 -B Tests/Terminal/SwiftTermWrap/verify-vendor.py`.
   Keep plugin validation enabled; do not write global trust overrides.
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

Ordinary hc Debug and Release exclude the CEF browser framework/helpers,
AgentRuntime, capture proxy executable and capture LaunchAgents. Both compile
only the explicitly unavailable Objective-C browser interface, on arm64 as well
as Intel; CEF implementation, headers, wrapper, loader and ChromiumCredits.html
are not normal product inputs/payloads. Real CEF remains only in the explicitly
selected Apple-silicon Debug fixture application.
There is no CEF preparation/download, Node install or CEF signing step in the hc
release workflow. Vendored SwiftTerm provenance is verified without
writing a global plugin-trust file; plugin validation stays enabled.

The ordinary `Shepherd` scheme selects only the hc application for every action,
including a CLI `-configuration Release build`. No normal configuration selects
the legacy SDK, capture helper, CEF, Node or historical UI/runtime implementation.
`ShepherdLegacyFixtures` is a disjoint-source SDK product consumed only by the
separate `Shepherd Legacy Fixtures` application/scheme. That fixture app has its
own bundle identity, requires an explicitly isolated launch, sets
`SKIP_INSTALL=YES`, and is not an archive/profile build root. Historical source
and user archives/settings/services are preserved, not deleted for this split.

The product gate checks the exact normal SDK per-slice compiler source lists,
link inputs and symbols, and rejects stale compiled fixture/browser products as
well as payloads. Shared models, archive codecs and pinned SSH/crypto are retained
intentionally; their historical folder names are not executable legacy backends.

This is a packaging policy, not authorization to update a user's installation.
An older installed capture LaunchAgent can point into the old app bundle. Do not
deploy this helper-free app over an active capture installation without a separately
approved handover that preserves its programs/data; do not infer retirement from a
route list or automatically stop/unregister it. Local packaging tests do not qualify
that service transition, signing or notarization.

It archives, exports/signs, notarizes, staples the app and DMG, runs Gatekeeper checks, and
signs the Sparkle feed. It stops if the update in the appcast came out unsigned, which is
what happens when the Sparkle key it was given is not the one the app trusts.

Right after export, `Tests/HcBackend/hc_release_bundle.py --app` rejects excluded
browser/helper/Node/proxy/LaunchAgent payloads, including nested/stale files and
escaping symlinks. It also checks the actual executable's Mach-O architectures and
load commands and CEF/legacy executable SDK symbols: Sparkle must remain linked,
but CEF code, its runtime and old client/transport/monitor/attach code must be absent.
Normal Debug inspection separately checks Xcode's launcher **and** its actual
`.debug.dylib` implementation image; that is not a Release export qualification. Reused DerivedData can retain retired files; a fresh archive must pass
without post-build stripping. Never delete an in-use build/cache or user app to make
a check pass. The old CEF-helper-name and proxy-bundle gates remain available for
explicit legacy Debug fixtures; they are not the hc Release payload policy.

The script then runs `Tests/Notices/run-notices-tests.py --profile hc --app --products`.
Before archiving it temporarily stamps the requested notice version and restores the
reviewed source on exit. The offline hc profile preserves frozen license/source hashes
and the reviewed remote-pin set, with only the explicit SwiftTerm/CLI-parser vendoring
delta. It verifies vendored renderer hashes, the unchanged MIT license and modified
version attribution. Node/runtime package checks belong to the explicit retained
`legacy-fixture` profile, not an absent hc payload. This does not waive any license
for linked SSH, crypto or archive-codec code. The frozen historical CEF inventory
and explicit `legacy-fixture` checks remain; the hc profile does not require an
unshipped CEF distribution. Historical attribution does not assert that it ships.

The hc gate receives the `.xcarchive` and its exact Release DerivedData, compares
archive/export Info.plist and architecture identities, and reads the app target's
exact link-file-list for every slice. Each required static product must be a real
non-empty Mach-O object at its expected product path and an actual app link input;
this includes `AgentProxyCore` and `AgentProxyProtocol` for archive reading, not an
unshipped `AgentProxyForwarder` helper. Each slice's browser interface object is
checked for absence of CEF implementation/wrapper symbols too. Source build settings
must not reintroduce a CEF header or linker path.
The exported main executable, archived main and exact app-target dSYM under
`ArchiveIntermediates/Shepherd/BuildProductsPath` must have matching `LC_UUID`s.
Sparkle must be embedded and directly loaded. Required notice bytes and bundle
version must match source; stale Chromium credits are rejected like other retired
payloads. Wrong targets/roots, empty objects and merely
similar names fail closed. UUIDs prove ordinary build coherence, not cryptographic
attestation against a malicious builder. The frozen legacy helper profile is not
relabeled as hc release evidence.

Existing output is not deleted. On a Mac, keep what a failed attempt left in
`build/release/<version>`, and set `SHEPHERD_RELEASE_WORK` to a fresh directory for the
retry. A workflow run starts from nothing each time.

## Verify the candidate

Verify version/build, architectures, Developer ID team, hardened runtime, retained
framework signatures, notarization/staple, third-party notices, absence of excluded
integration payloads, and absence of development credentials/profiles/evidence. The automated notice gate is not
a replacement for a human resource review: in the candidate app, inspect
`Contents/Resources/ThirdPartyNotices.txt` for the matching header version and the unique
two BoringSSL sections, Niels Provos, WIDE Project, Rich Felker, and uSHET. Confirm
ChromiumCredits.html, CEF and Node are absent from hc Release. Viewing Chromium
credits applies only to an explicitly retained browser Debug fixture, not this
candidate; do not automate a browser for it. Use private profiles
of your own for any runtime smoke tests. Do not restart or operate a copy of the app that
someone is using.

## Publish

The draft release holds these assets:

- `hrdrhrdrhrdr-<version>.zip` (Sparkle update archive)
- `hrdrhrdrhrdr-<version>.dmg` and `hrdrhrdrhrdr.dmg` (installation image)
- `appcast.xml` and any delta files it references

The draft targets the exact already-pushed source commit. Creating it changes neither
Latest nor `build/updates`. A candidate that was built without uploading and then verified
can be uploaded as a draft by hand instead; do not build again under a tag that already has
a release.

Download the draft assets, compare hashes/sizes and verify the ZIP's Sparkle signature,
app/DMG notarization and Gatekeeper acceptance. Check that all appcast URLs refer to the
same release tag, and that the appcast item for this version carries the release notes.

Then push an annotated tag `v<version>` that points to the exact built commit; without it,
GitHub creates a lightweight tag when the draft is published. Do not create the tag before
the build: the script stops if the tag already exists in the checkout. Only after that,
publish the draft and explicitly mark it Latest. Verify the public feed and downloads again.

After a release built on a Mac, copy `build/release/<version>/updates` into `build/updates`,
keeping the older archives that are there: later releases make deltas from them. The
workflow keeps no such directory; it downloads the published files on every run.

The repository's Pages workflow publishes the site separately, but the site's download
buttons point to `releases/latest/download/hrdrhrdrhrdr.dmg`, so they work only while
the Latest release has that file. Historical 0.1,
0.2.0, 0.2.1 and 0.3.0 assets remain available. Pushing source and releasing the app are
separate operations; a successful push does not mean the app was released.
