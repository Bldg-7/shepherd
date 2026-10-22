# Agent proxy

The agent proxy (`AgentProxy/`, SHPHRD-105) is a Swift package of its own. The
Mac app can opt in to it with Show Conversations on iPhone and iPad, off by
default and changeable only on This Mac. Its program,
`hrdrhrdrhrdr-agent-proxy`, passes the model requests of eligible agents the app
starts (Claude Code, Codex and Pi, signed in with a Claude or ChatGPT
subscription) on to api.anthropic.com or chatgpt.com. The app-side wiring is
implemented; reconstructing conversations and showing them in the iPhone and
iPad app are not implemented yet. It runs as two processes:

- The forwarder listens on 127.0.0.1 and passes requests on. Over its control
  socket, `ap.sock`, the app asks it for a route for each agent it starts. A
  route has a random token, and the agent is given the address
  `http://127.0.0.1:<port>/p/<token>`, so the forwarder knows which agent each
  request comes from. `proxy.restartWhenIdle` on the same socket makes the
  forwarder exit as soon as no request is in progress, so that launchd can start
  a newer build.
- The recorder is a child process that the forwarder sends the copies to. For
  now it checks them and throws them away.

The app's Pi extension adds `x-3rdr-pi-*` headers to say which Pi session a
request belongs to. The forwarder removes every `x-3rdr-*` header before it
passes a request on.

## Running the tests

One runner builds the package and tests it. It needs no app, no real agent, no
launchd and no network: the tests play the agent, and servers on 127.0.0.1
stand in for api.anthropic.com and chatgpt.com.

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
two test stages, described below. Both run under `sandbox-exec` with a profile
that allows connections only to 127.0.0.1 and denies the socket of mDNSResponder
(macOS's name lookup service), so that no name can be looked up either.

### The forwarder in the test program (`ForwarderTests.swift`)

The forwarder runs inside the test program, through an initializer only tests
use. TLS servers on 127.0.0.1, with certificates from a test authority, stand in
for api.anthropic.com and chatgpt.com.

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
  because the forwarder can't tell which agent sent it. A recorder that stops
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
