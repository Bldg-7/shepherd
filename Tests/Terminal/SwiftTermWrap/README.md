# Narrow-view live VT truncation — current renderer blocker

## Finding

The current product SwiftTerm1.20.0 (`5d14406844143538cd8f8851d2d8a67c1fe443e5`)
truncates live output following the official hc0.1.17 reconnect snapshot at6
columns. The same live bytes render normally at80. The core's own terminal.read
retains the full text, so this evidence does not show input or transport loss.

The snapshot begins with DECSTR (`CSI ! p`) then normal-screen restorations
including DECRST1049. SwiftTerm `Buffer.softReset()` resets savedWraparound to
false; restoring cursor after1049l restores that value. A fresh parser's saved
wrap default is also false. Thus the preformatted snapshot looks correct, but
following live text overwrites the rightmost cell rather than wrapping.

The diagnostic's separate ESC7-initialized parser **does not fix this**: DECSTR
resets the saved value again. This is not proposed as an application workaround.

`saved-wrap-default.patch` changes only these two defaults to true. It does not
filter core VT, insert program input, force the active wrap mode, or fork the
core. A paired explicit wrap-OFF/alternate-screen/restore remains wrap-OFF.

## Evidence

- Native `.h_45eof_`: partial47-pass then raw-peer ready marker fails; actual
  renderer6 columns shows `HC-DRY`. Other native gates before that failure were
  exercised, but this is not an overall UI pass.
- `hc-narrow-render.sxYyxp`, `hc-narrow-linked.fvJ0VA`: diagnostic compile failures
  (product module dependency maps), not runtime/render outcomes.
- `hc-narrow-product.aSt3zs`: actual unmodified product SDK/SwiftTerm and official
  core, rawReady+coreReady true at80/6, renderedReady false only at6.
- `hc-wrap-attribution.XlNay1`: separate ESC7 initialization still fails at6;
  explicit disabled wrap remains preserved. No production path was modified.
- `hc-wrap-comparison.4gFBMa`: identical diagnostic test source baseline fails,
  candidate passes both viewport cases with explicit disabled-wrap preservation.
  Both private cores/programs/socket/client were retired. See recipe.json and
  the retained source/product hash receipts. Candidate uses a derived diagnostic
  manifest with the actual target/resources/plugin, omitting unrelated CLI/docs
  dependencies. Its normal Swift5 dependency language mode is unchanged; the
  Shepherd diagnostic executable remains Swift6/strict/warnings-as-errors.

- `hc-wrap-final.3iYpFx`: final runner default attach9 passes, expected current
  renderer negative is confirmed (not counted as a pass), and candidate80/6
  cases pass. Renderer/product/map hashes are checked before/after. All three
  private scopes retire. This confirms the diagnostic override did not break
  the default attach runner.

At the diagnostic checkpoint the app renderer pin had not changed. With the
operator's subsequent approval, `Vendor/SwiftTerm` now supplies the product
renderer; see its PROVENANCE.md and `verify-vendor.py`. Integrated build/runtime
validation is a separate gate from the candidate evidence above.

Integrated evidence: `/private/tmp/hc-renderer-direct.Ts3ya4` passes the69 selected
renderer/parser tests (including8 new parameter cases), actual product6/80
rendering with explicit disabled-wrap preservation, macOS Debug/Release,
iOS Debug, original UI component suite and UI wiring20. Actual product identity
is `1.20.0-shepherd.saved-wrap-default.1-modified`, with no diagnostic renderer
override. Every stage exits naturally with zero runner signals. This is still
not an overall native GUI/release pass.

Earlier roots `hc-renderer-integrated.dKY6kl`, `hc-renderer-locked.157s03`, and
`hc-renderer-ios.GLOpoA` remain failed bounded-stage attempts: compilation itself
succeeded but owned helper retirement required SIGTERM. The executable-only
receipt identified Xcode's `ibtoold` pool, not the app/core. Final private build
environment sets `IBToolNeverDeque=1` (this pinned Xcode's direct-exec path),
without changing global preferences, extending grace or waiving any signal.
`run-stage.py` now records executable names only for verified owned survivors;
it still records no argv and keeps the same failure/teardown criteria.

Neither the candidate nor its headless result qualifies installed app replacement, native GUI, full UI parity,
fullscreen, provider/native identity, service lifetime or release cutover. The
core baseline stays official0.1.17. No upstream push has been performed.

## Reproduce

Unmodified product (expected negative until the renderer dependency is fixed):

```sh
python3 -B Tests/HcBackend/run-tests.py --narrow-render-tests \
  --products build/DerivedData/Build/Products/Debug \
  --official-017-archive /tmp/shepherd-official-hc-0.1.17.tar.gz \
  --output /private/tmp/<new-baseline-root>
```

For an independently rebuilt candidate, clone the exact base commit into a new
owned root (never edit the existing package checkout). Apply the checked-in
patch, preserve the original Package.swift, and copy Package.diagnostic.swift
as that clone's Package.swift. Build using a fresh HOME/TMPDIR/module cache,
no inherited auth environment/Git credentials, `swift build --target SwiftTerm
--jobs 4`, and a scratch build path in that root. The recorded candidate used
Xcode's SwiftPM Xcode build system, whose products are at
`<scratch>/out/Products/Debug`.

```sh
python3 -B Tests/HcBackend/run-tests.py --narrow-render-tests \
  --products build/DerivedData/Build/Products/Debug \
  --renderer-products <candidate-products> \
  --official-017-archive /tmp/shepherd-official-hc-0.1.17.tar.gz \
  --output /private/tmp/<new-candidate-root>
```

For the integrated product, omit `--renderer-products`: the runner checks the
modified renderer identity and vendored-source freshness in the actual app's
products. `python3 -B Tests/Terminal/SwiftTermWrap/verify-vendor.py` separately
checks source provenance and the local-package binding.

The override is diagnostic-only, recorded explicitly, and rejected without
`--narrow-render-tests`. Raw VT and per-case core/render results are retained.
The selected SDK/product/module-map hashes are checked before/after execution.
Do not weaken the failed assertion or remove it from the GUI audit to manufacture
an overall pass. The current native rerun remains a separate gate after integrated
headless/build validation.
