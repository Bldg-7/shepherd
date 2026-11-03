# Isolated hc 0.1.16 OSC8 backport

This is a **test-only source build, not an official release or an installer**.
It preserves the release's Rust sources, Cargo.lock, Ghostty C API and protocol.
Only `vendor/ghostty/src/terminal/formatter.zig` is changed, by the unmodified
upstream [Ghostty #14711](https://github.com/ghostty-org/ghostty/pull/14711) patch
(commit `510b253dbc52d77b9f842ab6b8cba9ef046cea11`, merged 2026-10-15).

`recipe.json` pins the core commit, Ghostty gitlink, patch, resulting formatter,
Cargo.lock and Zig archive/binary. Build with isolated Rust **1.95.0** (the core's
CI toolchain) and Zig **0.16.0**. No dependency update or C ABI adaptation is needed.
The two macOS GUI emission options are disabled because only libghostty-vt is used.
`-j4` bounds build concurrency, not test coverage.

## Prepare sources and tools without changing global configuration

Run from the Shepherd repository root on macOS ARM64. This fetches public sources
and compiler dependencies; the subsequent runtime tests deny external networking.
Do not point this procedure at an existing/user core checkout or installation.

```sh
REPO="$PWD"
ROOT=$(mktemp -d /tmp/hc-backport.XXXXXX)
mkdir -p "$ROOT/home" "$ROOT/tmp"
git_scratch() {
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$ROOT/home" TMPDIR="$ROOT/tmp" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git "$@"
}
git_scratch init "$ROOT/core"
git_scratch -C "$ROOT/core" remote add origin https://github.com/herdrdev/herdr-core.git
git_scratch -C "$ROOT/core" fetch --depth 1 origin e07c2a1bedd62cf4787ee026ee23ee79c7d95491
git_scratch -C "$ROOT/core" checkout --detach e07c2a1bedd62cf4787ee026ee23ee79c7d95491
git_scratch -C "$ROOT/core" submodule update --init --depth 1 vendor/ghostty
git_scratch -C "$ROOT/core/vendor/ghostty" apply --check "$REPO/Tests/CoreProtocol/backport/ghostty-14711.patch"
git_scratch -C "$ROOT/core/vendor/ghostty" apply "$REPO/Tests/CoreProtocol/backport/ghostty-14711.patch"

/usr/bin/curl -q --fail --location \
  https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz -o "$ROOT/zig.tar.xz"
printf '%s  %s\n' b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 "$ROOT/zig.tar.xz" | shasum -a 256 -c -
tar -xJf "$ROOT/zig.tar.xz" -C "$ROOT"

RUSTUP_BIN="$(command -v rustup)"
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$ROOT/home" \
  RUSTUP_HOME="$ROOT/rustup-home" CARGO_HOME="$ROOT/rustup-cargo-home" \
  "$RUSTUP_BIN" toolchain install 1.95.0 --profile minimal --no-self-update

python3 Tests/CoreProtocol/backport/build-backport.py \
  --workspace "$ROOT" --output "$ROOT/qualified" \
  --cargo "$ROOT/rustup-home/toolchains/1.95.0-aarch64-apple-darwin/bin/cargo" \
  --zig "$ROOT/zig-aarch64-macos-0.16.0/zig"
```

The builder refuses unexpected tracked/staged/untracked source changes, checks
the complete patched formatter hash and reverse applicability, and checks again
after building. It uses private HOME/TMP/Cargo/Zig/XDG directories and `--locked`.
It runs:

1. Zig formatter formatting check.
2. All matching libghostty-vt formatter tests (both Zig and C-facing test roots).
3. Release core build.
4. Rust ghostty-vt library tests.
5. Rust core library tests (not the binary target, which contains zero tests).

Test stages must execute a positive number of tests. A child Rust test harness
can print its own summary; the receipt records the final outer harness count.
Logs retain ignored/filtered counts rather than silently claiming full upstream
integration coverage. Upstream daemon integration tests are not run by this
builder; Shepherd's owned runtime tests below are the interoperability gate.

Only after all stages succeed does it produce `herdr-core-backport.tar.gz` and
`build-receipt.json`. The archive includes the executable, core license/notices,
Ghostty license, exact patch and source provenance. The receipt records archive,
binary, builder, recipe, source and toolchain hashes, commands and build-log hashes.
This is a reproducible **procedure**, not a claim of bit-identical archives across
build paths/times. A receipt is not a signature or authentication of a third-party
binary; only run artifacts built in your explicitly trusted scratch environment.

## Run the unchanged acceptance gate, plus reconnect-link coverage

After building the existing macOS Debug products:

```sh
python3 Tests/CoreProtocol/run-real-core-tests.py \
  --build-receipt "$ROOT/qualified/build-receipt.json" \
  --output "$(mktemp -d /tmp/hc-rpc.XXXXXX)/run"
python3 Tests/CoreProtocol/run-ssh-stream-tests.py \
  --build-receipt "$ROOT/qualified/build-receipt.json" \
  --products build/DerivedData/Build/Products/Debug \
  --output "$(mktemp -d /tmp/hc-ssh.XXXXXX)/run"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Tests/CoreProtocol -p test_core_test_artifact.py -v
```

`--build-receipt` is mutually exclusive with `--archive`. The latter still accepts
**only the pinned official release checksum** and still fails OSC8 qualification.
There is no checksum override, URL synthesis, skip, or expected-failure success.
The common extractor accepts only bounded regular named members; it does not
follow tar symlinks, extract paths, overwrite an existing executable or leave a
partial executable after a malformed archive.

The native gate checks initial attach, live output and fresh-connection reattach
using explicit SwiftTerm link lookup. The reconnect workload closes an OSC8 link
with an explicit ID before detach, so cursor-active-link restoration alone cannot
make the test pass. The original BURST-DONE reattach rendering check remains.
Both positive and negative runs must stop all owned processes and remove sockets.

## Scope and deployment boundary

- The binary still reports `0.1.16`. **That version string alone cannot identify
  the fixed build.** Its receipt/variant and binary hash distinguish it from the
  official archive. Do not enable arbitrary installed 0.1.16 cores on this evidence.
- No binary is checked in, installed globally, deployed, or substituted for a user
  core. App backend selection and managed distribution remain separate work.
- [Ghostty #14725](https://github.com/ghostty-org/ghostty/pull/14725), merged
  2026-10-19 (PR commit `152bdbc68075ee4bc5b4745fb908598a16fc628c`), was also reviewed.
  It fixes blank gaps, erased-background rows and wrap behavior, and adjusts the
  gap-link test from #14711. It is **not included** in this deliberately minimal
  OSC8 proof. Its broader TUI/background cases must be qualified during SHPHRD-151
  before product cutover; passing this gate is not full terminal/agent parity.
- See `docs/hc-osc8-first-paint-blocker.md` for measured results and remaining gates.
