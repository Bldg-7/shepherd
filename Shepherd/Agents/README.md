# Agent runtime boundary (phase 3)

This component consumes `CDPProxy.endpoint(for:)` and the accepted
`BrowserKey`/terminal identity. It never uses a CEF debugging socket. Remote
capability is intentionally unavailable.

## Current policy: automatic, Shepherd-session-only

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

No operation writes user CLI settings, user skill folders, or the Codex plugin
cache. Existing global Shepherd skills/MCP/enabled plugins cause explicit
rejection, not automatic deletion or migration. Old `setupCodex`/`setMode` RPCs
return `session-only-policy`; the MCP `--global` entry point is disabled.

## Pi local managed TUI launch

Pi 1.1.0 is available in the macOS launcher when the experimental browser is ON.
It requires Node >=22.19.0; the existing Claude/Codex Node 20 floor is unchanged.
`pi-runtime.mjs` probes the package-declared executable without running Pi or
loading personal settings/auth. Metadata availability never proves login or a
browser connection. Legacy argv/session parsers remain disabled for Pi even
though its dedicated launch path is enabled.

`stagePi` prepares a session-local executable shim, extension, skill and appended
guidance. `pi-launch.mjs` waits for an authenticated foreground binding before
importing the real CLI, closing the startup race with Pi's argv/title rewrite.
`PiLaunchCoordinator` observes the exact Herdr pane/terminal on a separate
connection while agent.start is pending. `PiBrowserLeaseProvider` composes the
real CDP proxy: per-epoch route leases deny unleased fallback and old-route replay,
recheck live process authority before dispatch, and wait for native detach.

The built-in MCP backend and adapter 5.1.0 are both qualified with actual Pi,
Herdr and CEF through the public launch service. Private normal Pi settings,
user instructions and extensions survive; model responses come only from an
owned loopback fake provider. No vendor accounts or personal profiles are used.
Session-only Herdr state reports travel through the authenticated app bridge,
not an inherited socket/pane environment. Adapter conflicts do not fall back to
the built-in backend. Its runtime server is session-owned, with acknowledged
unregistration; no global MCP/skill installation or npm/download is performed.

Resume, child/headless launch and competing-browser dispatch suppression remain
unqualified. A different session ID/file is retired and denied, not silently
rebound; use a fresh managed launch. See `docs/pi-agent-support.md` for scope,
security contracts, evidence and these explicit limitations.

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
and contain `node_modules`, `runtime-core.mjs`, `mcp-run.mjs`, `hook.mjs`, the
lock/manifest, and `skill/SKILL.md`. Do not auto-add every node_modules file as an
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
`setup-busy`, `session-only-policy`, `legacy-global-registration-present`,
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
   bundled resources automatically and check that no global Shepherd registration
   conflicts. Do not install a Codex marketplace/plugin into its user home.
2. **Before creating the pane**, call reserveLaunch and pass its environment to
   `tab.create` / `workspace.create`. herdr `agent.start` accepts argv, not env.
3. After the returned pane appears in an accepted local snapshot, obtain its
   actual `BrowserKey` and terminal ID and `CDPProxy.endpoint(for:)`. No descriptor
   means no browser launch; do not invent a port, token or remote route.
4. Call prepare with the reservation and actual endpoint. Environment is unchanged
   from step 2. Start through typed herdr agent.start with its `arguments`.
5. Register accepted local snapshot endpoints so Claude child hooks can lazily
   prepare exactly the requested child. No registered/ambiguous pane means the
   original command is retained and reason-recorded; never use a parent URL.
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

The MCP wrapper uses supported `--config <0600 file>` with browser.cdpHeaders.
No bearer header is in argv/environment/reports. Raw MCP diagnostic stderr is
suppressed and protocol output is redacted. The transient config is removed on
normal MCP termination. An abrupt wrapper SIGKILL can leave it behind mode 0600;
owned pane cleanup removes it after the wrapper is dead. Same-user PID reuse can
conservatively delay cleanup; no processes are killed by file cleanup.

Resources are copied into hash-versioned folders, then a single installation
pointer is atomically replaced. Existing sessions keep immutable resource paths;
old versions are intentionally retained until all sessions using them are gone.
CLI capability probes have actual 20-second subprocess deadlines (a deadline
kill is a failure, never a success). Setup uses an exclusive root lock and fails
`setup-busy` rather than clobbering an in-flight operation. A process crash can leave the lock; it is not automatically
removed by guessing ownership. Explicit recovery must prove that installer ended.

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
global/existing-pane/resume process must expose its own Shepherd navigation tools
and the selected user/override plus Shepherd developer instructions. Provider
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
