# Agent proxy

The agent proxy (`AgentProxy/`, SHPHRD-105) is a Swift package of its own, and
the app doesn't use it yet. Its program, `hrdrhrdrhrdr-agent-proxy`, is meant to
pass the model requests of the agents the app starts (Claude Code, Codex and Pi,
signed in with a Claude or ChatGPT subscription) on to api.anthropic.com or
chatgpt.com, and keep a copy of each request and response for the iPhone and
iPad app. It runs as two processes:

- The forwarder listens on 127.0.0.1 and passes requests on. Over its control
  socket, `ap.sock`, the app asks it for a route for each agent it starts. A
  route has a random token, and the agent is given the address
  `http://127.0.0.1:<port>/p/<token>`, so the forwarder knows which agent each
  request comes from. `proxy.restartWhenIdle` on the same socket makes the
  forwarder exit as soon as no request is in progress, so that launchd can start
  a newer build.
- The recorder is a child process that the forwarder sends the copies to. For
  now it checks them and throws them away.

The app's Pi extension will add `x-3rdr-pi-*` headers to say which Pi session a
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
