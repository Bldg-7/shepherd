# Shepherd's pinned SwiftTerm renderer

Base: upstream SwiftTerm1.20.0, commit
`5d14406844143538cd8f8851d2d8a67c1fe443e5` from
https://github.com/migueldeicaza/SwiftTerm. MIT license retained in LICENSE.

This is a source-vendored library/test subset, not a core fork and not a change
to the official hc0.1.17 baseline. No upstream push is implied.

## Runtime changes

Only two upstream renderer statements differ: `Buffer.savedWraparound`'s initial
value and its `softReset()` value change from false to true. See
`Tests/Terminal/SwiftTermWrap/saved-wrap-default.patch` in Shepherd. This corrects
unsaved/reset cursor restoration following DECSTR/DECRST1049. Explicitly saved
wrap-OFF remains wrap-OFF. There is no VT filtering or injected program input.

All151 copied upstream files (renderer, tests, license, upstream README/manifest)
are sealed with original/vendored SHA256 in source-hashes.json. Buffer.swift is
the only modified upstream file. SavedCursorWrapTests.swift is an added test.

## Build integration, explicitly separate from the renderer fix

- Package.swift exposes only the production SwiftTerm library and upstream tests.
  CLI/fuzzer/benchmark/docs tooling and their external dependencies are omitted.
  Upstream Apple deployment targets, Metal shader resource and Swift5 dependency
  language mode are preserved. Shepherd remains Swift6/strict; this package does
  not change the application's diagnostic settings.
- The upstream build-info plugin/tool are not run from this nested vendored
  directory: falling back to `git -C` here could mislabel SwiftTerm with the
  parent Shepherd commit. Added SwiftTermBuildInfo.swift preserves that public
  metadata API but explicitly reports the upstream base and
  `1.20.0-shepherd.saved-wrap-default.1-modified`. It is not an unmodified release.
- Package.upstream.swift and README.upstream.md retain the original upstream
  manifest/README for comparison. They are not the active package configuration.

`Tests/Terminal/SwiftTermWrap/verify-vendor.py` checks provenance, exact copied-file
inventory, the two-statement delta, and the Xcode local-package binding. Never
edit the build/SourcePackages checkout or apply patches opportunistically at
build time. The checked-in source is the product source.

## Validation boundaries

Before integration, current product6-column failure and the separately built
candidate6/80 pass were recorded at `hc-wrap-final.3iYpFx`, including wrap-OFF
preservation and owned resource retirement. These are not an integrated product
or native GUI pass. Integrated build/runtime receipts must be recorded separately.
No installed application, operator core, launchd service or backend default-root
cutover is authorized by this vendoring change.
