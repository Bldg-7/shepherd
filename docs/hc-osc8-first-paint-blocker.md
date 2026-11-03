# SHPHRD-157: hc first paint drops OSC8 cell hyperlinks

## Decision / impact

**Resolved for the explicitly pinned #14711 source backport; official hc 0.1.16 remains incompatible.**
The A2 transport qualification now passes against that private build. This is not
approval for product cutover, arbitrary installed 0.1.16 binaries, or deployment.
The local/SSH transport and stream implementation works, but an already-printed
OSC8 link loses its destination when attached/repainted. This breaks the existing
explicit-file-link preview policy: an arbitrary visible label cannot reconstruct
a file or web URI. Do not compensate by guessing plain-text paths, sending a
redraw/control key into the user's program, or restarting that program.

The app still uses its existing backend. No user core or global settings were
replaced. The new implementation is available for qualification, not enabled in
normal UI operation.

## Reproduction and contrast

Use `Tests/CoreProtocol/run-ssh-stream-tests.py` as described in that directory's
README. It uses an isolated core, an ephemeral loopback SSH server, a private
terminal workload and a native SwiftTerm view in a never-shown window.

1. The owned terminal emits an OSC8 open for `https://example.invalid/owned`,
   prints `owned-link`, closes the hyperlink, and reports idle.
2. A later `terminal.attach` gives the client its first paint.
3. Raw channel DATA contains `owned-link`, but neither the destination URI nor
   an OSC8 hyperlink open for that text. SwiftTerm's explicit link lookup is nil.
4. The same program is asked to emit a new live OSC8 link after attachment.
   Raw output and SwiftTerm's explicit lookup preserve that destination.

This distinguishes missing core snapshot metadata from SSH escaping, the client's
frame routing, or SwiftTerm's live OSC8 parser.

The test records the initial failure but continues through CJK/emoji, SGR, live
OSC8, native IME commit, kitty Ctrl+B, raw Ctrl+B-q, SGR mouse, resize, display
queries, output larger than the 256 KiB credit window, event subscription,
observer restrictions, reconnection/first paint, stale-handle rejection and
cleanup. It still exits nonzero at the end. **There is no ignore/skip flag that
turns the failing qualification into a pass.**

## Evidence

- Official archive: `https://releases.herdr.dev/core/0.1.16/herdr-core-macos-aarch64.tar.gz`
- SHA-256: `698d8f0c44f4e4b15fec174d52a39d57a014cfd71added44b53a0753b469d0fd`
- Release git tag `v0.1.16`: `e07c2a1bedd62cf4787ee026ee23ee79c7d95491`.
- That tag's `vendor/ghostty` gitlink: `1e5cdb865807abc990181efb8ebfa9122955cce2`
  (confirmed with `git ls-tree v0.1.16 vendor/ghostty`, not assumed from HEAD).
- Full gated run: `/private/tmp/hc-ssh.p4YctX/run/validation.json`.
- Raw snapshot and individual checks: same folder's `ssh-streams.log`.
- `report.json`: 31 other checks completed, `osc8Live: true`,
  `osc8FirstPaint: false`, `passed: false`; private core stop acknowledged.
- The runner confirms private daemon exit and socket removal. Final run has no
  supervisor kill and no callbacks scheduled after SSH EventLoop shutdown.
- Independent stream fixtures: `/private/tmp/hc-streams.xrhvot/run/validation.json`
  (7 stages pass, including Swift 6 and iOS 17 typecheck).

Checksums establish correspondence to the release manifest, not an independent
cryptographic signature. Tests use no private SSH keys, provider accounts,
installed core state or real coding-agent sessions.

## Source-level cause

The pinned [Ghostty formatter](https://github.com/ghostty-org/ghostty/blob/1e5cdb865807abc990181efb8ebfa9122955cce2/src/terminal/formatter.zig)
explicitly handles per-cell hyperlinks only in HTML:

- [Lines 1471–1510](https://github.com/ghostty-org/ghostty/blob/1e5cdb865807abc990181efb8ebfa9122955cce2/src/terminal/formatter.zig#L1471-L1510):
  hyperlink transitions skip every format except HTML; the comment identifies VT
  OSC8 emission as future work.
- Around line 1696: the cell-run fast path checks hyperlink transitions only for
  HTML. Merely changing the slow path would still skip links in simple runs.
- Around lines 2090–2135: `formatHyperlinkOpen` declares `.vt` unreachable;
  `formatHyperlinkClose` returns without emitting anything for VT.
- Around lines 626–628 and 770: `ScreenExtra.hyperlink` restores the **cursor's
  currently active hyperlink**, not the hyperlinks already stored on cells.

The core enables that extra in its formatter and then uses VT output for first
paint. Consequently, the extra flag does not fix the lost links after an OSC8
close. The live stream is unaffected because the core forwards the original
program bytes.

## Fix and acceptance

The earlier conclusion that a new upstream implementation was needed was premature.
[Ghostty #14711](https://github.com/ghostty-org/ghostty/pull/14711) was already merged
on 2026-10-15: `510b253dbc52d77b9f842ab6b8cba9ef046cea11`. Its unmodified patch applies
to the release-pinned Ghostty. The following acceptance requirements are retained:

- Emit per-cell OSC8 transitions in VT, preserving URI/id semantics and safely
  handling control characters; keep cursor-state restoration independent.
- Update both slow and fast formatting paths, and validate line wrapping,
  history/selection, adjacent links, same-URI/different-ID links and final close.
- Add upstream formatter tests, rebuild core from a pinned source/toolchain and
  retain provenance. A public fixed release or an explicitly maintained patched
  core must then be selected for the app's qualification baseline.
- Run the full SSH/core/SwiftTerm suite with `osc8FirstPaint: true` and
  `passed: true`, including reconnect and cleanup. Do not change the visible
  labels or remove the assertion to manufacture a passing result.

## Backport qualification result

Only `formatter.zig` changes; no Rust source, dependency lockfile, C ABI or wire
protocol change. The recipe, original upstream patch and license, isolated builder
and reproduction commands are in `Tests/CoreProtocol/backport/`. Rust 1.95.0 and
Zig 0.16.0 were installed only inside the scratch directory, not globally.

| Check | Pinned backport | Official 0.1.16 control |
|---|---|---|
| Initial OSC8 cell link | preserved | missing |
| Live OSC8 | preserved | preserved |
| Fresh SSH reconnect OSC8 cell link | preserved | missing |
| Other native integration checks | 32 passed | 32 completed |
| Entire qualification | passed, exit 0 | failed, exit 1 |
| Owned processes exited / socket removed | yes | yes |

The reconnect fixture emits and closes an explicit-ID hyperlink before detach.
Both the original BURST-DONE rendering assertion and the added reconnect URI
assertion remain. No URL is reconstructed from text, no redraw is requested, and
no failure is waived. Both runs have zero supervisor signals.

Final evidence (local scratch artifacts, not durable download links):

- Build receipt and full logs: `/private/tmp/shp-hc-backport.PfyX5A/qualified/`.
- Backport SSH/SwiftTerm: `/private/tmp/qualified-backport-ssh.TbWItL/run/validation.json`.
- Backport local RPC: `/private/tmp/qualified-backport-rpc.F0pbDe/run/validation.json`.
- Official negative control: `/private/tmp/final-official-ssh-negative.oVTIqW/run/validation.json`.
- Independent Swift 6 protocol fixtures: `/private/tmp/hc-backport-fixtures.1sI5OJ/run/validation.json` (7 stages).
- Zig formatter tests: 309 passed (147 + 162 across the two test roots).
- Rust VT library: 10 passed. Core library outer harness: 89 passed, 1 ignored;
  its subprocess helper separately ran 1 test. This is not all upstream daemon integration tests.
- Artifact selection/extraction: 14 Python tests passed, including rejection of
  changed receipts/logs, zero tests, wrong hashes, unsafe tar members and overwrite.
- Upstream notice regeneration leaves `THIRD-PARTY-NOTICES` unchanged.

Hashes of the qualified artifact:

- Binary: `e5b63cfa1f4440c14ca87a9d2b8b9ba8c2669a5865931bb587593e32b5d3715f`.
- Archive: `0d716c310e7a3df4c56c1216044415d021359be9c472cf4690b6d883df87cd73`.
- Patch: `35d3b2bce1f61865b282c2c40b25dde6337c66862e163d20d8f5a99a421c5f47`.
- Patched formatter: `46d49949dd4f1d82e882c83de856c47050abc54f40f2d0cb853c6fa39fe4206e`.

## Remaining product boundary

The backport still reports version `0.1.16`; **a version string is insufficient to
select it**. The test runners require the exact recipe/build receipt and artifact
hashes via explicit `--build-receipt`. Official `--archive` mode keeps its original
fixed checksum and red result. Receipts are consistency evidence, not signatures.

[Ghostty #14725](https://github.com/ghostty-org/ghostty/pull/14725), merged 2026-10-19,
was reviewed too. It addresses separate blank-gap/erased-background/wrap fidelity,
not the missing per-cell OSC8 emission itself. It is not included in this minimal
backport. Those broader TUI cases remain part of SHPHRD-151 parity qualification.

No patched daemon has been installed, pushed or distributed, and the app still
uses its existing backend. SHPHRD-151–154, production artifact selection and any
maintained patched-core distribution remain separate gates. The unrelated
FilePreview regression tracked in SHPHRD-156 is not resolved by this work.
