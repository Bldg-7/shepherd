# SHPHRD-157: hc first paint drops OSC8 cell hyperlinks

## Decision / impact

**Do not mark SHPHRD-150 or the backend cutover complete against official hc 0.1.16.**
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

## Required fix and acceptance

The change belongs in the VT formatter or a core snapshot representation that
actually carries the missing metadata. Required work:

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

No patched daemon has been installed or distributed. Publishing an upstream PR
or adopting a maintained fork is a separate external/dependency decision; the
client cannot recover a destination that was never transmitted.
