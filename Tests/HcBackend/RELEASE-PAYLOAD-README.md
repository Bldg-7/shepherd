# hc Release payload retirement

The default product remains hc. This batch removes deferred **payloads** from
Release, not every legacy implementation/dependency. No app/core/service is
installed, launched, stopped or unregistered by these packaging checks.

## Policy

Release excludes AgentRuntime (and Node packages), Chromium Embedded Framework,
all 3rdr browser helpers, the capture proxy executable and both capture LaunchAgent
plists. Debug keeps its explicit isolated fixture payloads. The app still links
archive codecs/protocol, SSH/crypto, the legacy SDK code and the browser bridge/static
CEF wrapper; those code/build dependencies are **not claimed retired**.

Only four settings in the main app's Release configuration change: excluded file
names, CEF header path, CEF static-wrapper path and `SHEPHERD_CEF_ROOT`. Debug and all
other project settings/objects remain unchanged. The pre-existing dirty project is
preserved; the owned index patch is generated against HEAD, never by staging that
whole working file. See `project-preservation.json` in the evidence root.

Xcode tokenizes exclusion names containing spaces. Patterns use
`Chromium*Embedded*Framework.framework` and `3rdr*Helper*.app`, not space-containing
entries which leave the Copy Files payloads behind. A strict artifact audit rejects
stale/nested payloads and escaping links; no post-build stripping repairs a result.

The Release driver uses a fresh `WORK/DerivedData`, no npm runtime install or CEF
framework/helper signing. CEF headers/static wrapper and retained Chromium credits
remain build/attribution inputs. CI verifies local vendored SwiftTerm without a
global plugin-trust override; plugin validation, exact-source, Developer ID,
notarization, Gatekeeper, Sparkle signing and manual publishing gates remain.
Neither the release script nor CI/signing/authentication was executed in this batch.

## License/build identity gate

`Tests/Notices/run-notices-tests.py --profile hc` is the default current profile.
The frozen inventory is not edited or relabeled: only the reviewed remote-pin delta
for vendored SwiftTerm and its CLI-only argument-parser is allowed. Vendor hashes,
unchanged MIT license and modified renderer attribution are verified. Linked app
objects include `AgentProxyCore`/`AgentProxyProtocol` for archive reading, rather
than evidence from an unshipped forwarder helper.

The real app target link list, per-slice Mach-O objects, exact app dSYM, archive
Info.plist and archive/export LC_UUID identities remain mandatory. Retained CEF
bridge object/credits are covered. `legacy-fixture` keeps the old frozen helper/Node
contract; it is not evidence for hc and can reject the newer active dependency graph.
Source notices preserve license bodies and distinguish retained fixture attribution
from payloads actually shipped.

## Evidence

Owned root: `/private/tmp/hc-release-prune.ve7EE4`.

- First fresh unsigned archive built, but payload audit **failed**: space-containing
  exclusions did not remove CEF Copy Files inputs. Runtime/proxy artifacts were
  absent, CEF helpers/framework remained. No later notice gate is inferred green.
- Second fresh `Shepherd-fixed.xcarchive` builds with CODE_SIGNING_ALLOWED=NO,
  a private headers/static-wrapper-only CEF build path and no post-build stripping.
  Real payload and exact archive/link/dSYM notice gates pass for arm64 and x86_64.
- An unsigned **copy** of that archive app passes the same separate-path coherence
  check. Deliberately changing one copied executable LC_UUID is rejected; restoring
  exact bytes passes. This is not an actual Developer ID export.
- Eight offline policy tests (with per-payload subcases), notice content tests and
  hc notice self-test negative guards pass. Missing objects, wrong product roots,
  stale resources and forbidden payloads are not synthetic success paths.
- Debug/iOS follow-up builds pass. The actual Debug proxy Mach-O/signature/plist
  checker passes; Debug runtime, CEF and debug LaunchAgent remain. No helper runs.

Previous local Release app: ~409 MiB allocated. Fresh retired-payload app: ~51 MiB
allocated (`du -sk`), not compressed download size or a process-memory measurement.
The build consumed the preserved dirty working project with explicit private test
version overrides; it is **not** exact clean-commit/signing/notarization/installation
or full release qualification. Normal product-root/control behavior was unchanged;
no new foreground GUI, physical-input, real-device or service-lifetime claim is made.

Cleanup: `build/cleanup/hc-release-prune-cleanup.json` records **8** exact owned
negative/copy/cache removals (~**2.936 GiB** allocated) after all builders exited.
The fixed archive and matching exact link/object/dSYM inputs are retained as the
baseline needed for the next code/build-dependency retirement gate. Source, failed
and positive receipts, before/index project snapshots and user programs are preserved.

## Update/service boundary

An installed old capture LaunchAgent can reference the installed app's helper path.
Do not deploy this helper-free candidate over an active capture installation without
an approved disposable-host handover plan and evidence. No route snapshot is a
service-retirement lease. Existing archives/routes/settings/programs/services were
not removed or stopped; no legacy backend fallback is added to preserve capture.
