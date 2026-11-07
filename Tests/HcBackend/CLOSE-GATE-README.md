# Owned native Cancel / pending selected close

Current evidence: `/private/tmp/hc-screen-app._35qrzu0`,74 actual current-root
fullscreen/native-layout checks, natural exit and no runner signals. It retains
all previous69 checks and adds:

- A real Close dialog's enabled Cancel: document/version, selected native detail,
  recovery record count and every program incarnation/state remain unchanged.
- A separate view-only close using one actual native default Return. Exactly one
  complete outgoing `doc.set` is held BEFORE transport dispatch. Old selected
  detail/input is hidden while the document is unchanged. A different real row
  is selected; releasing the original bytes once cannot clear that newer choice.
  Program count/address/PID/creation/state are preserved.

`native-default-return.json` and `native-pending-default-return.json` are separate
one-dispatch receipts. `native-pending-close.json` records the observed effects.
The original default view close/no-fallback assertion is not removed to make the
new explicit-selection case pass.

## Test boundary

`HcFixtureCloseGateTransport` is DEBUG/macOS-only and exists only in the explicit
private HcMigrationHost factory. Normal MachineStore transport selection and SDK
production implementations are unchanged. It delegates reads opaquely; it neither
feeds rendering nor consumes CREDIT. Writes pass through byte-for-byte. An armed
gate inspects only a copy of one bounded complete frame, recognizes channel0's
doc.set, and holds one continuation. There is no changed JSON ID/version, VT
filter, rebasing, auto-release or uncertain-operation replay. Re-arming/releasing
a used gate fails; cancellation/close resumes the held operation with failure and
retires its base. Concurrent write admission fails closed rather than reordering.

The product SDK's imported CoreByteTransport is MainActor-isolated. A direct
actor conformance passed a source-composed component but failed the real app
build at `hc-close-native-gates.EFmphU/integrated/macos-debug.log`. This failure is
retained; later stages in that run are NOTRUN. The fixture now follows the real
CoreProcessTransport pattern: a nonisolated Sendable facade and an internal actor.
No SDK isolation/concurrency diagnostics were relaxed. The strengthened component
imports the actual product SDK/module maps/objects, recording hashes before/after.

```sh
python3 -B Tests/HcBackend/run-close-gate-tests.py \
  --products build/DerivedData/Build/Products/Debug --output /private/tmp/<new-root>
```

`hc-close-product-sdk.6Wli99` passes13 invariants with Swift6 strict feature flags,
warnings-as-errors, private HOME and runtime network denial. It is not an actual
core/GUI pass. `hc-close-composed-gates.vggp5Z` separately passes macOS Debug/Release,
iOS Debug, actual product6/80 renderer, selected renderer/parser69, original UI
suite and wiring24. Native74 above is a separate actual-core/UI gate.

## Not qualified

This delay is a controlled pre-dispatch point, not a network-loss/partial-write
or OS failure test, physical pointer timing, or a stop replay experiment.
Fullscreen uses the explicit native-toggle mode: no pointer warp/edge-hover or
physical drag/IME qualification. wholeUIParityQualified/releaseCutover remain
false. User apps/services/credentials and default backend are not replaced.
