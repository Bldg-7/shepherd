#!/bin/bash
#
# Gets the browser engine the macOS app embeds — CEF, the Chromium Embedded
# Framework — and builds what Xcode needs of it into Vendor/CEF/out:
#
#   include/                         CEF's headers
#   lib/Debug, lib/Release           libcef_dll_wrapper.a, CEF's C++ API
#   Chromium Embedded Framework.framework
#   Shepherd Helper*.app             the five helper apps (CEFHelper/)
#
# CEF is too big to keep in the repository (plan item H4 in
# docs/agent-browser-plan.md), so this downloads a pinned version and checks
# it against the checksum CEF publishes for it. Run it once after cloning and
# again after changing CEF_VERSION; it does nothing when everything is
# already up to date.
#
# Usage: scripts/cef.sh

set -euo pipefail

# From https://cef-builds.spotifycdn.com/index.json, the macosarm64
# "minimal" distribution of this version.
CEF_VERSION='154.0.33+ga03e714+chromium-154.0.8037.94'
CEF_SHA1='bfa2358a5fba8d0a016118941d9cda0bf2d06f20'
# Intel Macs aren't supported for now (decision 7 in the plan).
ARCH=arm64
MIN_MACOS=26.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/CEF"
NAME="cef_binary_${CEF_VERSION}_macos${ARCH}_minimal"
ARCHIVE="$VENDOR/downloads/$NAME.tar.bz2"
DIST="$VENDOR/$NAME"
OUT="$VENDOR/out"
HELPER_SOURCES="$ROOT/CEFHelper"
HELPER_NAME="Shepherd Helper"
# The name suffixes CEF looks for, each with the bundle ID suffix and the
# entitlements its helper is signed with ("<name>:<id>:<entitlements>").
HELPERS=(
  "::Helper"
  " (Alerts):.alerts:Helper"
  " (GPU):.gpu:Helper"
  " (Plugin):.plugin:Helper-Plugin"
  " (Renderer):.renderer:Helper"
)

step() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# What the output was built from: the version, and this script and the
# helper's sources, so that changing either rebuilds it.
fingerprint() {
  {
    echo "$CEF_VERSION"
    cat "$0" "$HELPER_SOURCES"/*
  } | shasum -a 1 | cut -d' ' -f1
}
STAMP="$OUT/.built-from"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$(fingerprint)" ]]; then
  echo "CEF $CEF_VERSION is up to date in $OUT"
  exit 0
fi

if [[ ! -f "$ARCHIVE" ]]; then
  step "Downloading CEF $CEF_VERSION"
  mkdir -p "$(dirname "$ARCHIVE")"
  url="https://cef-builds.spotifycdn.com/$(printf %s "$NAME.tar.bz2" | sed 's/+/%2B/g')"
  # The archive is large and the CDN sometimes drops the connection
  # partway; -C - picks up where the last attempt stopped.
  for attempt in 1 2 3 4 5; do
    curl -fL --retry 3 -C - -o "$ARCHIVE.part" "$url" && break
    [[ $attempt == 5 ]] && fail "couldn't download $url"
    sleep 3
  done
  actual="$(shasum -a 1 "$ARCHIVE.part" | cut -d' ' -f1)"
  if [[ "$actual" != "$CEF_SHA1" ]]; then
    rm "$ARCHIVE.part"
    fail "the download's SHA-1 is $actual, not $CEF_SHA1"
  fi
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

if [[ ! -d "$DIST" ]]; then
  step "Unpacking"
  rm -rf "$DIST.partial"
  mkdir "$DIST.partial"
  tar -xjf "$ARCHIVE" -C "$DIST.partial" --strip-components 1
  mv "$DIST.partial" "$DIST"
fi

rm -rf "$OUT"
mkdir -p "$OUT"
BUILD="$VENDOR/build"
rm -rf "$BUILD"
mkdir -p "$BUILD"

# The flags CEF's own CMake files build the wrapper with on macOS
# (cmake/cef_variables.cmake), without -Werror.
CXXFLAGS=(
  -arch "$ARCH" -mmacosx-version-min="$MIN_MACOS"
  -std=c++20 -fno-exceptions -fno-rtti -fno-threadsafe-statics
  -fobjc-call-cxx-cdtors -fvisibility=hidden -fvisibility-inlines-hidden
  -fno-strict-aliasing -fstack-protector -funwind-tables
  -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS
  -I"$DIST"
)
JOBS="$(sysctl -n hw.ncpu)"

# Compiles every source of libcef_dll for one configuration and archives the
# objects. Debug and Release are both built because CEF's headers lay some
# classes out differently with and without NDEBUG: the app's own Objective-C++
# has to be linked against a wrapper built the same way.
build_wrapper() {
  local config="$1"; shift
  local objects="$BUILD/$config"
  mkdir -p "$objects" "$OUT/lib/$config"
  step "Building libcef_dll_wrapper ($config)"
  # One compiler run per source, as many at a time as there are cores. xargs
  # passes each run the source (relative to libcef_dll) and its object file.
  local compile="$BUILD/compile-$config.sh"
  printf '#!/bin/sh\nexec xcrun clang++ %s -c "%s/libcef_dll/$1" -o "$2"\n' \
    "$(printf '%q ' "${CXXFLAGS[@]}" -DWRAPPING_CEF_SHARED -w "$@")" "$DIST" >"$compile"
  chmod +x "$compile"
  (cd "$DIST/libcef_dll" && find . \( -name '*.cc' -o -name '*.mm' \) | sed 's|^\./||') |
    while IFS= read -r source; do
      printf '%s\0%s\0' "$source" "$objects/${source//\//_}.o"
    done |
    xargs -0 -n 2 -P "$JOBS" "$compile" ||
    fail "compiling libcef_dll_wrapper ($config) failed"
  xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/lib/$config/libcef_dll_wrapper.a" "$objects"/*.o
}
build_wrapper Debug -O0 -g
build_wrapper Release -O3 -DNDEBUG

step "Building the helper apps"
xcrun clang++ "${CXXFLAGS[@]}" -O3 -DNDEBUG \
  "$HELPER_SOURCES/main.cc" "$OUT/lib/Release/libcef_dll_wrapper.a" \
  -framework AppKit -framework IOSurface -lpthread \
  -o "$BUILD/helper"
for entry in "${HELPERS[@]}"; do
  IFS=: read -r suffix id_suffix entitlements <<<"$entry"
  name="$HELPER_NAME$suffix"
  app="$OUT/$name.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$BUILD/helper" "$app/Contents/MacOS/$name"
  sed -e "s/@NAME@/$name/g" -e "s/@ID_SUFFIX@/$id_suffix/g" -e "s/@VERSION@/${CEF_VERSION%%+*}/g" \
    "$HELPER_SOURCES/Info.plist.in" >"$app/Contents/Info.plist"
  # Signed here, ad hoc, only so that the entitlements and the Hardened
  # Runtime are on the bundle: Xcode signs it again when it embeds it, with
  # the app's identity, and keeps both.
  codesign --force --sign - --options runtime \
    --entitlements "$HELPER_SOURCES/$entitlements.entitlements" "$app"
done

step "Copying the framework and headers"
# CEF ships the framework flat, with everything at the top. Xcode only
# embeds a macOS framework in the usual versioned layout, so it is copied
# into Versions/A, with the usual links to it at the top. CEF and its
# helpers find the framework's binary, resources and libraries through
# those links.
framework="$OUT/Chromium Embedded Framework.framework"
mkdir -p "$framework/Versions"
ditto "$DIST/Release/Chromium Embedded Framework.framework" "$framework/Versions/A"
ln -s A "$framework/Versions/Current"
for item in "Chromium Embedded Framework" Resources Libraries; do
  ln -s "Versions/Current/$item" "$framework/$item"
done
ditto "$DIST/include" "$OUT/include"

rm -rf "$BUILD"
fingerprint >"$STAMP"
echo "CEF $CEF_VERSION is ready in $OUT"
