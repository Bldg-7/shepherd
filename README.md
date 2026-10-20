# hrdrhrdrhrdr for herdr

A native macOS workspace for Herdr terminals and coding agents.

[Download hrdrhrdrhrdr](https://github.com/Bldg-7/shepherd/releases/latest/download/hrdrhrdrhrdr.dmg) · [Website](https://bldg-7.github.io/shepherd/) · [Releases](https://github.com/Bldg-7/shepherd/releases)

This repository contains the **macOS application source**, its required shared dependencies, website and signed releases. Mobile application branches and development evidence are not included. The existing public repository history is preserved.

## Requirements

- macOS 26.6.2 or later. Experimental Chromium browsing requires Apple silicon; the Intel build retains terminal functionality.
- Herdr installed separately.
- Optional managed browser agents: Node >=20 for Claude Code/Codex; **Pi 1.x (`^1.0.0`) requires Node >=22.19.0**. Agent CLIs and their authentication remain user-managed.

## Experimental browser and agents

The browser is **OFF by default**. Enable it in **Settings → Experimental Features**, wait for Preparation, then choose Claude Code, Codex or Pi when opening a new tab.

Resources are bundled and injected into the new session only. No global MCP/skill installation, runtime npm download, automatic trust approval or replacement of user instructions/extensions is performed. The authenticated native browser endpoint is pane-scoped.

**Do not run the old `npx skills … --global` / `setup.sh` instructions.** Those legacy entry points now refuse installation. Previously installed global hrdrhrdrhrdr registrations must be reviewed and removed explicitly by their owner; the app does not silently edit them.

Pi supports fresh local managed TUI sessions. Exact saved-session resume, browser-enabled child/headless processes, automatic reauthorization after session-ID/file changes and competing-MCP dispatch suppression remain unsupported. Because of that, "Block other browser tools" is not applied to Pi: Pi still launches when the setting is on, and keeps all of its MCP servers. See [Pi support](docs/pi-agent-support.md).

Password-manager connection does not imply credential-fill authorization. Native credential binding/proxy composition is not complete. Chrome password import/sync is not included.

## Machine editing and file preview

Edit registered machines in Settings → Machines. Existing SSH credentials stay unchanged unless Change Authentication is explicitly enabled.

Click an OSC8 file link (for example from `ls --hyperlink`) to open the read-only preview beside the terminal; Command-click also works. Plain text is not a file link even when it looks like a path, `path:line` or `file://` URL: clicking it goes to the TUI like any other text. Code wraps automatically and uses basic native syntax highlighting; Markdown has rendered/source modes. Remote files are read over SFTP on the clicked machine, not opened by a remote editor or resolved against the Mac. File gestures are claimed before terminal mouse reporting and kept local, with or without Command. HTTP(S) URLs, plain text or OSC8, are also captured locally; non-link clicks still belong to the TUI. Settings → Experimental Features → Open links in says whether they open in a new tab of the clicked pane's In-app Browser or in the Mac's default browser; until you choose, the first click asks. ⌘-click opens a link in the other browser, and the In-app Browser's ⋯ menu sends the page it shows to the default browser. With In-app Browser OFF or unavailable, links open in the default browser; the browser is never turned on for a link. `localhost` URLs refer to the Mac, not an automatic SSH tunnel. Nested Herdr-machine file routing is not supported.

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
