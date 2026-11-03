# Passive-observer candidate (not a release)

This is a separate candidate from the minimal OSC8 artifact in
`Tests/CoreProtocol/backport/`. It combines only these upstream changes on the
same hc `v0.1.16` commit and Ghostty gitlink:

1. Ghostty #14711, `510b253dbc52d77b9f842ab6b8cba9ef046cea11`: per-cell OSC8.
2. Ghostty #14725, PR commit `152bdbc68075ee4bc5b4745fb908598a16fc628c`:
   blank gaps, erased backgrounds and wrap handling (merged 2026-10-19).
3. hc `5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2`: opt-in observer resize
   negotiation, ordered RESIZE/replacement paint, reply-before-stream publication,
   relay negotiation/downgrade handling and associated tests/schema.

The original upstream patches are retained unchanged. `recipe.json` pins their
hashes and every resulting changed core file, the complete formatter, Cargo.lock,
base commits and the original OSC8 recipe. No dependency lockfile or Ghostty C ABI
change is needed. This does **not** import other HEAD changes such as launchd setup.

## Prepare and build

Use a **fresh scratch workspace**, not the existing qualified OSC8 source tree.
Follow the source/compiler preparation in
`Tests/CoreProtocol/backport/README.md` through applying #14711 and preparing
isolated Rust 1.95.0 / Zig 0.16.0. Do not use that directory's builder for this
candidate: it deliberately rejects these additional source changes.

With `REPO`, `ROOT`, and the private `git_scratch` helper from that procedure:

```sh
git_scratch -C "$ROOT/core" apply --check "$REPO/Tests/CoreObservation/backport/core-observer.patch"
git_scratch -C "$ROOT/core" apply "$REPO/Tests/CoreObservation/backport/core-observer.patch"
git_scratch -C "$ROOT/core/vendor/ghostty" apply --check "$REPO/Tests/CoreObservation/backport/ghostty-14725.patch"
git_scratch -C "$ROOT/core/vendor/ghostty" apply "$REPO/Tests/CoreObservation/backport/ghostty-14725.patch"
python3 Tests/CoreObservation/backport/build-candidate.py \
  --workspace "$ROOT" --output "$ROOT/passive-qualified"
```

`--tools-workspace` can explicitly reuse an **isolated** compiler/Cargo/Zig cache
workspace; it never substitutes that workspace's core sources or target binary.
The builder uses a short private `HC_SESSION=parity` to respect Unix socket limits.
The first exploratory run's longer name exceeded the limit in an upstream test;
that failed run was retained, not waived. No core assertion was weakened.

Build checks: Zig formatting, all formatter tests, release core build, Rust VT and
core library tests, unchanged license notices. Positive test counts are required.
Source, builder and validator hashes are checked before/after the build. The
fresh output holds an executable copy, licenses/notices and a receipt with logs,
commands, toolchain and artifact hashes. No installer or user daemon is run.
This is a reproducible procedure, not a bit-identical-build or signature claim.
Only execute receipts from your explicitly trusted local build environment.

## Runtime gates

After rebuilding the macOS Debug products:

```sh
python3 Tests/CoreObservation/run-passive-core-tests.py \
  --candidate-receipt "$ROOT/passive-qualified/candidate-receipt.json" \
  --products build/DerivedData/Build/Products/Debug \
  --output "$(mktemp -d /tmp/hc-passive.XXXXXX)/run"
python3 Tests/CoreProtocol/run-ssh-stream-tests.py \
  --candidate-receipt "$ROOT/passive-qualified/candidate-receipt.json" \
  --products build/DerivedData/Build/Products/Debug \
  --output "$(mktemp -d /tmp/hc-passive-ssh.XXXXXX)/run"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Tests/CoreObservation -p test_candidate_artifact.py
```

The passive gate accepts `--baseline-receipt` instead to run the original #14711
artifact as a negative control. It must fail with `resizeNegotiated: false` and
`failure: unsupported`, while still cleaning up its private core/processes/socket.
There is no expected-failure pass. Official archive checks remain unchanged.

The SSH gate's expected resize support comes from explicit artifact selection,
not the identical `0.1.16` version string. The normal OSC8 baseline still expects
false; this candidate expects true. All previous SSH/SwiftTerm checks remain.

## Scope

The passive fixture proves ordered geometry and repaint, blank-gap/default and
background-only cells, dim attributes, CJK/emoji, OSC8, resize coalescing and return
to the core's headless grid. It drops renderer-generated responses and checks the
program receives zero input, using `terminal.read(lines:0)` only.

The fixture has an explicit PAINT-DONE marker for its assertions. Real agents do
not promise that marker. **A DATA boundary is not snapshot completion or an
empty-composer/readiness proof.** Full managed/unmanaged CLI parity, native owner
integration, safe rename/resume and production distribution remain unqualified.
The binary still reports 0.1.16; neither it nor an arbitrary installed 0.1.16 core
may be selected by version alone. No user core, global configuration, agent account,
credential approval or browser session is changed by these tests.
