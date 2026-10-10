# Shepherd for herdr

A native macOS workspace for Herdr terminals and coding agents.

[Download Shepherd](https://github.com/Bldg-7/shepherd/releases/latest/download/Shepherd.dmg) · [Website](https://bldg-7.github.io/shepherd/) · [Releases](https://github.com/Bldg-7/shepherd/releases)

This repository contains the **macOS application source**, its required shared dependencies, website and signed releases. Mobile application branches and development evidence are not included. The existing public repository history is preserved.

## Requirements

- macOS 26.6.2 or later. Experimental Chromium browsing requires Apple silicon; the Intel build retains terminal functionality.
- Herdr installed separately.
- Optional managed browser agents: Node >=20 for Claude Code/Codex; **Pi 1.1.0 requires Node >=22.19.0**. Agent CLIs and their authentication remain user-managed.

## Experimental browser and agents

The browser is **OFF by default**. Enable it in **Settings → Experimental Features**, wait for Preparation, then choose Claude Code, Codex or Pi when opening a new tab.

Resources are bundled and injected into the new session only. No global MCP/skill installation, runtime npm download, automatic trust approval or replacement of user instructions/extensions is performed. The authenticated native browser endpoint is pane-scoped.

**Do not run the old `npx skills … --global` / `setup.sh` instructions.** Those legacy entry points now refuse installation. Previously installed global Shepherd registrations must be reviewed and removed explicitly by their owner; the app does not silently edit them.

Pi supports fresh local managed TUI sessions. Exact saved-session resume, browser-enabled child/headless processes, automatic reauthorization after session-ID/file changes and competing-MCP dispatch suppression remain unsupported. See [Pi support](docs/pi-agent-support.md).

Password-manager connection does not imply credential-fill authorization. Native credential binding/proxy composition is not complete. Chrome password import/sync is not included.

## Machine editing and file preview

Edit registered machines in Settings → Machines. Existing SSH credentials stay unchanged unless Change Authentication is explicitly enabled.

Command-click a file path, `file://` URL or OSC8 file link to open the read-only preview beside the terminal. Code wraps automatically and uses basic native syntax highlighting; Markdown has rendered/source modes. Remote files are read over SFTP on the clicked machine, not opened by a remote editor or resolved against the Mac. File gestures are kept local; ordinary clicks still belong to the TUI. Nested Herdr-machine file routing is not supported.

The preview and experimental browser share the side-panel slot; switching visibility preserves browser tabs/profiles. The preview has a circular Liquid Glass close button and no header refresh button. Browser integration uses pane-scoped status icons; Group by Tab hides unknown/unavailable captions and pane counts. Pi automatic title prefixes are hidden for display only.

See [0.3.0 release notes](notes/0.3.0.md) for limits and validation scope.

## Build from source

Use Xcode 27 and its command-line tools. The repository pins Swift dependencies in `Package.resolved`, Chromium/CEF in `scripts/cef.sh`, and browser Node packages in `package-lock.json`.

```sh
scripts/cef.sh
npm ci --prefix Shepherd/Agents/AgentRuntime --ignore-scripts --no-audit --no-fund
open shepherd.xcodeproj
```

CEF and `node_modules` are build inputs, not committed binaries. SwiftTerm 1.20.0's `SwiftTermBuildInfoPlugin` may require Xcode's explicit package-plugin approval; do not disable plugin validation globally. Debug builds have no Sparkle update feed. For unsigned local builds, use `CODE_SIGNING_ALLOWED=NO`.

[Release procedure](docs/releasing-macos.md) · [0.3.1 release notes](notes/0.3.1.md) · [0.3.0 feature notes](notes/0.3.0.md)
