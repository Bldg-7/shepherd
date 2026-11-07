# Official hc release baseline

## Product decision (2026-11-04)

Use **official hc 0.1.17**, generation 1, for the Shepherd release baseline. The
user accepted non-crashing/non-unusable core limitations rather than taking on a
separately maintained app-managed formatter fork. This supersedes the earlier
"wait for a fixed official release or maintain a patched core" decision request.
`0.17.0` in that request refers to the previously discussed hc **0.1.17**, not a
new Shepherd marketing version or a nonexistent selected archive.

This selects the core baseline and authorizes release work; it is **not evidence
that Shepherd's remaining migration or release qualification is complete**.

## Artifact and compatibility

- Manifest: https://releases.herdr.dev/core/0.1.17/manifest.json
- Tag: `v0.1.17`, `ce87721557176f6cddaac1c7aefbf76929923263`.
- macOS ARM64 archive SHA-256:
  `cedbd4d4d9ba1385588198dd4d3c67d2654478f33add5b6445d4d0eb9da5fcf3`.
- macOS x86-64 archive SHA-256:
  `e2dc3211edb1f1c77d0e73dd76c1426636d71050f34a5303916a56d363d7062b`.

A checksum establishes consistency with the manifest, not an independent
signature. App connections still negotiate API generation and required methods;
this is not permission to reject a compatible user's core solely by its version
string. The older private 0.1.16-based backports remain test controls, **not** the
release artifacts. No third-party core release is published by Shepherd.

The installation help pins `HC_VERSION=0.1.17` on the **sh** side of the pipe.
It must not silently resolve `latest`. Showing a command does not execute it.
The official installer calls `update --from` for an existing binary, which can
perform a running-core handover; the help explicitly warns of this instead of
suggesting that executing the command cannot restart/update a live core.

## Accepted rendering limitations, not green fidelity gates

1. Initial attach/reconnect loses destinations of already-printed closed OSC8
   cell hyperlinks. Live OSC8 passes. File-link preview cannot reconstruct a lost
   URI from its visible label and must not guess one or send a forced redraw.
2. VT repaints can give a blank gap the previous text's background, omit
   background-only rows, and alter blank-cell/wrap fidelity.

The retained official SSH integration completed 34 checks with live OSC8 true,
first-paint/reconnect OSC8 false. The passive fixture stops at the default-gap
background assertion. These are **not observed crashes** in the tested cases,
nor proof that every real TUI remains usable. Lost essential text, unreadable
real-agent UI, broken input, crashes, data corruption or lost programs remain
release blockers if found. The product discloses the limitations.

Do not turn these negative tests into passes: preserve their nonzero exit and
report them as known, accepted upstream limitations separately from required
protocol, lossless-credit, ownership, cleanup and product-usability checks.

## Upstream state

- [Ghostty #14711](https://github.com/ghostty-org/ghostty/pull/14711) is merged:
  per-cell OSC8 VT output.
- [Ghostty #14725](https://github.com/ghostty-org/ghostty/pull/14725) is merged:
  default gaps/erased backgrounds/wrap fidelity.
- hc master and v0.1.17 still pin Ghostty
  `1e5cdb865807abc990181efb8ebfa9122955cce2`. Submitted
  [hc #117](https://github.com/herdrdev/herdr-core/pull/117), commit
  `289d696d94e61ff2ae8acac53427609bf1e6de02`, with two before/after Rust
  `Terminal::paint` regressions. The PR is open, not merged or released.

Local upstream evidence: `/var/tmp/hc-upstream-formatter.EyLRSx/logs-final`.
Both new tests fail on the old pin; after the bump VT13, formatter325,
core-library146 + one separately executed helper pass (one existing ignored).
Core build/notices pass. `just check` is unavailable locally; full CI is not
claimed from those narrower results. An earlier long-session-name socket failure
is retained separately in `logs`. [GitHub CI run `41817190148`](https://github.com/herdrdev/herdr-core/actions/runs/41817190148)
completed **success** for this exact head (lint, upgrade, Linux/macOS/Windows
and aggregate checks). That does not merge or release the PR.

App baseline-policy evidence: `/private/tmp/hc-official-policy.LZ7qAr`: official
0.1.17 detect/bootstrap34 (owned cleanup/TCP denial), macOS/iOS Debug builds pass.
These builds do not substitute for GUI or release qualification.

The bump uses official Ghostty commit
`891a4dba5757f7bd4db0e927d0d68032320783ff`, containing both fixes. It is 144
commits ahead of the old pin, so ABI/dependency/binary-snapshot upgrade CI review
is explicitly required, not hidden as a formatter-only source change.

## macOS privacy is a different issue

[hc #83](https://github.com/herdrdev/herdr-core/issues/83) reports launchd privacy
attribution and repeated prompts. [hc #105](https://github.com/herdrdev/herdr-core/pull/105)
(signed core identity) is merged **after**, and is not an ancestor of, v0.1.17.
Do not claim that shipping official 0.1.17 contains this fix or eliminates prompts.

Observed TCC records attribute Music/Photos/Desktop/Documents requests from one
`/usr/bin/find` process to the installed core's responsible identity. The
Documents request was denied. The triggering command's full argv/traversed path
and its exact relationship to this agent's commands are not established. This
is not evidence of core itself reading every protected library, nor evidence
that no user-visible side effect occurred. Project tooling must only search
known owned output roots, not recursively walk all of `/private/tmp`. No privacy
grant is auto-approved, reset or broadened, and Full Disk Access is not a setup
requirement. A user-selected protected project can legitimately need its own
file access approval.

## Independent unfinished release gates

Scoped foreground/key-window/native-command runs now pass, but whole-UI and
physical edge/IME/drag gates remain unqualified; this decision does not waive them.
The operator separately directed the [default source root switch](hc-default-backend-cutover.md)
to hc. Gateway/installation integration, deployment qualification and full legacy
target/dependency retirement remain unfinished. In-app browser and
capture-based conversation collection/mobile display are explicitly deferred
under [hc-migration-scope.md](hc-migration-scope.md), not release gates for this
migration. Their unqualified results remain unqualified, not passed. Release
build success alone must not publish the old/default backend as an hc migration.
Existing signing, notarization, exact-source and candidate verification rules
still apply. No running user's core is replaced or restarted by this decision.
