# hc framed protocol and RPC foundation (SHPHRD-149 / SHPHRD-150)

```sh
python3 Tests/CoreProtocol/run-tests.py --output /tmp/shepherd-hc-wire-FRESH
```

The output directory must not exist. The runner uses a private HOME, temp and
module cache; it does not launch `hc`, herdr, the app, an agent, SSH or a browser.
It neither installs packages nor reads account credentials. Xcode is required.
Each subprocess has a deadline using the existing owned-stage runner.

## Production code

`ShepherdKit/Sources/ShepherdKit/CoreKit/` is independent of the legacy backend:

- `CoreWire.swift`: generation-1 constants, immutable frames, bounded incremental
  encoder/decoder. Little endian 9-byte headers; 16 MiB payload limit enforced
  before copying a body; fixed-size controls and focus values checked. Unknown
  frame kinds fail closed. A consumer exception poisons the parser as well.
- `CoreHandshake.swift`: JSON-RPC hello request, reply ID/version/envelope shape,
  core identity, framed mode, API generation and required method checks. Keeps
  bytes after the hello newline, even when they contain several binary frames.
  A 64 KiB hello limit prevents an unterminated stdout banner growing forever.
  Server error messages and terminal contents are not included in codec errors.
- `CoreEventLines.swift`: bounded newline framing inside event DATA streams;
  line and UTF-8 boundaries need not align with wire frames. It preserves bytes
  and leaves JSON/event validation to the future event reducer.

- `CoreRPC.swift` (SHPHRD-150, first slice): exact UInt64 JSON-RPC IDs and typed
  result decoding, request/response correlation, caller-supplied deadlines,
  cancellation tombstones and connection epochs. Bounds both outstanding slots
  and admitted payload bytes. Late replies retain their original method so a
  future connection owner can clean up a late attach without guessing ownership.

No runtime code calls these types yet. The existing app backend is unchanged.

## Coverage

- Python `struct.pack('<IBI', ...)` independently generates vectors for all six
  frame kinds; Swift encoder output is unpacked and checked again in Python.
- Binary payloads (including invalid UTF-8), large channel IDs, every split of a
  representative frame, byte-at-a-time input, coalesced and empty frames.
- Seeded fragmentation of 200 multiplexed frames, with nonzero Data indices.
- Exact 16 MiB body, oversized header rejection, aggregate input larger than a
  frame limit delivered incrementally rather than accumulated in a result array.
- Bad kind/channel/control length/focus value, EOF at every incomplete position,
  parser retirement after error/EOF, and consumer errors.
- Event lines split inside Korean/emoji UTF-8, CRLF, empty lines, exact/overflow
  byte budgets, aggregate batches and incomplete EOF.
- Every split across hello and two frames; hello must be delivered first, once.
- Wrong RPC ID/type/version, malformed JSON/UTF-8/banner, error envelope, both
  result and error, missing methods, unsupported generation, framing refusal,
  custom request IDs, optional unknown features and exact/oversized hello.

The runner compiles the real sources in Swift 6 with the package's
upcoming-feature flags and default MainActor isolation. It rejects first-party
package or Xcode target settings that drift to another language mode.
It also typechecks the production sources against the iOS Simulator SDK for
an iOS 17 deployment target. `validation.json`, source hashes and stage logs are
retained in the output directory. This is not a full package/app build.

## RPC coverage (SHPHRD-150)

`CoreRPCTests.swift` checks out-of-order replies, null results, remote failures,
unknown/duplicate IDs, stale connection epochs, deadlines before the timer fires,
cancellation and exactly-once close drainage. Canceled/expired requests retain
bounded tombstones until a late reply or connection close; a cancellation flood
cannot grow an unbounded retired-ID list. Python independently unpacks the Swift
request and verifies UInt64.max survives in both its request ID and params.

This is only the routing state, NOT a working connection. The connection owner
must supply actual timers, settle its waiters, close orphan attach channels,
apply a separate outbound writer budget and arrange process/SSH I/O. Neither
cancellation nor timeout implies that a remote command was rolled back. No
mutating command is automatically retried here.

## Protocol baseline and remaining work

Reference: herdr-core `5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2`,
`schema/README.md` and `crates/herdr-core/src/wire.rs`. The implementation is
written against the documented protocol, not copied from the Rust client.
The HEAD-only observer resize option is not assumed to exist in 0.1.16.

This layer deliberately does NOT claim transport or product compatibility:

- **SHPHRD-150**: actual local pipes/SSH exec, deadlines, RPC and stream routing,
  cancellation/late replies, bounded channel admission, consumption-based CREDIT,
  attach lifetime, reconnection epochs and SwiftTerm interoperability.
- CREDIT must be sent after consumer processing, not at decoder receipt or
  AsyncStream enqueue time. This codec emits no automatic CREDIT.
- A complete frame callback is not proof of initial-screen completion, and a
  valid hello is not proof of authentication to a browser or a particular agent.
- Every connection owns new decoder instances; never reuse old stream IDs or
  decoder state after reconnecting.
- The endpoint must keep stderr separate. No scanning past stdout banners or
  malformed bytes to guess a new frame boundary.
- Each event stream owns its own `CoreEventLines`; sharing one across channels
  would splice unrelated JSON. Slow-consumer policy belongs to its owner.

See `docs/hc-connect-migration-review.md` for the full migration and safety gates.
