# hrdrhrdrhrdr for herdr

[English](README.md) · [한국어](README_KO.md) · [日本語](README_JP.md)

A native macOS workspace for Herdr terminals and coding agents.

[Download the released macOS app](https://github.com/Bldg-7/shepherd/releases/latest/download/hrdrhrdrhrdr.dmg) · [Website](https://bldg-7.github.io/shepherd/) · [Releases](https://github.com/Bldg-7/shepherd/releases)

## Overview

hrdrhrdrhrdr brings Herdr workspaces to macOS with local and SSH-connected machines, saved herdr machines, terminal panes, and coding-agent sessions. It adds native file preview, machine management, and an opt-in pane-scoped In-app Browser for supported managed agents.

This repository contains the source for the macOS app, the iPhone and iPad app (`ShepherdMobile/`), their shared `ShepherdKit` package, site, and release materials. The download link above is for released macOS binaries; source presence does not promise a public mobile distribution.

## Key capabilities

- Work with This Mac, SSH machines configured in Settings, and machines saved by herdr.
- Open OSC 8 file links in a read-only preview, including Markdown rendering, a heading table of contents, find, and reload.
- Open terminal web links in the pane's In-app Browser or, with Command-click, the macOS default browser; HTML file-link handling follows the same boundary where supported.
- Pair an iPhone or iPad with This Mac by QR code and Remote Login. Pairing uses a Secure Enclave key and requires your explicit confirmation.
- Start fresh local managed Claude Code, Codex, or Pi sessions from the new-tab launcher when the experimental browser is prepared.

For interaction details, remote-machine behavior, pairing security, conversation-capture boundaries, and feature caveats, read the **[English user guide](docs/user-guide.md)**.

## Requirements and limits

- macOS **26.6.2 or later** and a separately installed **Herdr** are required.
- The experimental Chromium-based In-app Browser is **OFF by default**, works only on Apple silicon, and is not available on Intel Macs; terminal functionality remains available there.
- Managed browser agents are optional. Claude Code and Codex require Node **>=20**. Pi supports **1.x (`^1.0.0`)** and requires Node **>=22.19.0**.
- Agent CLIs and their authentication are user-managed. Browser preparation, MCP registration, browser connection, provider connection, and credential approval are separate states.
- Pi supports fresh local managed TUI sessions. Saved-session resume, child/headless browser-enabled processes, automatic reauthorization after session changes, and competing-MCP dispatch suppression are unsupported. **Block other browser tools** does not apply to Pi.

## Getting started

1. Install Herdr separately, then download a released macOS binary from the link above or build from source below.
2. Open hrdrhrdrhrdr and connect to This Mac or add an SSH machine in **Settings → Machines**.
3. To use the experimental browser, enable it in **Settings → Experimental Features** and wait for Preparation to finish.
4. Open a new tab and select Shell, Claude Code, Codex, or Pi. Select an agent only after you have installed and authenticated its CLI yourself.

Browser resources are bundled and injected only into the new managed session. hrdrhrdrhrdr does not install global MCP servers or skills, download npm packages at runtime, approve trust automatically, or replace your agent instructions or extensions. The authenticated browser endpoint is pane-scoped.

**Do not run legacy `npx skills … --global` or `setup.sh` installers.** They refuse installation. If you previously installed global hrdrhrdrhrdr registrations, review and remove them yourself; the app does not modify them silently.

## Build from source

Use **Xcode 27** and its command-line tools. The repository pins Swift dependencies in `Package.resolved`, Chromium/CEF in `scripts/cef.sh`, and browser Node packages in `package-lock.json`.

```sh
scripts/cef.sh
npm ci --prefix Shepherd/Agents/AgentRuntime --ignore-scripts --no-audit --no-fund
open shepherd.xcodeproj
```

CEF and `node_modules` are build inputs, not committed binaries. Approve the exact SwiftTerm 1.20.0 build plugin if Xcode asks; do not disable plugin validation globally. Debug builds have no Sparkle update feed. For an unsigned local build, use `CODE_SIGNING_ALLOWED=NO`.

## Documentation

- **[User guide (English)](docs/user-guide.md):** detailed usage, privacy and trust boundaries, limitations, and trademarks.
- **[Pi support](docs/pi-agent-support.md):** managed Pi scope and technical support boundaries (Korean).
- **[Link-opening UX](docs/link-opening-ux.md):** design history and current link-opening rules (Korean).
- **[macOS release procedure](docs/releasing-macos.md):** maintainer release instructions.
- [0.3.1 release notes](notes/0.3.1.md) · [0.3.0 feature notes](notes/0.3.0.md)
