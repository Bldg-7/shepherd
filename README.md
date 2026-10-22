# hrdrhrdrhrdr for herdr

A native macOS workspace for Herdr terminals and coding agents.

[Download hrdrhrdrhrdr](https://github.com/Bldg-7/shepherd/releases/latest/download/hrdrhrdrhrdr.dmg) · [Website](https://bldg-7.github.io/shepherd/) · [Releases](https://github.com/Bldg-7/shepherd/releases)

This repository contains:

- the source of the **macOS application**
- the source of the **iPhone and iPad application** (`ShepherdMobile/`)
- the `ShepherdKit` package that both applications use
- their required shared dependencies, the website, and signed releases

Development evidence is not included. The existing public repository history is preserved.

## Requirements

- macOS 26.6.2 or later. Experimental Chromium browsing requires Apple silicon; the Intel build retains terminal functionality.
- Herdr installed separately.
- Optional managed browser agents: Node >=20 for Claude Code/Codex; **Pi 1.x (`^1.0.0`) requires Node >=22.19.0**. Agent CLIs and their authentication remain user-managed.

## Experimental browser and agents

The browser is **OFF by default**. Enable it in **Settings → Experimental Features**, wait for Preparation, then choose Claude Code, Codex or Pi when opening a new tab. To choose, click one in the new tab launcher's Launch picker, or press the Tab key while you type the new tab's name: Tab moves the choice to the next of Shell, Claude Code, Codex and Pi, and ⇧Tab to the previous one. The text cursor stays in the name field, and the name you typed is kept.

Resources are bundled and injected into the new session only. No global MCP/skill installation, runtime npm download, automatic trust approval or replacement of user instructions/extensions is performed. The authenticated native browser endpoint is pane-scoped.

**Do not run the old `npx skills … --global` / `setup.sh` instructions.** Those legacy entry points now refuse installation. Previously installed global hrdrhrdrhrdr registrations must be reviewed and removed explicitly by their owner; the app does not silently edit them.

Pi supports fresh local managed TUI sessions. Exact saved-session resume, browser-enabled child/headless processes, automatic reauthorization after session-ID/file changes and competing-MCP dispatch suppression remain unsupported. Because of that, "Block other browser tools" is not applied to Pi: Pi still launches when the setting is on, and keeps all of its MCP servers. See [Pi support](docs/pi-agent-support.md).

Password-manager connection does not imply credential-fill authorization. Native credential binding/proxy composition is not complete. Chrome password import/sync is not included.

## Machine editing and file preview

Edit registered machines in Settings → Machines. Existing SSH credentials stay unchanged unless Change Authentication is explicitly enabled.

Click an OSC8 file link (for example from `ls --hyperlink`) to open the read-only preview beside the terminal; Command-click also works. Plain text is not a file link even when it looks like a path, `path:line` or `file://` URL: clicking it goes to the TUI like any other text. Code wraps automatically and uses basic native syntax highlighting; Markdown has rendered/source modes. In both modes, a table of contents of the file's headings floats at the top right of the preview. Click a heading to bring it to the top; the heading you are reading is highlighted. The list button next to Source hides or shows it, for that preview only. Every Markdown file opens with it shown. A file with no headings has no table of contents, and the button is disabled. Press ⌘F while the preview has the keyboard to search the text it shows. Clicking anywhere in the preview gives it the keyboard; click the terminal to type there again. ⌘F while the terminal has the keyboard goes to the terminal, as before. The find bar opens at the top of the preview and finds as you type, ignoring case. A rendered Markdown file is searched in the text you see, including code, tables and frontmatter but not `**` or link targets; Source and other text files are searched in their lines as written. Every match is highlighted and the current one stands out, and the bar shows where you are, such as 3 / 17, or No Results. Return, ⌘G or the down arrow button goes to the next match, and ⇧Return, ⇧⌘G or the up arrow button to the previous one, wrapping around at either end; the preview scrolls to it. Esc or the close button closes the bar and removes the highlights. While the preview has the keyboard and the bar is closed, Esc closes the preview, or returns an expanded one to its place beside the terminal. Each pane's preview keeps its search; opening the file again clears it. The Reload button (↻) in the preview's header, left of the expand button, reads the file again, and so does ⌘R while the preview has the keyboard; while the terminal has the keyboard, ⌘R goes to the terminal as before. Reload keeps how you are looking at the file: rendered or Source, the scroll position (or the end, if the file is now shorter), whether the table of contents is shown, and the find bar with its search, whose matches are counted again in the new text. A line highlighted by a link to a line (`path:line`) stays highlighted. While the file is read, the old text stays on screen and a small spinner takes the button's place. If the read fails, for example because the file was deleted, the preview says why and offers Retry, which now works like Reload. A remote file is read again over a new SFTP connection. The preview never reloads by itself, and selecting its pane again doesn't reload it; only a reload that was interrupted by selecting another pane is made again when you come back. Remote files are read over SFTP on the clicked machine, not opened by a remote editor or resolved against the Mac. File gestures are claimed before terminal mouse reporting and kept local, with or without Command. HTTP(S) URLs, plain text or OSC8, are also captured locally; non-link clicks still belong to the TUI. A click on an HTTP(S) link opens it in a new tab of the clicked pane's In-app Browser, the way a click on a file link opens the preview. ⌘-click opens it in the Mac's default browser, and the In-app Browser's ⋯ menu sends the page it shows to the default browser. A double or triple click on a link opens it once. With In-app Browser OFF in Settings, links open in the default browser. With it on but unable to run on this Mac (an Intel Mac), they open in the default browser too, and a notice at the bottom of the terminal says why. Clicking a link never turns In-app Browser on. A file link to an HTML file (`.html` or `.htm`) in a pane of This Mac, not of a herdr machine, opens the page in a browser instead of the preview, by the same rules as an HTTP(S) link: a plain click opens it in a new tab of the clicked pane's In-app Browser, and a ⌘-click opens it in the default browser. With In-app Browser off, or on an Intel Mac, a plain click also opens it in the default browser. For such a file, the default browser is the app that opens `https` links, even if `.html` files are set to open in an editor. The `#fragment` of a `file://` link is kept, and the line number of a link such as `report.html:12` is dropped. While an agent is connected to the pane's In-app Browser, a click opens the file in the default browser instead, and a notice at the bottom of the terminal says why. When an agent connects to a pane's In-app Browser, any tab there that shows a file on this Mac becomes a blank tab with its history cleared, so the agent can't see the file. The In-app Browser still doesn't let a connected agent open `file://` pages itself. HTML files in panes of SSH machines and herdr machines, and `.xhtml` and `.svg` files, still open in the preview, which shows HTML as source and never runs it. `localhost` URLs refer to the Mac, not an automatic SSH tunnel. Nested Herdr-machine file routing is not supported.

Drag in a terminal to select text, and press ⌘C to copy it. In a shell, or in Claude Code with its default interface, a plain drag selects. Pi and Codex use the mouse themselves, so in their panes a plain drag still goes to the program; hold ⇧ while you drag to select there instead. ⇧-drag selects in any pane and also when it starts on a link, and ⇧-click extends a selection without opening the link under it. The one exception is a program that has asked the terminal to pass ⇧ clicks on to it (XTSHIFTESCAPE): it still receives them, so ⇧ doesn't select there. In a pane whose program doesn't use the mouse, a plain drag that starts on a link turns into a selection once it has moved more than a few points; a click without dragging still opens the link. A selection stays while the pane's output changes elsewhere on the screen. It ends when the text under it changes, when you click without ⇧, when you type, or when the window changes size; ⌘C doesn't end it. The mouse wheel scrolls herdr's scrollback as before.

To make plain drags reach the terminal, hrdrhrdrhrdr starts each of its own `herdr terminal attach` processes with herdr's `ui.mouse_capture` setting off, so herdr asks for mouse input only when the pane's program uses the mouse. It does this by pointing the `HERDR_CONFIG_PATH` environment variable at a small herdr configuration file of its own: `~/Library/Caches/com.bldg-7.shepherd/herdr-attach.toml` on this Mac, and `~/.cache/3rdr/herdr-attach.toml` on an SSH host or herdr machine, written there when a pane is attached. Your `~/.config/herdr/config.toml` is not changed, and herdr's server and the herdr windows you open yourself keep using it. hrdrhrdrhrdr's attach processes don't read your file, though, so the few herdr settings that take effect in the attach process itself use herdr's defaults in hrdrhrdrhrdr: for example `ui.mouse_scroll_lines` (three lines per wheel step) and custom notification sound files. With herdr older than 0.9.0, a plain drag still selects nothing; use ⇧-drag.

In the sidebar, a pane's second line says which agent runs in it. For Claude Code and Pi it shows the agent's logo, in the logo's own colors, instead of its name. Hold the pointer over the logo to see the name; VoiceOver reads the name too. Codex and the other agents herdr knows are still shown by name, and a pane without an agent shows its folder. A search in the sidebar still matches the agent's name, so `claude` finds Claude Code's panes. The iPhone and iPad app shows names, not logos. Claude is a trademark of Anthropic, PBC, and the Pi logo belongs to Earendil Inc.; hrdrhrdrhrdr is not affiliated with or endorsed by them.

Drag a pane or a tab from the sidebar onto a terminal to paste its herdr ID there, followed by a space: a pane's ID such as `w1:p4`, or a tab's such as `w1:t2`. Nothing else is typed, Return is not pressed, and the keyboard stays where it was. The ID is pasted in one piece, the way a dropped file's path is, so a shell, Claude Code, Codex or Pi takes it as pasted text. A terminal takes the drop whether or not an agent runs in it, and with Terminal File Drop on or off, but not while it is still connecting or after its connection failed. An ID means something only to the herdr that gave it out, so a terminal takes only rows of the herdr its own pane runs on. A pane on a herdr machine (see "herdr machines" below) takes only rows of that herdr machine. A pane of This Mac or of an SSH machine takes only that machine's own rows, not those of its herdr machines or of another machine. While the terminal under the pointer would take the drop, it shows an accent-colored border. Dropped into another app, such as TextEdit, a row gives the ID alone, without the space.

The preview and experimental browser share the side-panel slot; switching visibility preserves browser tabs/profiles. The preview has a circular Liquid Glass close button; its other header buttons, Reload included, are plain icons. Browser integration uses pane-scoped status icons; Group by Tab hides unknown/unavailable captions and pane counts. Pi automatic title prefixes are hidden for display only.

See [0.3.0 release notes](notes/0.3.0.md) for limits and validation scope.

## Pane names and agent sessions

When you rename a pane in hrdrhrdrhrdr (Rename Pane… in a row's menu, or a double-click on the title), the Claude Code or Codex session in that pane gets the same name, once. hrdrhrdrhrdr types the agent's own `/rename <name>` command into the agent through herdr. This works for panes on This Mac, on an SSH machine added in Settings → Machines, and on a herdr machine.

The command is typed only when the agent is ready for your next message and its input box is empty. A grey suggestion that Claude Code shows in an empty box counts as empty. Otherwise the rename is held back: while the agent is working or starting, while it shows a question or approval prompt, or while you have typed something in its input box. A held rename is checked again each time the sidebar updates and is typed once the agent is ready. A newer rename replaces a held one. A held rename is dropped when the pane closes, when another agent or session takes the pane's place, or when hrdrhrdrhrdr quits. The `/rename` line stays in the agent's terminal and in its input history.

A Pi session opened from the New Tab launcher gets the name through hrdrhrdrhrdr's Pi extension while Pi is idle, and nothing is typed. A Pi started from a shell is not renamed.

These don't rename any session: clearing a pane's name (the session keeps its name), renaming a tab, renaming a pane outside hrdrhrdrhrdr (in herdr's own window, for example), and renaming a pane that has no agent. The name is passed on as a single line of at most 200 characters.

## iPhone and iPad

The iPhone and iPad app can add this Mac as a machine by scanning a QR code. The device then connects to this Mac's herdr over Remote Login (macOS's SSH server) with a key made in its Secure Enclave, which never leaves the device. hrdrhrdrhrdr only does the pairing and doesn't need to be running afterwards.

On the Mac, open Settings → iPhone and iPad and click Add Device…. The page first checks that Remote Login is on (System Settings → General → Sharing; Open Sharing Settings… goes there, and the page checks again every two seconds), whether herdr is running, whether the firewall would block devices from connecting, and whether `~/.ssh/authorized_keys` can be written. hrdrhrdrhrdr never turns Remote Login on itself. The page then lists the addresses a device could reach this Mac at: its `.local` name and its private IPv4 addresses on Wi-Fi and wired networks, and with Tailscale on, its Tailscale IPv4 address and MagicDNS name. Pick one; the code carries only that one. The kind picked last time is picked again; the first time, the order is MagicDNS, Tailscale IPv4, `.local`, private IPv4.

Devices can be added only while the window shows This Mac. While it shows another machine, Add Device… in Settings → iPhone and iPad is greyed out, and "Connect to This Mac to add a device." appears under the device list. Paired devices are still listed, and you can still remove them. To add a device, first click Make Active next to This Mac in Settings → Machines. If the window switches to another machine while the Add Device page shows a QR code (for example, when you click a notification from a pane on that machine), the code disappears and can no longer be used. The Add Device page says why, and shows no new code until This Mac is active again. If a device's request is already on the Add Device page, you can still click Approve… or Reject. An approval you already started still goes to the end: the Touch ID or password prompt, the line added to `authorized_keys`, and the device's report after its first login. Add Another Device on the result is then greyed out.

Show QR Code shows a code that can be used once and lasts two minutes; a new code replaces it every two minutes and whenever the address changes. While codes are shown, and for ten minutes at most, hrdrhrdrhrdr listens for devices on an IPv4 port of its own. It accepts a connection only when both the device's address and the address it reached this Mac at are of the kind picked, and it stops listening after 20 failed requests, such as unreadable messages or unknown codes. With the firewall on, macOS may ask whether hrdrhrdrhrdr may accept incoming connections; click Allow. Anyone who can see a code can use it to ask to connect, so don't show a code while you share your screen. hrdrhrdrhrdr also leaves the Settings window out of screen captures and screen sharing from the moment a code is shown until the window is closed.

In the iPhone or iPad app, tap + in Machines, then Scan Mac's QR Code, and point the camera at the code. The app asks for the camera the first time. It scans the code with its own camera view; a code photographed with the Camera app can't be used. Before it sends anything, it shows what the code says: the Mac's name, the account and address it will connect to and the address's kind, the Mac's SSH host key, the time left on the code, and this device's name as the Mac will show it, which you can change. Tap Connect. A `.local` name or a private IPv4 address makes iOS ask for Local Network permission the first time; a MagicDNS name needs Tailscale connected on the device, with the Tailscale app's Use Tailscale DNS setting on.

The Mac then shows the device's name, its model and a six-digit confirmation code, and the device shows a code too. Check that the two codes match, then click Approve… on the Mac and confirm with Touch ID or your password, or click Reject. A request that isn't answered within a minute is turned down; while the Touch ID or password prompt is open, the Mac waits up to two minutes. If the device cancels or loses its connection before you answer, the request goes away, any Touch ID or password prompt for it is cancelled, nothing is added, and a new code is shown. On approval, hrdrhrdrhrdr appends one line to `~/.ssh/authorized_keys`: `restrict,port-forwarding ecdsa-sha2-nistp256 … shepherd-mobile:<id>:<name>`, where `<id>` and `<name>` are the device's ID and name. `restrict` turns off SSH's optional features (a terminal, agent and X11 forwarding, port forwarding), and `port-forwarding` turns port forwarding back on, because the device reaches herdr's socket through it. hrdrhrdrhrdr writes the line only when the `~/.ssh` folder and the file are your own, are not links, and can't be written by others; otherwise it shows a command you can run to add the line yourself. The device then saves the Mac, logs in over SSH at the same address with the host key from the code, asks herdr for its panes, tells the Mac how that went and opens the Mac's board. If the Mac turns the request down, or the code has expired or was already used, nothing is saved on the device. If the first login fails after the approval, the Mac stays in Machines and the app says why.

Scanning the code of a Mac that is already in Machines doesn't add it twice. At the same address, the app says the Mac is already added. At a new address, Use New Address logs in there with the key and host key the app already has, and changes only the address if the login and herdr work; you don't approve on the Mac again. A code whose SSH host key differs from the saved one changes nothing: if you reinstalled macOS, remove the Mac from Machines and scan again. Machines can still be added by hand with + → Add Machine Manually.

Settings → iPhone and iPad on the Mac lists the paired devices with their key fingerprints and says when a device's line is no longer in `authorized_keys`. Removing a device takes out only its own line. A connection the device already has open stays until it ends; turn Remote Login off and on to end it. Pairing the same device again with a new key adds a new line and leaves the old one listed, so remove the old one yourself. When a paired Mac turns the device's key down, the device's board says that the Mac removed its access, and stops trying. The device list and the last 1,000 pairing events are kept in `~/Library/Application Support/com.bldg-7.shepherd/`. The iPhone and iPad app is in English, Korean and Japanese.

## herdr machines

herdr can save other computers it connects to over SSH, with `herdr machine add`;
herdr calls each one a machine, and the sidebar shows each in its own group. In
this section, the host is the machine hrdrhrdrhrdr is connected to (This Mac, or a
machine added in Settings), and a herdr machine is a computer saved in the host's
herdr. hrdrhrdrhrdr can add a herdr machine to the host's herdr, check one that
fails to connect, and remove one. This needs herdr 0.9.0 or later on the host.

Adding a herdr machine works only while the host is This Mac. While the window
shows a machine added in Settings, the three Add herdr Machine… items listed under
Add below (in the File menu, in the host's group header menu and in the New Tab
launcher) are greyed out and show "Connect to This Mac to add a herdr machine." To
add a herdr machine, first click Make Active next to This Mac in Settings →
Machines. Reconnect… and Remove work on every host. If the window switches to
another machine while the Add herdr Machine panel is open, the panel closes, and a
`herdr machine add` that the panel is still running is stopped.

- **Add:** use any of these:
  - File → Add herdr Machine…
  - Add herdr Machine… in the host's group header menu
  - the last row of the New Tab launcher's Machine step. If no herdr machine is
    saved yet, the launcher skips that step; press Backspace while the Workspace
    step's field is empty to go back to it.

  Then pick a Host alias from the host's `~/.ssh/config`, or type an SSH target,
  and name the new machine. hrdrhrdrhrdr runs these checks on the host:
  1. It resolves the target with `ssh -G`.
  2. It signs in to the target from the host the way herdr will, with `BatchMode`
     and strict host key checking.
  3. If the target's host key is new to the host, hrdrhrdrhrdr shows the key's
     fingerprint. When you trust the key, hrdrhrdrhrdr adds it to the host's
     `known_hosts`. It never overwrites a key that has changed or been revoked.
  4. It runs `herdr machine add`.
- Three cases need you to answer at a terminal: herdr asks to install or update
  itself on the new machine, the target is reached through a jump host whose key
  the host doesn't know, or the sign-in asks you to log in in a browser.
  hrdrhrdrhrdr then opens a new tab on the host that runs `herdr machine add`
  there, so you can answer.
- A target that accepts only a password, or a password plus a one-time code,
  can't be added, because herdr signs in only with SSH keys or ssh-agent.
- **Check again:** Reconnect… in the group header menu of a herdr machine that
  fails to connect runs the checks again.
- **Remove:** Remove “workbox”… in the group header menu of a herdr machine named
  workbox, or File → Remove herdr Machine “workbox”…, removes that machine from the
  host's herdr. The herdr sessions running on workbox keep running, and workbox's
  host key stays in the host's `known_hosts`.

With herdr machines saved, drag a group's header in the sidebar, the host's own or a
herdr machine's, to put the groups in another order. While you drag, every group
shows only its header, and a line shows where the group will go. Let go to move it
there; each group is then folded or unfolded as it was before. Press Escape, or let
go outside the sidebar, to leave the order as it was. A header let go over a
terminal types nothing there. The order is kept separately for each host, and a
herdr machine added later goes at the end. herdr's own order (`herdr machine list`)
doesn't change, and the iPhone and iPad app is unchanged.

## Build from source

Use Xcode 27 and its command-line tools. The repository pins Swift dependencies in `Package.resolved`, Chromium/CEF in `scripts/cef.sh`, and browser Node packages in `package-lock.json`.

```sh
scripts/cef.sh
npm ci --prefix Shepherd/Agents/AgentRuntime --ignore-scripts --no-audit --no-fund
open shepherd.xcodeproj
```

CEF and `node_modules` are build inputs, not committed binaries. SwiftTerm 1.20.0's `SwiftTermBuildInfoPlugin` may require Xcode's explicit package-plugin approval; do not disable plugin validation globally. Debug builds have no Sparkle update feed. For unsigned local builds, use `CODE_SIGNING_ALLOWED=NO`.

[Release procedure](docs/releasing-macos.md) · [0.3.1 release notes](notes/0.3.1.md) · [0.3.0 feature notes](notes/0.3.0.md)
