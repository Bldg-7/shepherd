# Agent proxy

The agent proxy (`AgentProxy/`, SHPHRD-105) is a Swift package of its own. The
Mac app can opt in to it with Show Conversations on iPhone and iPad, off by
default and changeable only on This Mac. Its program,
`hrdrhrdrhrdr-agent-proxy`, passes the model requests of eligible agents the app
starts (Claude Code, Codex and Pi, signed in with a Claude or ChatGPT
subscription) on to api.anthropic.com, chatgpt.com, or the exact api.openai.com
Responses endpoint for a prepared Pi route. The app-side wiring is
implemented. Bounded main/compaction collection, observed child final results,
the read API and paired iPhone/iPad conversation UI are connected. With persistent capture configured it uses three process roles:

- The forwarder listens on 127.0.0.1 and passes requests on. Over its control
  socket, `ap.sock`, the app asks it for a route for each agent it starts. A
  route has a random token, and the agent is given the address
  `http://127.0.0.1:<port>/p/<token>`, so the forwarder knows which agent each
  request comes from. `proxy.restartWhenIdle` on the same socket makes the
  forwarder exit as soon as no request is in progress, so that launchd can start
  a newer build.
- The recorder is a child process that consumes the copies into bounded
  conversations and sends only validated normalized records over a private,
  bounded inherited socketpair to the storage owner. It does not persist raw tee
  bodies, headers or credentials and does not log raw errors. It decodes
  gzip, zlib-wrapped deflate and zstd copies with bounded output and an 8-MiB
  zstd window; forwarding retains the original bytes. Unknown/stacked encodings,
  trailing/concatenated frames, invalid checksums and truncated streams fail
  capture closed without changing the HTTP exchange. Pi uses request-local
  contract2 tagging qualified against1.3.0/1.4.0; legacy tags and unknown builds
  cannot become main. Child ancestry is bounded, byte-exact and scope-checked.
- The singleton storage-owner process owns the private journal, retention and
  clear operations. OFF maintenance starts the same owner role with explicit
  paths and a separate producer admission; it does not launch an agent.

The app's Pi extension adds `x-3rdr-pi-*` headers to say which Pi session a
request belongs to. The forwarder removes every `x-3rdr-*` header before it
passes a request on.

## Pi OpenAI direct subscription regression

`Tests/AgentBrowser/Phase3/PiOpenAIProxyTests.mjs` loads qualified public Pi SDK
provider/composer code through explicit `PI_AI_DIST` and `PI_CODING_DIST` paths.
Run under a network-denying sandbox. It uses fake fetch, never a live model,
agent, auth lookup or user settings. It compares real SDK payloads before and
after proxying: model URL/catalog/OAuth/thinking/cache semantics must remain
unchanged, while only eligible subscription POST `/v1/responses` fetches go to
the local `/openai/v1/responses` namespace. API keys, custom endpoints, other
paths and methods stay unchanged. Main, compaction and warming remain distinct.

The forwarder permits this new upstream only on a known Pi route, with the
adapter marker and non-API-key Bearer shape; api.openai.com validates the token
through fully verified TLS. No claim of local cryptographic token validation is
made. Only POST `/v1/responses` is supported; there is no general `/v1/*` OpenAI
proxy. Private headers are stripped and redirected fetches are not followed.
Origin and browser site/destination metadata remain forbidden. Node fetch adds
its own lone `sec-fetch-mode: cors`; this is accepted only for a known Pi direct
Responses POST with the contract and adapter marker, never as a general browser
exception. A real Node fetch traverses the native proxy to loopback TLS in the
forwarder suite, so mocked fetch tests cannot hide transport-added headers.
The native test uses a synthetic TLS certificate for the exact host and checks
path/body/header preservation and refusal before any upstream request. The core
test drives the tee through complete request/response ingestion to the existing
mobile-readable store. The protocol shape is unchanged for mobile 0.1.0(4).

## Running the tests

One runner builds the package and tests it. It needs no app, no real agent, no
launchd and no network: the tests play the agent, and servers on 127.0.0.1
stand in for api.anthropic.com, chatgpt.com and api.openai.com.

```sh
python3 Tests/AgentProxy/run-forwarder-tests.py --output /tmp/shepherd-agent-proxy-FRESH \
  --dependencies DerivedData/SourcePackages/checkouts
```

- Replace `FRESH` with a new name, so that the output folder is new. The runner
  refuses a folder that exists.
- `--dependencies` is the folder where Xcode put the Swift packages the app
  uses, so the app must have been built once. After a build with
  `-derivedDataPath DerivedData`, it is `DerivedData/SourcePackages/checkouts`.
  After `scripts/release-macos.sh`, it is `build/SourcePackages/checkouts`. The
  runner builds from there and downloads nothing.

The runner reads `AgentProxy/Package.swift`, writes a package with the same
targets under the output folder, and adds the test program to it. It then runs
forwarder, process, real read-socket and EmbeddedChannel SSH-bridge stages.
They run under `sandbox-exec` with a profile
that allows connections only to 127.0.0.1 and denies the socket of mDNSResponder
(macOS's name lookup service), so that no name can be looked up either.

### The forwarder in the test program (`ForwarderTests.swift`)

The forwarder runs inside the test program, through an initializer only tests
use. TLS servers on 127.0.0.1, with certificates from a test authority, stand in
for api.anthropic.com, chatgpt.com and api.openai.com.

- Passing on: request bodies, a zstd-compressed one among them, arrive byte for
  byte. Request headers arrive as they were sent, except that Host is replaced
  with the server's name, `Expect`, `x-3rdr-*` and the hop-by-hop headers
  (`Connection`, the headers it names, `Keep-Alive` and the like) are removed,
  and nothing is added. Response headers come back as the server sent them, less
  the hop-by-hop ones.
- Streaming: each server-sent event (SSE) reaches the agent before the server
  sends the next one.
- Closing: when the agent closes its connection, the forwarder closes its
  connection to the server within a second. When the server closes in the
  middle of a response, the response to the agent ends without chunked
  encoding's closing chunk, so the agent can tell that it was cut off.
- Refused, with no connection made to the server: a WebSocket upgrade (426); a
  Host other than `127.0.0.1:<port>`; any `Origin` or `Sec-Fetch-*` header, which
  only browsers send; a method other than GET, POST and HEAD; a path that isn't
  on the forwarder's fixed list of API paths; a Claude Code route's request for
  chatgpt.com, or a Codex route's for api.anthropic.com; and a model request
  (`/v1/messages` for Claude, `/backend-api/codex/responses` for Codex) signed in
  with an API key instead of a subscription.
- Server failures: when the server's certificate is untrusted or for another
  name, when the connection is refused, or when the server never finishes the
  TLS handshake, the agent gets 502, and the forwarder sends nothing to that
  server.
- A connection to a server is kept for the next request and closed after 30
  seconds unused.
- The recorder gets a copy of each exchange (a request and its response) on a
  known route, without the credential headers, up to 64 MiB per exchange. A
  request whose token matches no route is still passed on, but not copied,
  because the forwarder can't tell which agent sent it. The open frame includes
  only the non-secret route kind, herdr session, pane/terminal IDs and CLI
  version—not its token, token hash or base URL. Older frames decode without
  that identity; a recorder must not fabricate a mapping for them.
  Header capture uses an exact reviewed list, never an entire vendor prefix:
  signature/tunnel credential headers and raw Codex turn metadata must not reach
  the recorder. Tests also verify that these provider headers still go upstream
  unchanged and that synthetic secret values remain absent from artifacts.
  Codex's native `thread-id` is distinct from its cache-affinity `session-id`.
  A recorder that stops
  reading, or is killed, never holds a response up.

### The program itself (`process-tests.py`)

The second stage starts the built `hrdrhrdrhrdr-agent-proxy` the way launchd
would, with its state folder and control socket under the output folder, and
checks that:

- the state folder is 0700, its files and the control socket are 0600, and a
  state folder that others can open is narrowed to 0700;
- after a restart, it listens on the same port and still knows its routes, and
  if another program has taken that port, it picks a new one;
- a second copy, a state folder that is a symbolic link, a socket path that is
  too long and a relative path are refused;
- `proxy.restartWhenIdle` makes it exit and remove its socket, SIGTERM makes it
  exit at once, and a socket left behind by a crash is replaced;
- its recorder is started again when it dies.

### No secrets left

Last, the runner looks for every secret the tests sent in every file the run
left: the marker strings sent in the Authorization, x-api-key, Cookie and
ChatGPT-Account-ID headers, and the route tokens. None may be there.

## Conversation capture primitives (`run-core-tests.py`)

```sh
python3 Tests/AgentProxy/run-core-tests.py --output /tmp/shepherd-agent-core-FRESH
```

This Foundation/system-CryptoKit stage compiles the local `AgentProxyProtocol`
and `AgentProxyCore` modules and the tests in both Debug
and optimized mode, then type-checks the core for the iOS Simulator (iOS 17
minimum), without resolving SwiftPM dependencies. The tests run in a
sandbox denying all network access, with temporary HOME and cache folders.
They use synthetic bytes, not real conversations or credentials.

- SSE framing across every pair of byte-chunk boundaries (including the UTF-8
  BOM, Korean and emoji), CR/LF/CRLF, multiple data lines, empty data, comments,
  event-name reset, exact bounds, invalid UTF-8 and incomplete EOF.
- Oversized lines/events permanently stop that decoder and release buffered
  bytes. A synchronous event sink avoids retaining the whole response stream.
- Body capture accepts the exact bound; overflow or abort discards the partial
  body and cannot be mistaken for complete JSON by a later chunk.
- Text prefixes fit a byte budget without cutting a UTF-8 scalar. Grapheme
  clusters are not guaranteed to remain whole.
- Anthropic Messages and Responses request bodies project into neutral user,
  assistant and tool blocks. System/developer instructions and thinking are
  omitted; images become placeholders. Known metadata wrappers are removed
  from user input, including nested wrappers, without rewriting assistant or
  tool output. Unknown shapes are marked incomplete instead of being presented
  as a complete transcript.
- One Anthropic Messages response is assembled incrementally from SSE blocks:
  text appears before message completion; tool-argument fragments replace the
  initial empty object; hidden reasoning/signature blocks and image payloads
  are not retained. Hidden blocks count toward the entry bound too. Missing
  block starts/stops, malformed JSON, provider errors, EOF and aborted/dropped
  transport remain incomplete rather than appearing successfully finished.
- Responses SSE uses output/item/content identities for live text, refusal
  and function-argument deltas. Repeated done snapshots replace rather than
  duplicate text. A complete final output replaces the view transactionally;
  an invalid final snapshot preserves the prior live view as incomplete.
  Reasoning/encrypted content is omitted, image output is a placeholder, and
  hidden entries still count toward item/content bounds. `[DONE]` without a
  valid Responses completion event does not establish completion.
- Compaction response projection requires a verified compaction request class.
  Completed plaintext is bounded to 256 KiB, separators included; tools,
  reasoning and images cannot become summary text. Codex's `compaction`,
  `compaction_summary` and `context_compaction` items retain only typed presence,
  with their optional IDs respected and their ciphertext/unknown fields omitted.
  Opaque output yields an unavailable-summary marker, never guessed plaintext
  from adjacent output. Aborted, malformed or unfinished exchanges remain
  incomplete. The classified reconciler entry point records main ownership;
  compaction tickets then append typed boundaries and optional summary text
  without replacing old visible history. Claude requires an explicit matching
  root agent ID, or the source-verified omitted-root-ID convention of exactly
  Claude 2.1.309 on both requests. Unknown builds with absent IDs fail closed;
  no root agent ID is fabricated. Codex uses its native thread. Both require the current route/pane/terminal/herdr namespace. Active
  main requests, child compactions, retries superseded by newer requests,
  completed tickets, moved routes, eviction and recorder epochs are covered.
  Changed post-compaction context is marked reconstructed, not mistaken for a
  retry that moves the old reply behind its boundary. Identical context after
  a summary response is not duplicated: an API response does not prove the
  caller applied the summary. Child compactions never acquire a main ticket.
- Projection keeps at most the latest 200 visible messages and 4 MiB of
  accounted content; user/assistant/tool text and block counts are bounded.
  Responses continuation IDs are retained so a later store can distinguish
  incremental input from a complete history. The JSON scanner limits nesting
  and token count before materialization; metadata scan work is also bounded.

`ConversationCapture` now connects tee request/body/end and response head/SSE/end
frames to classification, reconciliation and compaction. It reserves framing and
metadata space, per-exchange parser/decoder workspace and 4x buffered request
bytes under a 128-MiB accounting budget. Pressure evicts oldest history plus its
owned in-flight streams, or rejects capture. Independent count/body/decoded-byte
caps cover empty exchanges and decompression expansion. The forwarder's monotonic
open IDs prevent late frames or duplicate opens from resurrecting discarded
captures. EOF/drop/abort finalize incomplete; no partial request JSON is parsed.
Native gzip/zlib/zstd fixtures pass through this same ingestion path in the
forwarder suite. Client4MiB and transient encoding8MiB reservations share this
same admission boundary; their tokens and connection counts are bounded too.

`ConversationReadAPI` implements the read-only, versioned query/wire layer.
The recorder exposes it on private `ac.sock`, sharing one event loop with tee
ingestion. Release, Debug and custom sockets are isolated. `conversations.list` returns bounded summaries, filtered
by terminal/herdr/native-session/agent using exact UTF-8 identity.
`conversation.read` returns the latest page, then older pages via a stable
`beforeItemID`; epoch changes, missing conversations and removed anchors produce
explicit resets instead of guessed offsets. Requests are capped at 64 KiB;
pages at 64 items and about 256 KiB of accounted content (one full bounded item
is allowed), with a 2-MiB encoded reply cap including JSON escaping. DTOs retain
compaction/discontinuity types for localized separators and no raw metadata.
Tests cover pagination, worst-case escaping, filters and bounded static errors.
The socket host reserves client/encoding/write capacity in the aggregate capture
budget. `conversation.subscribe` coalesces suffix patches at <=10Hz and resets
on incompatible history changes; a client that cannot drain a write in five
seconds is disconnected rather than retaining queued snapshots. At most16
connections and one outstanding reply each. `show --terminal ID [--socket PATH]`
reads a bounded latest page. Shared SSH/client and mobile chat/Screen UI are
wired. Pi purpose tagging and subagent result tracking are connected with the
qualification limits below.

`read-socket-tests.py` exercises the actual child recorder with synthetic fd3
frames, including lifecycle/inode ownership, framing, connection caps, slow
readers and CLI. `SSHLineBridgeTests` uses real NIOEmbedded channels, not an
authenticated SSH session. `run-client-tests.py --core <run-core-tests output>
--output <fresh directory>` checks actual client/window and observable mobile
model code with a synthetic authenticated-transport seam, Debug/-O and iOS17.
No agent, provider API or user credential is used in these checks.

The byte counts concern payloads and explicit object allowances, not a hard
allocator/process-RSS limit. `ConversationStore` bounds retained transcripts
(4 MiB per conversation, 128 MiB total), with independent conversation/item
count caps. It retains recent items, evicts the oldest-updated conversations,
reports truncation/evicted IDs, preserves native identity across route changes,
and gives a fresh store a fresh epoch. Summaries do not include full bodies;
identical upserts do not advance the sequence. Invalid input is rejected before
any existing snapshot or eviction order changes. Tests use small limits to
exercise exact thresholds, empty-object floods and atomic rejection.

The store accepts already reconciled snapshots: it does not classify requests,
deduplicate by text, or reject stale response generations on its own.
`ConversationReconciler.beginMain` accepts only already-classified main requests:
SHA-256 fingerprints detect retries without swallowing repeated user messages;
full history replaces provisional response grouping, while Responses predecessor
IDs distinguish incremental input. Ambiguous/missing history adds a typed
boundary instead of guessing. Fresh request/epoch tickets reject superseded,
finished or evicted updates. Metadata retains at most 200 message digests per
resident conversation and is pruned with store eviction; no raw request copy
is kept there. Opaque session keys compare exact bytes, not Unicode equivalence.

`RequestClassification` selects bounded Claude request-class/session/agent
metadata and Codex canonical body request_kind/native thread/parent metadata.
Non-main results cannot expose a main conversation key. Duplicate headers,
conflicting IDs, missing route identity and unrecognized values fail closed;
cache-affinity session IDs and raw turn-metadata headers are not identity
fallbacks. Classification fixtures reflect Claude 2.1.309 and Codex 0.162.1
source contracts, not live provider traffic. Pi's unconditional legacy main tag
is explicitly unverified, not silently accepted.

### Qualification boundaries

Pi contract2 is source-qualified for1.3.0/1.4.0. A WeakMap binds operation
signals to native IDs during context/compaction hooks. The standard agent-loop
callback shape and session ID further qualify main requests; cache warming's
new signal/maxTokens1 and branch-summary signals never become main. Public
provider delegates are preserved without replacing catalogs, auth or cache
settings. An authenticated app report qualifies the exact native session;
initial control failure cannot qualify one. Later app/browser disconnection does
not stop an already-bound proxy session, while replacement/shutdown clears it.
Stale local headers are removed before delegation to a custom endpoint. Known inherited-child markers are rejected before any provider override;
headless modes cannot qualify capture. An inherited bootstrap is never treated
as the child's own owner reservation.
`PiProxyLoopTests.mjs <absolute public agent-loop.js>` runs that SDK loop with a
fake stream in a no-network sandbox, not a CLI or real model.

Child metadata is bounded to128 per root,1024 globally and16 observed ancestry
levels. Explicit parent IDs establish rooted depth. Exact Claude2.1.309 root-ID
omission can establish managed-native membership from class/native ID plus the
current route/pane/terminal/herdr namespace, but **not** a guessed parent ID:
missing depth is reported as unknown, cycles/reparenting are rejected, and this
membership never authorizes a child's compaction on main. Unknown builds and
unqualified Pi children remain unavailable. Only successful transport plus
Anthropic end_turn without tools, or Codex final_answer without a tool/compaction
turn, can retain a child's final text (16KiB). Counts are observed children and
children with final answers, never proof of live processes or process exit.
Retries/tickets/owner changes/eviction cannot resurrect or duplicate results.

The mobile client shares the existing paired-Mac SSH connection; remote herdr
machines and manual SSH hosts stay on Screen. State/prompt/keys stay with herdr.
The device bounds decoded lines/queues/history, rejects stale scope/sequence,
and labels unavailable summaries/ancestry and reconstruction. Pi's already
reported `<timestamp>_<session UUID>.jsonl` filename metadata supplies a comparable
native ID when herdr reports a path; no file is opened, and this does not enable
legacy Pi resume. This prevents selecting another session merely because its
response updated the same terminal more recently. It uses the
same inert Markdown block parser as desktop preview; no HTML execution or
image fetch. Actual provider OAuth traffic, physical-device scrolling and
blocked dialogs still require manual end-to-end validation; synthetic tests
and compilation are not claims that those live checks were performed.

## The app's side (`run-app-tests.py`)

```sh
python3 Tests/AgentProxy/run-app-tests.py --output /tmp/shepherd-agent-proxy-app-FRESH \
  --app DerivedData/Build/Products/Debug/hrdrhrdrhrdr.app
```

This runner tests the macOS app's side of the proxy, using a Debug build of the
app. The app itself never runs. Neither do launchd, herdr or an agent, nothing
is registered with macOS, and no connection leaves the Mac. The runner has three
parts.

1. `App/AppServiceTests.swift` builds the app's `AgentProxyService`, which turns
   the proxy on and off and gives launches their routes, together with its
   `ap.sock` client. A stand-in takes the place of the LaunchAgent (the
   background item macOS starts the proxy from), and a stand-in proxy listens on
   a Unix socket under the output folder. `AgentProxyService+System.swift`,
   which holds SMAppService, user defaults and This Mac's herdr, is left out of
   this build. The test checks that:
   - turning the setting on registers the LaunchAgent;
   - a proxy from a different build of the app is asked once to restart when
     it is idle, and no launch gets a route until it has;
   - a proxy that doesn't answer, or whose bundled build hash cannot be read,
     gives no launch a route;
   - a launch gets a route only when all of these hold: its CLI is new enough
     (Claude Code 2.1.283, Codex 0.162, Pi 1.3.0), the Mac has no system proxy,
     the window shows This Mac, and the proxy hasn't already refused that kind of
     agent for signing in with something other than a subscription;
   - the routes of panes that have closed are removed, while the route of a
     launch still starting up, whose pane isn't there yet, is kept;
   - with the setting turned off, the LaunchAgent is unregistered only once the
     pane of the last agent using the proxy has closed. A failed control-socket
     query cannot establish that no agents remain, so registration is retained
     with an error shown until a successful query establishes that it can stop.

   This test file is in the `App/` folder because `run-forwarder-tests.py`
   compiles every `*.swift` file directly in `Tests/AgentProxy`.
2. `check-bundle.py` reads the built app's files without running anything. It
   checks that the proxy executable is in `Contents/MacOS`, is signed, is built
   for the same architectures as the app and carries no framework of its own,
   and that `Contents/Library/LaunchAgents` holds only the LaunchAgent plist of
   the build's configuration (Debug or Release), with the label, program and
   restart settings it should have. The release script also runs this check on
   the exported app, adding `--team` so that it requires the team's signature
   and the hardened runtime as well.
3. Last, the proxy executable inside the built app is run where it is, in a
   sandbox that allows only 127.0.0.1 and Unix sockets, with the checks of
   `process-tests.py`. It is run once more with its state folder and socket given
   as paths starting with `~/`, the way the Debug build's LaunchAgent passes
   them, to check that it reads them as paths in the home folder.
