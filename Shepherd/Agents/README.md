# Agent runtime boundary (phase 3)

This component consumes `CDPProxy.endpoint(for:)` and the accepted
`BrowserKey`/terminal identity. It never uses a CEF debugging socket. Remote
capability is intentionally unavailable.

## Current policy: automatic, hrdrhrdrhrdr-session-only

Browser ON (including persisted-ON startup) schedules one shared app-private
resource preparation when This Mac becomes available. Settings shows waiting,
preparing, resources-ready, or failed with explicit retry, not global Set Up or
injection-mode controls. OFF retains cached files, blocks new app launch/setup,
and drains preparation through the existing safe-disable lifecycle. Already
running agents are never silently restarted and already-read text is not erased.

Claude receives a per-invocation `--plugin-dir` with the bundled skill. Codex
receives descriptor-specific MCP config and the bundled guidance appended to its
existing developer instructions. **This is not native Codex skill registration.**
The pinned Codex 0.160.1 CLI/schema has no equivalent per-launch plugin-directory
option; marketplace install support must not be reported as that capability.

Agents see the browser integration under these names: the MCP server `3rdr-browser`, the
skill `3rdr-browser` and, in Claude, the plugin `3rdr`. Its tools are
`mcp__plugin_3rdr_3rdr-browser__*` in Claude and `mcp__3rdr_browser__*` in Codex and Pi,
which turn the hyphen into an underscore. Versions up to 0.5.2 used `shepherd-browser`
and `shepherd`. Three checks accept both the new and the old names (`SERVERS` and
`PLUGINS` in `runtime-core.mjs`):

- the check for duplicate registrations and for registrations in the user's global CLI
  settings
- the child hook's check for launch arguments it has already added
- `isInjected`

This keeps two cases working. A session launched before the rename keeps its own version
folder and the old names, and is still recognised. A global registration left from an
old version is still found and reported. The pi-mcp-adapter protocol namespace stays
`shepherd`: the adapter requires a namespace that starts with a letter, and `3rdr` starts
with a digit.

No operation writes user CLI settings, user skill folders, or the Codex plugin
cache. Existing global hrdrhrdrhrdr skills/MCP/enabled plugins cause explicit
rejection, not automatic deletion or migration. Old `setupCodex`/`setMode` RPCs
return `session-only-policy`; the MCP `--global` entry point is disabled.

## Pi local managed TUI launch

Pi 1.x (`^1.0.0`) is available in the macOS launcher when the experimental browser is ON.
It requires Node >=22.19.0; the existing Claude/Codex Node 20 floor is unchanged.
`pi-runtime.mjs` probes the package-declared executable without running Pi or
loading personal settings/auth. Metadata availability never proves login or a
browser connection. Legacy argv/session parsers remain disabled for Pi even
though its dedicated launch path is enabled.

`stagePi` prepares a session-local executable shim, extension, skill and appended
guidance. `pi-launch.mjs` waits for an authenticated foreground binding before
importing the real CLI, closing the startup race with Pi's argv/title rewrite.
`AgentLaunchService.launchPi` types the shim by its absolute path into the pane
(`pane.send_input`, as `herdr pane run` does) rather than through `agent.start`,
whose bare `pi` the shell resolves through the PATH its startup files leave.
The New Tab launcher closes as soon as the shim is typed (`launch(started:)`).
The launch then waits for herdr to see Pi idle in the pane, and for Pi's MCP.
That wait, and any failure after it, show only in the sidebar.
`PiLaunchCoordinator` observes the exact Herdr pane/terminal on a separate
connection while that typed launch is pending. `PiBrowserLeaseProvider` composes the
real CDP proxy: per-epoch route leases deny unleased fallback and old-route replay,
recheck live process authority before dispatch, and wait for native detach.

The built-in MCP backend and adapter 5.1.0 are both qualified with actual Pi 1.1.0,
Herdr and CEF through the public launch service; Pi 1.2.0 so far only through
the native bridge (`docs/pi-agent-support.md`). Private normal Pi settings,
user instructions and extensions survive; model responses come only from an
owned loopback fake provider. No vendor accounts or personal profiles are used.
Session-only Herdr state reports travel through the authenticated app bridge,
not an inherited socket/pane environment. Adapter conflicts do not fall back to
the built-in backend. Its runtime server is session-owned, with acknowledged
unregistration; no global MCP/skill installation or npm/download is performed.

Resume, child/headless launch and competing-browser dispatch suppression remain
unqualified. Because that suppression is unqualified, "Block other browser
tools" (Settings, Experimental Features, Advanced) is not applied to Pi and does
not refuse a Pi launch: Pi gets no blocking arguments and keeps all of its MCP
servers, and the setting's help says so. A different session ID/file is retired
and denied, not silently rebound; use a fresh managed launch. See
`docs/pi-agent-support.md` for scope, security contracts, evidence and these
explicit limitations.

## Pane names for agent sessions

When a pane is renamed in this app and herdr accepts the rename
(`pane.rename`, in `AgentBoardView.rename`), the new name is passed on once to
the session of the agent in that pane (`AgentSessionNaming.swift`). The name is
trimmed, control characters and line breaks (U+2028 and U+2029 included) become
spaces, and it is cut to 200 characters. An empty name, a tab rename, or a pane
with no Claude Code, Codex or Pi agent passes nothing on. Renames made in herdr
or another herdr client are not seen, nothing is read back from the agent, and
no session file is written.

### Claude Code and Codex

`AgentSessionNamer` holds at most one name per pane, in memory only. A pane is
identified by its Machine (This Mac or an SSH machine from Settings), its herdr
machine if any, and its herdr pane ID. A newer rename replaces the held name.
With the name, the namer records what was in the pane at rename time: pane ID,
herdr terminal ID, agent kind, the agent session ID that herdr reports for it,
Machine and herdr machine.

On every snapshot of that herdr (`showSnapshot`, `showHerdrMachines`) the namer
compares the pane with that record:

- The pane is gone, its herdr machine was removed, or its terminal, agent kind
  or agent session ID differs: the name is dropped.
- herdr reported an agent session ID at rename time but reports none now: the
  name is held, not dropped.
- The agent is idle or done and not `launch_pending`: the name is sent, at most
  once every 3 seconds per pane. `interactive_ready` is not required, because
  herdr sets it only for agents started with `agent.start`, not for agents
  started from a shell.

Sending opens a connection of its own and goes through three steps:

1. Read the visible screen (`pane.read`, visible, with ANSI; for a herdr machine
   `herdr --machine <id> pane read … --format ansi`). Go on only if the agent's
   input box is empty.
2. Read the agent again with `agent.get`. Go on only if it is the same agent
   session and still idle or done.
3. Submit `/rename <name>` with `agent.prompt`, which pastes it in bracketed
   paste mode and then presses Enter.

The input box check is `AgentIdleStopPolicy.isEmptyEditor`, the check the app
also uses before stopping an idle agent to resume its session. For naming only,
a Claude Code prompt line that shows nothing but Claude's own placeholder
suggestion (its first character drawn inverted as the cursor and the rest dim,
or all of it dim) also counts as empty. The resume check still treats such a
suggestion as typed text.

After a send that doesn't go through:

- The name is kept for a later snapshot after: a draft in the input box, a
  question or review prompt on screen, `agent_blocked`, a timeout, or a failed
  connection.
- The name is dropped after: `agent_not_found`, `pane_not_found`, or a different
  agent session.

If a newer rename replaces a name while that name is being sent, the newer name
is checked as soon as that send ends.

### Pi

Only a Pi launched by this app on This Mac is named
(`AgentLaunchService.namePiSession`). `PiHostBridge.nameSession` gives each name
for a launch a sequence number. Every `status` reply the bridge sends to that
launch carries `sessionName: {sequence, name}`; replies to other launches don't.
In Pi, `pi-host.mjs` polls `status` while the launch's bridge connection is up
and hands the name to `pi-session-name.mjs`. That calls `pi.setSessionName()`
once per sequence number: right away if Pi is idle with no message waiting to
be sent, otherwise at Pi's next `agent_settled` event. When Pi starts a new
session, a name not yet set is dropped. Nothing is typed into Pi. A Pi started
from a shell is not renamed, and the name reaches Pi only while its launch's
bridge connection is up.

## Packaging requirement — integration owner

The source resource folder is **`Shepherd/Agents/AgentRuntime`**. Before packaging,
run `npm ci --prefix Shepherd/Agents/AgentRuntime --ignore-scripts --no-audit
--no-fund` (finite build deadline). The checked-in lock pins Playwright MCP
**0.0.83**, Playwright's exact transitive version and TOML parser 2.2.5. No
browser download, npx, network or npm is used at runtime. **Node >=20** (required
by pinned playwright/playwright-core engines) must already be available on the local agent host. The resource folder is about 18 MiB;
`node_modules` is ignored and must be copied, not linked to another worktree.

GUI launches need not inherit a terminal's PATH. `AgentHostExecutables` checks
absolute inherited PATH entries and conventional local/Homebrew/Volta/fnm default
locations (plus explicit version-manager environment paths). It resolves Node to
its stable installed path and supplies an expanded PATH only to the runtime
subprocess and its CLI children, including `~/.local/bin` for Claude. It never
sources shell rc files, scans arbitrary installed versions, installs Node, or
changes global/app environment. Unsupported custom locations fail explicitly.

Mechanical project requirements (integration owns the pbx edit):

1. Set `explicitFolders = ("Agents/AgentRuntime");` on the synchronized root,
   then exclude `Agents/AgentRuntime` from automatic target membership with a
   `PBXFileSystemSynchronizedBuildFileExceptionSet` (`membershipExceptions`, target
   `000000000000000100000000`) referenced from Shepherd's synchronized root group
   `000000000000000000000010`. Treat it as an explicit folder, not individual files.
2. Add a folder `PBXFileReference` (`lastKnownFileType = folder`,
   `path = Shepherd/Agents/AgentRuntime`, `sourceTree = SOURCE_ROOT`) and a resource
   `PBXBuildFile` with **`platformFilters = (macos, );`** (same spelling as existing
   CEF/Sparkle filters). Add that build file to Resources phase
   `000000000000000140000000`. This copies the folder intact only on macOS; do not
   put Node/MCP/plugin assets in iOS/visionOS bundles.
3. Verify the folder exists intact in a built macOS app and is absent in iOS.
   Generate new object IDs through the integration owner's normal tooling.

The resulting bundle path must be `Contents/Resources/AgentRuntime/runtime.mjs`
and contain `node_modules`, `runtime-core.mjs`, `mcp-run.mjs`,
`playwright-mcp-snapshot.json`, `hook.mjs`, the lock/manifest, and `skill/SKILL.md`. Do not auto-add every node_modules file as an
individual build resource. No pbx file was edited by this component. The existing
Swift filesystem group discovers `AgentRuntime.swift` and
`AgentBrowserAdapter.swift`; the latter is excluded on iOS by `#if os(macOS)`.
Full app/resource packaging builds remain integration gates, not backend passes.

## Exact exported Swift contract

All types are internal, `nonisolated`, Foundation-compatible and `Sendable`.
`AgentRuntime` accepts a `@Sendable (String) async throws -> Data` script runner;
its macOS convenience initializer accepts the existing `HerdrClient`.

- `AgentKind: String, Codable, CaseIterable`: `.claude`, `.codex`, `.pi` (gated).
- `AgentHost`: `.thisMac`, `.remote` (the latter always throws).
- `AgentInjectionMode`: `.plugin` only for new operations. `.global` remains
  decodable solely to report legacy state without silently changing it.
- `AgentRuntimePreferences`: mode, disableCompetingBrowsers (default false),
  competingBrowserServers, allowedOrigins, blockedOrigins, outputMaxSize (default
  64 MiB, permitted 1 MiB–1 GiB). MCP origin filtering is not a security boundary.
- `AgentPaneIdentity(key: BrowserKey, terminalID: String)` retains all qualified
  key fields plus terminal ID. Cleanup/output identity is terminal-based, so pane
  aliases/moves retain the same output folder.
- `AgentBrowserEndpoint(_ endpoint: BrowserEndpoint)` contains only public origin,
  URL and opaque token-file path. Node revalidates local loopback/v1/pane binding,
  no URL credentials/query/fragment, token file owner/mode and no symlink final
  component before startup. Token bytes are never returned.
- `AgentRuntime(root: String, resourceDirectory: String,
  nodeExecutable: String = "node", scriptRunner: ...)`.
- `AgentRuntime(root: String, resourceDirectory: String,
  nodeExecutable: String = "node", client: HerdrClient)` (macOS).
- `install(on: AgentHost) async throws -> AgentRuntimeInstallation`.
- `installation(on: AgentHost) async throws -> AgentRuntimeInstallation?`:
  version/resourceDirectory/mode/codexPluginKey/codexPluginReady/
  globalRegistrationVersion and computed requiresGlobalUpdate remain readable
  for legacy diagnostics. Install rejects legacy-global state. New installations
  set mode=plugin, codexPluginKey=null and codexPluginReady=false; new launches
  use the new immutable resource version without changing running sessions.
  `installation(on:)` reads `<root>/installation.json` in Swift and starts no
  Node process. It applies the same folder checks and error codes as runtime.mjs `status`
  (`invalid-runtime-root`, `unsafe-directory`, `runtime-failed`), but returns
  nil for a missing runtime folder instead of creating it. Every action that
  runs Node still checks Node's version.
- `availability(of: AgentKind, executable: String, on: AgentHost) async throws ->
  AgentCLIAvailability`: nodeVersion/nodeSupported/executable/version/readiness/
  sessionPlugin/sessionConfiguration/hookRewrite. `unsupportedPrerequisite` means
  Node is below the selected agent's floor (20 for Claude/Codex, 22.19 for Pi);
  no agent probe is then started. Pi uses a metadata-only probe. Install/prepare/mode/setup/
  reservation actions and the MCP wrapper reject `node-version-unsupported`
  before filesystem/launch/token side effects. Authentication is explicitly unknown until
  the CLI/herdr launch result; no account probe is performed.
- `checkScope(claudeSettingsFile:claudeSkillDirectory:codexHome:on:)` checks for
  conflicting global registrations without modifying them. App preparation and
  every new Node prepare enforce this boundary.
- `setUpCodex(...)` and `setMode(...)` are compatibility rejection paths only.
  They do not execute a vendor CLI or write configuration/cache/skill links.
- `reserveLaunch(on: AgentHost) async throws -> AgentLaunchReservation`.
- `discardReservation(_: AgentLaunchReservation, on: AgentHost) async throws`:
  only unbound reservations may be discarded.
- `prepare(kind: AgentKind, executable: String, pane: AgentPaneIdentity,
  endpoint: AgentBrowserEndpoint, preferences: AgentRuntimePreferences = .init(),
  arguments: [String] = [], codexHome: String, claudeSettingsFile: String,
  profile: String? = nil, reservation: AgentLaunchReservation? = nil,
  on: AgentHost) async throws -> PreparedAgentLaunch`: nil reservation means an
  argv-only existing-pane launch. Codex then always returns descriptor-specific
  MCP/configuration injection even if old plugin metadata exists; stale inherited
  SHEPHERD_AGENT_SESSION is irrelevant. Bound reservations retain their qualified
  environment, but Codex still uses descriptor-specific config. Unreserved plans
  return environment={}.
  Claude registration options are inspected before adding ours: every separate
  variadic --mcp-config value, every repeated/equals option, and all collection
  plugin directories. Actual Claude2.1.288 --mcp-config=value consumes only its
  attached value; following positional input is not a configuration value.
  Missing/malformed/relative/archived/ambiguous inputs are rejected with
  uninspectable-claude-registration; plugin/config command strings are never run.
- `registerPane(_: AgentPaneIdentity, endpoint: AgentBrowserEndpoint,
  preferences: AgentRuntimePreferences = .init(), executables: [String:String] =
  [:], codexHome: String, claudeSettingsFile: String, on: AgentHost) async throws`:
  register accepted local snapshot descriptors and fresh host/config context for
  lazy child-hook preparation from the child's current argv. A launch registry
  record alone is insufficient: the command remains unchanged with reason
  fresh-child-context-unavailable, rather than inheriting stale parent/profile
  developer instructions.
- `cleanup(pane: AgentPaneIdentity, on: AgentHost) async throws`: only after
  *proven disappearance* and agent/MCP termination, never a failed snapshot or
  disconnect. Refuses live wrapper PIDs, deletes only the qualified pane output,
  sessions and bound reservations; removes its endpoint/launch registry entries.
- `PreparedAgentLaunch`: immutable kind/executable/arguments/environment/
  outputFolder/sessionFolder/pluginDirectory/mcpConfiguration/mcpArguments/
  codexPluginKey/injection (`plugin`, `global`, `codexConfigurationFallback`).
- `PreparedAgentLaunch.isInjected(processArguments: [String]) -> Bool` uses
  reported process argv, not shell text. Global injection cannot be proved from
  argv and returns false; actual socket status remains phase2's authority.
- `AgentBrowserStatus.inspect(…, connectedPID:, …)`: the MCP wrapper closes the
  browser socket after ten minutes without a tool call (`timeouts.idle`) and
  opens it again on the next call. The Claude Code or Codex process last seen
  with the socket open stays connected, the green globe, for as long as the same
  process (PID, one foreground process of its kind) runs, in either injection
  mode. A different process in the pane does not inherit it. A Pi launch seen
  with the socket open stays connected for that launch (`PiLaunchCoordinator.hasConnected`).
- `PreparedAgentLaunch.resuming(sessionID: String) throws -> PreparedAgentLaunch`
  preserves config/profile/plugin args and appends Claude `--resume ID` or Codex
  `resume ID`. Conflicting resume flags or non-simple session IDs are rejected.
  The UI alone enforces explicit user action while idle; no automatic restart.

`AgentRuntimeError` cases: `remoteUnavailable`, `missingBundledResources`, `nodeUnavailable`,
`rejected(String)` with non-secret reason codes. Transport failures propagate;
missing/empty/invalid result envelopes never mean success. Handled backend RPC
rejections complete transport normally with `{ok:false,error:<reason>}` because
runScript otherwise discards stdout on nonzero exit; Swift always throws the typed
rejection. Normal process completion alone is never operation success. Crashes or
missing executables still produce transport errors without a valid result. Important codes:
`setup-busy`, `runtime-lock-failed`, `session-only-policy`, `legacy-global-registration-present`,
`legacy-global-skill-present`, `node-version-unsupported`,
`uninspectable-claude-registration`, `offline-dependencies-missing`, `cli-missing`, `cli-unsupported`,
`duplicate-registration`, `globally-enabled-shepherd-plugin`,
`remote-unavailable`, `pane-endpoint-mismatch`, `unsafe-token-reference`,
`mcp-still-running`, `invalid-profile`, `missing-profile`,
`invalid-instructions`, `configuration-path-required`, `invalid-runtime-root`,
`unsafe-configuration-file`, `missing-option-value`, `unknown-competing-server`,
`reservation-already-prepared`. The runtime root/generated session folders must be owned by the invoking user,
non-symlink directories with mode 0700. Existing user configuration directories
are inspected only; their bytes, permissions and linkage are preserved.
App-owned generated descriptor/configuration files are mode 0600. Runtime and config
paths must be absolute. Codex's -p/--profile separate and combined forms and TOML
literal/raw -c developer_instructions overrides are merged, preserving unrelated
argv/config/profile values. Typed profile selection is forwarded as --profile
when it is not already in argv.

`AgentSkillSetup.bundledResourceDirectory(in:)` verifies the bundle folder.
`AgentSkillSetup.runtime(root:resources:nodeExecutable:using:)` constructs the
runner. The old no-host `setUp(using:)` / `isInstalled(using:)` calls intentionally
throw `explicit-host-context-required`, rather than guess local identity or retain
public-main/global installation. The Settings UI now uses automatic app-private
preparation; compatibility declarations never restore the old global behavior.

## Required UI/API call order

1. Confirm This Mac, establish local client, locate Node/agent CLIs, choose a
   private runtime root (for example Application Support/AgentRuntime), install
   bundled resources automatically and check that no global hrdrhrdrhrdr registration
   conflicts. Do not install a Codex marketplace/plugin into its user home.
2. **Before creating the pane**, call reserveLaunch and pass its environment to
   `tab.create` / `workspace.create`. herdr `agent.start` accepts argv, not env.
3. After the returned pane appears in an accepted local snapshot, obtain its
   actual `BrowserKey` and terminal ID and `CDPProxy.endpoint(for:)`. No descriptor
   means no browser launch; do not invent a port, token or remote route.
4. Call prepare with the reservation and actual endpoint. Environment is unchanged
   from step 2. Start through typed herdr agent.start with its `arguments`.
   Over herdr's socket API, `agent.start` answers as soon as the command is
   typed, before Claude Code or Codex is ready. So the launch then waits until
   herdr marks the agent `interactive_ready` and no longer `launch_pending`
   (`AgentLaunchReadiness`, up to 30 seconds). Right after the start, the launch
   calls `started` (`launch(started:)`), and the New Tab launcher closes. This is
   the hand-off. From then on, a working agent also counts as ready, since the
   user may already have sent it a prompt. The wait, and any failure after the
   hand-off, show only in the sidebar.
5. Register accepted local snapshot endpoints so Claude child hooks can lazily
   prepare exactly the requested child. No registered/ambiguous pane means the
   original command is retained and reason-recorded; never use a parent URL.
   For each pane, hrdrhrdrhrdr keeps the runtime preferences
   (`AgentRuntimePreferences`) it was registered with. A new pane is registered
   at the next check. A pane already registered is registered again only when
   the current preferences differ from those. That happens at the first check
   after the preferences have not been saved for a second, because the "Browser
   MCP servers to block" field saves them at every key. Saving unchanged
   preferences registers nothing. Changing the browser port or installing the
   agent runtime registers every pane again at the next check, without the
   one-second wait.
   If registering a pane fails, or preparing the agent found in a pane's argv
   fails, hrdrhrdrhrdr waits before trying that pane again: 30 seconds after the
   first failure, then 60, 120 and 240 seconds, then 5 minutes between later
   tries. A preparation wait belongs to the pane's current argv. Diagnostics
   keeps showing the last error during the wait. hrdrhrdrhrdr tries again at once
   when the argv changes or the failure was `setup-busy`. These all cancel
   every wait: Retry Preparation, Check Prerequisites Again, saving settings,
   changing the port, and installing. As before this change, duplicate-
   registration and uninspectable panes are not retried. On each two-second
   check of accepted snapshots, an agent pane whose snapshot entry and
   agent.list row match the previous check reuses its process info for up to
   30 seconds; a pane without an agent has its process info read every time.
6. On proven disappearance, terminate/await owned agents/MCP, then cleanup with
   terminal identity. On failed launch discard an unbound reservation, or cleanup
   a prepared one only after termination. App startup can reconcile existing
   registries with proven live pane identities through the same cleanup method.

For an existing pane or explicit idle resume, omit reservation: Claude's
plugin/descriptor is already in argv; Codex always uses the exact descriptor-
specific session configuration. It neither selects an env-dependent plugin nor
trusts an inherited descriptor. New Codex panes use the same per-invocation
configuration rather than a globally cached plugin. Child herdr start is likewise argv-only: only an endpoint
registry entry with current host context allows fresh preparation; a launch-only
record is left unchanged and recorded.
Do not wrap raw shell text, silently run an external browser or put tokens in env.

## Security and lifetime

Claude Code, Codex and Pi all start one MCP wrapper, `mcp-run.mjs`. It answers
`initialize`, `tools/list` and `ping` itself from `playwright-mcp-snapshot.json`,
the pinned Playwright MCP's own replies (`McpRunTests.mjs` compares it with the
live server; `node Tests/AgentBrowser/Phase3/McpRunTests.mjs --update` rewrites
it after a version bump). Other requests get Playwright's `Method not found`.
Playwright MCP starts at the first `tools/call`: the wrapper sends it the
client's own initialize, then the calls in order. If it fails to start or dies,
each call waiting for it gets a tool error result (`isError`) saying it can be
retried, and the next call starts it again; it is never restarted without a
call. Input lines are limited to 1 MiB. A Playwright output line over 8 MiB is
discarded as it streams (only its first and last 4 KiB are kept, to find its
id) and its call gets a tool error asking for `filename` or a narrower call;
Playwright keeps running with its page state. The id is read from the line's
end (`{"result":…,"jsonrpc":"2.0","id":…}`, the pinned SDK's order); when it
cannot be read, the only waiting call gets the error, or every waiting call
when several are, and later replies to them are dropped. Given a Pi bridge descriptor, the same
wrapper asks the app's bridge to admit it (`mcpAttach`) before reading anything
else, and reports `mcpReady` once it has answered initialize and tools/list.

The MCP wrapper uses supported `--config <0600 file>` with browser.cdpHeaders,
written when the wrapper starts. No bearer header is in argv/environment/reports.
Raw MCP diagnostic stderr is suppressed and protocol output is redacted. The
transient config is removed when the wrapper ends normally. An abrupt wrapper SIGKILL can leave it behind mode 0600;
owned pane cleanup removes it after the wrapper is dead. Same-user PID reuse can
conservatively delay cleanup; no processes are killed by file cleanup.

Resources are copied into hash-versioned folders, then a single installation
pointer is atomically replaced. Existing sessions keep immutable resource paths;
old versions are intentionally retained until all sessions using them are gone.
CLI capability probes have actual 20-second subprocess deadlines (a deadline
kill is a failure, never a success).

Setup uses an exclusive lock, taken in two steps. Each runtime action that
writes (install, Pi staging, reserving a launch, discarding a reservation,
preparation, pane registration and cleanup) first opens the runtime root
folder (`AgentRuntime` or `AgentRuntime-Debug`) with a kernel lock on it
(`open` with `O_EXLOCK`, the same lock as `flock`). Then it creates the file
`.lock` in that folder. When the action ends, it removes `.lock` first and
closes the folder after that.

- The kernel lock keeps actions of this version apart. If another action
  holds it, the action fails with `setup-busy` before it changes anything,
  instead of overwriting the action in progress. The kernel releases it when
  the process holding it exits, however it exits. Processes that the action
  starts, such as CLI probes, do not inherit it.
- The `.lock` file keeps out hrdrhrdrhrdr 0.5.2 and earlier. Those versions
  take the lock only by creating `.lock` as a folder, so while the file
  exists, their `mkdir` fails and they fail with `setup-busy`.

When an action finds `.lock` already there, what it does depends on what
`.lock` is:

- A file: an action of this version ended without removing it, for example
  in a crash. The action removes it and runs.
- A folder made before the Mac last started: a version up to 0.5.2 made it
  and cannot still be running. If the folder is empty, the action removes it
  and runs; if not, the action fails with `runtime-lock-failed`. A folder
  counts as made before the Mac last started when it was made more than 2
  seconds before the kernel started and more than 2 seconds before launchd
  (process 1) started. The 2 seconds allow for those start times being known
  only roughly.
- A folder made since the Mac last started, or one whose creation time cannot
  be read: the version that made it may still be running. The action fails
  with `setup-busy` and leaves the folder.
- Anything else, such as a symbolic link: the action fails with
  `runtime-lock-failed`.

The action also fails with `runtime-lock-failed` when it cannot open or lock
the root folder for any reason other than another action holding it, or
cannot create `.lock` or remove one left behind.

A launch or a resume waits up to 5 seconds for the lock. The two-second check
needs no such wait: a pane registration or preparation of its own that fails
with `setup-busy` runs again at the following check. A launch or a resume has
no following check, so it runs these runtime actions through
`AgentRuntimeLockWait`:

- a launch: install, reserving the launch, discarding the reservation, and
  preparation
- a Pi launch: install and Pi staging
- a resume: preparation

`AgentRuntimeLockWait` runs the action again every 100 ms while it fails with
`setup-busy`. When the action fails with `setup-busy` 5 seconds or more after
the first try, `AgentRuntimeLockWait` stops, and the launch or resume fails
with `setup-busy`. A failure other than `setup-busy`, or cancellation, ends the
wait at once. `runtime-lock-failed` is one of those other failures: a launch
or resume fails with it at once. When a pane registration or preparation in
the two-second check fails with it, the check waits 30 seconds before trying
that pane again, as after its other failures.

The Node process that runs `runtime.mjs` for an action holds the root folder's
kernel lock. If that process crashes or is killed, the kernel releases the
lock, and the next action removes the `.lock` file left behind and runs.
Nothing has to be removed by hand. The one exception is a `.lock` folder made
since the Mac last started by hrdrhrdrhrdr 0.5.2 or earlier. From the folder
alone, an action cannot tell whether the process that made it crashed or is
still running, so while the folder stays, every launch and resume fails with
`setup-busy` after 5 seconds. After the Mac restarts, the next action removes
it. To remove it sooner by hand, first make sure no version up to 0.5.2 is
still running, including the hooks of agent sessions started before the
update, which keep using the runtime they started with.

Output folders are private, qualified by machine/herdr/session/terminal and use
MCP outputMaxSize eviction. Explicit filename outputs are anchored to this folder;
traversal and symlink escape are rejected. A single current response may exceed
the threshold: it is not a hard filesystem quota. Existing user filesystem access
via uploads/Playwright evaluation is not made into an OS sandbox by this wrapper.
Native B permission/navigation/pane policies remain authoritative.

## Current source-only gate

`run-managed-skill-tests.py --output <fresh directory>` exercises session-only
runtime policy with fake CLIs, immutable user-home inventories, disabled legacy
RPC/MCP paths, full Codex instruction preservation, and automatic preparation
state transitions. It compiles the actual launch service/Settings source against
explicit synthetic native/transport seams; this is not a GUI or CEF E2E claim.
No live CLI authentication or global migration is part of this gate.

## Historical phase-3 evidence (not qualification of current policy)

Earlier executable tests under `Tests/AgentBrowser/Phase3` cover quoting, session paths,
parser safety/idempotence, atomic failure preimages, instruction/profile merge,
reservations, duplicates, modes, cleanup, real installed CLI local-provider
startup, Claude updatedInput, actual optional competitor-tool denial/default-off
behavior in Claude and scoped disable configuration in Codex, and the installed
pinned MCP -> accepted production
B fixture. `run-tests.py` reuses the phase2 bounded identity-checking runner and
requires natural exit with zero cleanup signals. Homes/configs/providers are
owned disposable fixtures; no credentials or production accounts are copied.

Real versions tested: Claude Code 2.1.288 and Codex 0.154.0. Provider captures are
per-invocation, attributed at HTTP request arrival; each Codex plugin/config/
global/existing-pane/resume process must expose its own hrdrhrdrhrdr navigation tools
and the selected user/override plus hrdrhrdrhrdr developer instructions. Provider
completion alone is not MCP readiness and cannot borrow earlier Claude evidence.
Existing-session resume uses an actual session ID and the CLI's documented
noninteractive exec resume form in a disposable non-Git home. MCP-to-B evidence
remains the separate actual adapter gate, not a CLI-to-new-app claim. Codex has plugin/hooks
features but no command rewriting capability is asserted: its tested fallback is
merged developer instructions and descriptor-specific MCP configuration. Claude
hook contract is tested with an owned fake herdr executable (not a real herdr
child-agent readiness pass). The production B test uses an owned exact copy of the
accepted predecessor Debug fixture; it is not the not-yet-integrated phase3 UI app.
Full UI launch/resume/board behavior, actual herdr child readiness, real account
authentication, app packaging/builds, remote routing and publication remain
integration/later-phase gates. macOS/iOS MainActor-default compiler guards include
actual AgentSkillSetup, adapter, BrowserKey, Machine and HerdrClient/model/transport
sources; the macOS endpoint definition is extracted verbatim from accepted
CDPProxy.swift to avoid importing its native implementation. These checks are not
full application builds.
