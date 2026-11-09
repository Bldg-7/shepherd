# CEF implementation/build-input retirement from hc Release

> Historical stage. The subsequent [fixed code/build cleanup](CODE-CLEANUP-README.md)
> supersedes this stage's remaining ordinary-Debug fixture/SDK coupling and its
> CLI Release-build caveat. The original receipts below keep their time boundary.

Follow-up to `8a3e9ab`'s payload removal. **Release now compiles no CEF
implementation and needs no CEF distribution, headers, static wrapper, runtime
loader or Chromium credits.** Apple-silicon Debug retains the actual historical
browser implementation solely for isolated fixtures; ordinary product routing is
still hc, with no legacy backend fallback or browser integration.

## Product changes

`BrowserEngine.mm` limits the real implementation to
`__arm64__ && defined(DEBUG) && DEBUG`. All Release slices use the existing
unavailable Objective-C ABI, not a fake working browser. Availability/running are
false; start fails with `BrowserEngineError.unavailable`. Preparation creates no
app, directory or capability. Unsupported credential-proxy methods fail closed,
including no unproven restoration acknowledgment. The Debug implementation body,
user browser profiles and installed processes are untouched.

Release removes the CEF include/static-wrapper settings and
`SHEPHERD_CEF_ROOT`; it also excludes ChromiumCredits.html. Debug settings are
unchanged. CI/release driver no longer download/prepare CEF, while fixture setup
scripts remain. The license bodies and frozen historical inventory remain intact.
Current notices distinguish retained fixture attribution from shipped code.
The hc license profile rejects reintroduced CEF build settings and retired credits;
`legacy-fixture` retains its historical distribution/license requirements.

Main executable load commands/symbols and each exact per-architecture
BrowserEngine.o are audited. **Final-binary `nm` alone is insufficient:** the old
8a3e9ab final binary already dead-stripped global CEF symbols, while its actual
Release browser object still contains CEF. The attempted old-binary negative was
not observed and is recorded as such; the real old object is rejected. This is
why source configuration, real object evidence and a CEF-absent source tree are
all used, rather than calling dead stripping build-dependency retirement.

## Forwarder archive dependency

The main app no longer has the unconditional target dependency on the capture
helper. Its two orphan proxy/dependency records are removed; the helper target
itself remains for historical Debug fixtures. The shared scheme explicitly lists
that helper for its configured **Debug run/test/analyze** actions, but not for
**Release archive/profile**. Actual archive graphs and exact Release products must
contain neither the native helper target nor AgentProxyForwarder.o. Required
AgentProxyCore/Protocol archive codecs stay linked.

An implicit-copy-only experiment built Release but failed a genuinely fresh Debug
build: the SwiftPM forwarder lacked Clang module-map propagation. A fresh Debug
build with the explicit scheme fixture root passes without changing Swift modes,
module validation or diagnostics. This failure is retained. A first `-dry-run`
probe is also explicitly failed: Xcode 27 no longer supports that option.

This is archive/profile retirement, not deletion of the fixture target. A CLI
`-configuration Release build` overrides the scheme's configured Debug run action
and can still select its explicit helper root; it is not the qualified Release
archive path. Removing the remaining fixture target/configuration and legacy SDK
from all build variants requires further separation, not a claim of full removal.

## Validation

Owned root: `/private/tmp/hc-release-code.tsvo3n_k`.

- `run-unavailable-browser-tests.py --output <fresh>` compiles the real interface
  with Clang `-Werror`, without any CEF include/library, denying reads of Vendor/CEF
  and networking. Release and DEBUG=0 each pass **10** native checks; no NSApplication,
  provider, core, credential broker or service starts.
- Fresh unsigned universal archives from a private source projection containing
  Citadel/SwiftTerm/swift-nio-ssh but **no Vendor/CEF directory** passes, with the
  exact working project copied byte-for-byte and product source linked unchanged.
  App target link/object/dSYM, architecture, payload and notice checks pass.
  After the fixture scheme adjustment, the final archive graph explicitly excludes
  both forwarder targets; the matching product audit rejects compiled forwarder
  leftovers. The final archive reuses that newly created forwarder-free DerivedData,
  not old fixture outputs.
- Separate unsigned copied-export coherence passes. Changing one private copied
  executable LC_UUID is rejected; exact restored bytes pass. This is not a signed
  Developer ID export or deployment approval.
- Fresh Debug build with the explicit fixture scheme retains **real CEF symbols**,
  runtime/credit/Node/proxy fixture payloads
  and the debug proxy signature/plist check. iOS build and original source-wiring
  checks pass. No new foreground GUI or physical-input evidence is inferred.

Two planning failures are preserved, not counted as product passes: an outer
sandbox conflicts with SwiftPM's own sandbox (`sandbox_apply: Operation not
permitted`); the first private source projection omitted the local swift-nio-ssh
package. No package/plugin sandbox or validation was disabled. The corrected
CEF-absent projection includes that required SSH source and builds naturally.

The final offline policy suite has **12** methods (with negative subcases). The
native unavailable-interface component has 10 checks per mode. These are not new
whole-UI, provider or service qualification counts.

Final evidence: `scheme-archive-validation.json`, `scheme-payload.json`,
`scheme-release-graph.txt`, `scheme-uuid-negative.json`,
`platform-scheme-fixed/validation.json`, and `project-preservation.json` in the
owned root. Final app is approximately **42.4 MiB** allocated (`du -sk`), versus
~51 MiB at the payload-only stage; neither figure is compressed download size.

Cleanup removed **29** exact owned superseded/copy/cache/executable outputs
(~**6.581 GiB** allocated), including the now-consumed older 8a3e9ab intermediates.
The current scheme archive and exact Release link/object/dSYM baseline, fresh
Debug/iOS products, source and failed/positive receipts remain for SDK retirement.
Receipt: `build/cleanup/hc-release-code-cleanup.json`. No active builder or owned
executable was stopped. Unrelated user project settings/objects are verified
unchanged; the index patch is made from HEAD, not the dirty working project.

The frozen inventory is not relabeled, source language/concurrency modes are not
relaxed, and no post-build stripping manufactures a passing bundle. Source inputs,
failed/positive logs, link/dSYM evidence and user project provenance are recorded.
The archive uses the preserved dirty project and a private version override; it is
not an exact clean-commit signed/notarized release. No installed app/core/service,
Keychain, privacy grant or user data is changed. Full legacy SDK/client/transport
retirement and service/install/handover qualification remain separate.
