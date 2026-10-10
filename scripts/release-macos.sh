#!/bin/bash
#
# Builds Shepherd for macOS, signs it with Developer ID, has Apple notarize
# it, and uploads a draft GitHub release. Publish/mark latest separately
# after artifact verification; only then does Sparkle see the new feed. docs/releasing-macos.md has the one-time setup this expects.
#
# Usage: scripts/release-macos.sh <version> [release-notes.md]
#
#   SHEPHERD_SKIP_PUBLISH=1   build, notarize with Apple and create the appcast,
#                             but do not upload to GitHub
#   SHEPHERD_SKIP_NOTARIZE=1  don't notarize either (a build to try out
#                             locally; Gatekeeper rejects it on other Macs).
#                             Implies SHEPHERD_SKIP_PUBLISH.
#   SHEPHERD_RELEASES_REPO    where releases go (Bldg-7/shepherd)
#   SHEPHERD_GITHUB_USER      the gh account to publish as (ESnark), used
#                             for this script only, whichever account gh
#                             has active
#   SHEPHERD_NOTARY_PROFILE   notarytool keychain profile (shepherd-notary)

set -euo pipefail

VERSION="${1:?usage: scripts/release-macos.sh <version> [release-notes.md]}"
NOTES="${2:-}"
REPO="${SHEPHERD_RELEASES_REPO:-Bldg-7/shepherd}"
GITHUB_USER="${SHEPHERD_GITHUB_USER:-ESnark}"
NOTARY_PROFILE="${SHEPHERD_NOTARY_PROFILE:-shepherd-notary}"
SKIP_NOTARIZE="${SHEPHERD_SKIP_NOTARIZE:-}"
SKIP_PUBLISH="${SHEPHERD_SKIP_PUBLISH:-$SKIP_NOTARIZE}"
TEAM_ID="SYZS4D43Z6"
SIGN_IDENTITY="${SHEPHERD_SIGN_IDENTITY:?set SHEPHERD_SIGN_IDENTITY to the approved Developer ID certificate fingerprint}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SHEPHERD_RELEASE_WORK:-$ROOT/build/release/$VERSION}"
# The update archives and the appcast as last published. The next release
# is offered as a delta from the archives here, and its appcast is made from
# this one — in a copy, STAGE, which only replaces this folder once it is
# published, so a release stopped halfway leaves nothing behind in it.
UPDATES="$ROOT/build/updates"
STAGE="$WORK/updates"
DERIVED="$ROOT/build/DerivedData"
SPARKLE_BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"
ARCHIVE="$WORK/Shepherd.xcarchive"
APP="$WORK/export/Shepherd.app"
TAG="v$VERSION"
ZIP="Shepherd-$VERSION.zip"
DMG="Shepherd-$VERSION.dmg"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
# The public source history differs from the earlier private history. Never
# derive Sparkle's monotonic build number from the number of Git commits.
BUILD_NUMBER="${SHEPHERD_BUILD_NUMBER:-22}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build number' >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Signed builds use the operator's existing approved Xcode/Keychain context;
# DerivedData and package/build outputs remain inside this release tree.
# Do not copy credentials, auto-approve plugins or bypass validation.
# notarytool keeps the profile in the part of the Keychain that is closed
# while the screen is locked.
notary_ready() { xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; }
# Has Apple notarize a file and waits for the verdict. The profile was there
# at the start; if it isn't now, stop rather than hiding a Keychain prompt.
notarize() {
    local file="$1" result="$WORK/notarize-$(basename "$1").json" status
    notary_ready || fail "Unlock the Mac before retrying notarization; existing output is preserved"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 15m --output-format json > "$result"
    status="$(plutil -extract status raw "$result")"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$(plutil -extract id raw "$result")" --keychain-profile "$NOTARY_PROFILE" || true
        fail "notarization of $(basename "$file") ended as $status"
    fi
}

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "the version should look like 1.2 or 1.2.3, not $VERSION"
[[ -z "$NOTES" || -f "$NOTES" ]] || fail "there are no release notes at $NOTES"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || fail "commit or stash your changes first: a release is built from the working tree, and should be what is committed"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "$TAG is already tagged here"
fi
if [[ -z "$SKIP_PUBLISH" ]]; then
    command -v gh >/dev/null || fail "publishing needs the GitHub CLI (gh)"
    # gh's active account may well be another one, kept active for other
    # work; its token is taken for this run instead of switching to it.
    release_token="${GH_TOKEN:-}"
    if [[ -z "$release_token" ]]; then
        release_token="$(gh auth token --user "$GITHUB_USER" 2>/dev/null)" || fail "Authenticate the selected GitHub account; no account fallback"
    fi
    unset GH_TOKEN GITHUB_TOKEN
    gh() { GH_TOKEN="$release_token" command gh "$@"; }
    [[ "$(gh api "repos/$REPO/commits/$(git -C "$ROOT" rev-parse HEAD)" --jq .sha)" == "$(git -C "$ROOT" rev-parse HEAD)" ]] \
        || fail "Push the exact reviewed source commit before publishing"
    [[ "$(gh api "repos/$REPO" --jq .permissions.push 2>/dev/null)" == "true" ]] \
        || fail "neither $GITHUB_USER nor gh's active account can publish to $REPO"
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
        fail "$REPO already has a release $TAG"
    fi
fi
if [[ -z "$SKIP_NOTARIZE" ]]; then
    notary_ready || fail "notarytool can't use the profile $NOTARY_PROFILE: register it (docs/releasing-macos.md, 2-4), or unlock the screen if it is locked"
    # An idle Mac would lock its screen, and with it the profile, while the
    # archive is being built.
    caffeinate -di -w $$ &
fi

[[ ! -e "$WORK" ]] || fail "Output already exists; preserve it and use SHEPHERD_RELEASE_WORK for a fresh attempt"
[[ -f "$ROOT/Shepherd/Agents/AgentRuntime/node_modules/@playwright/mcp/package.json" ]] || fail "Prepare the locked browser runtime before archiving"
[[ -d "$ROOT/Vendor/CEF/out/Chromium Embedded Framework.framework" ]] || fail "Run scripts/cef.sh before archiving"
if [[ -f "$UPDATES/appcast.xml" ]]; then
    python3 - "$UPDATES/appcast.xml" "$BUILD_NUMBER" <<'PY'
import sys,xml.etree.ElementTree as ET
tree=ET.parse(sys.argv[1]); version='{http://www.andymatuschak.org/xml-namespaces/sparkle}version'
values=[int(e.text) for e in tree.iter(version)]
values += [int(e.get(version)) for e in tree.iter('enclosure') if e.get(version) is not None]
assert values and int(sys.argv[2]) > max(values), 'Build number must exceed the prior appcast'
PY
fi
step "Signing pinned CEF framework and helper inputs"
python3 "$ROOT/scripts/sign-cef.py" --identity "$SIGN_IDENTITY"
step "Archiving Shepherd $VERSION ($BUILD_NUMBER)"
mkdir -p "$WORK"
xcodebuild archive -quiet \
    -project "$ROOT/shepherd.xcodeproj" -scheme Shepherd -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
    -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -jobs 4 \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

step "Exporting with Developer ID"
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$SIGN_IDENTITY</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -quiet \
    -archivePath "$ARCHIVE" -exportPath "$WORK/export" -exportOptionsPlist "$WORK/ExportOptions.plist"
codesign --verify --deep --strict "$APP"
[[ "$(codesign --display --verbose=2 "$APP" 2>&1)" == *"TeamIdentifier=$TEAM_ID"* ]] \
    || fail "the exported app isn't signed by team $TEAM_ID"

if [[ -z "$SKIP_NOTARIZE" ]]; then
    step "Notarizing the app (this takes a few minutes)"
    ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
    notarize "$WORK/notarize.zip"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
fi

# The disk image people download to install: the app, and a link to
# Applications to drag it onto. It is signed with the very certificate the
# app is (this Mac has two of the same name, and codesign won't pick one by
# name), and notarized too, so that Gatekeeper lets it open. A copy named
# Shepherd.dmg goes into every release, so that
# releases/latest/download/Shepherd.dmg is always the newest.
step "Making the disk image"
rm -rf "$WORK/dmg"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Shepherd.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname Shepherd -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$WORK/$DMG"
codesign --display --extract-certificates="$WORK/signer" "$APP" 2>/dev/null
codesign --sign "$(shasum -a 1 "$WORK/signer0" | cut -d' ' -f1)" --timestamp "$WORK/$DMG"
if [[ -z "$SKIP_NOTARIZE" ]]; then
    notarize "$WORK/$DMG"
    xcrun stapler staple "$WORK/$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$WORK/$DMG"
fi
cp "$WORK/$DMG" "$WORK/Shepherd.dmg"

step "Adding $VERSION to the appcast"
mkdir -p "$UPDATES"
cp -R "$UPDATES" "$STAGE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/$ZIP"
if [[ -n "$NOTES" ]]; then
    cp "$NOTES" "$STAGE/Shepherd-$VERSION.md"
fi
# One version per appcast: every file it names is then in this release, so
# one download prefix covers them all — the new archive, and the deltas
# from earlier versions to it. An app older than the one before still
# updates; it just downloads the whole archive.
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --maximum-versions 1 \
    --embed-release-notes \
    "$STAGE"

# What the appcast points into this release, by file name.
uploads=()
while IFS= read -r url; do
    uploads+=("$STAGE/${url#"$DOWNLOAD_PREFIX"}")
done < <(grep -o "${DOWNLOAD_PREFIX}[^\"]*" "$STAGE/appcast.xml" | sort -u)
[[ ${#uploads[@]} -gt 0 && " ${uploads[*]} " == *" $STAGE/$ZIP "* ]] || fail "the appcast doesn't offer $ZIP"

if [[ -n "$SKIP_PUBLISH" ]]; then
    step "Stopped before publishing"
    printf 'App:      %s\nDisk:     %s\nAppcast:  %s\nUploads:  %s\n' "$APP" "$WORK/$DMG" "$STAGE/appcast.xml" "${uploads[*]}"
    exit 0
fi

step "Publishing $TAG to $REPO"
notes_args=(--notes "Shepherd $VERSION")
if [[ -n "$NOTES" ]]; then
    notes_args=(--notes-file "$NOTES")
fi
# Sparkle reads the feed from the latest release
# (releases/latest/download/appcast.xml), so this one is marked latest.
# Upload as a draft first. Publishing/latest is a separate explicit action
# after download, signature and artifact checks; never change the live feed here.
gh release create "$TAG" --repo "$REPO" --target "$(git -C "$ROOT" rev-parse HEAD)" --title "Shepherd $VERSION" --draft \
    "${notes_args[@]}" "${uploads[@]}" "$STAGE/appcast.xml" "$WORK/$DMG" "$WORK/Shepherd.dmg"
# The published-update cache and source tag are finalized only after the
# operator verifies and publishes the draft. Failed/draft outputs stay in WORK.

step "Draft uploaded — verify downloads before publishing and marking latest"
printf 'Feed (unchanged until publication): https://github.com/%s/releases/latest/download/appcast.xml\n' "$REPO"
printf 'Download: https://github.com/%s/releases/latest/download/Shepherd.dmg\n' "$REPO"
printf 'Tagged the commit it was built from as %s.\n' "$TAG"
