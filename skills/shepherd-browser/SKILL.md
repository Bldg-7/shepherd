---
name: shepherd-browser
description: "Use the browser Shepherd shows beside this herdr pane: open pages, read them, click, type and take screenshots there, where the person can watch and step in. Use when a task in a herdr pane needs a web browser and Shepherd is showing the pane, or when the person mentions Shepherd's browser. Also sets its tools up for Claude Code and Codex. Requires HERDR_ENV=1."
---

# Shepherd browser

Shepherd, the Mac app that shows herdr's panes, keeps a Chromium browser for each pane and shows it beside the pane. This skill drives that browser through the `shepherd-browser` MCP server: Playwright MCP, connected to this pane's browser and to no other. What you do there happens on the person's screen, in a browser that may be signed in to their accounts.

## Check that you are in a pane

```bash
test "${HERDR_ENV:-}" = 1 && test -n "${HERDR_PANE_ID:-}"
```

If the check fails, you are not running in a herdr pane and there is no Shepherd browser for you. Say so, and don't switch to some other browser without asking.

## Use the browser

The tools are Playwright MCP's, from the `shepherd-browser` server: `browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_take_screenshot` and the rest. In Claude Code they are called `mcp__shepherd-browser__browser_navigate` and so on.

- Work from `browser_snapshot`. It lists the page's elements with a ref for each, which is what `browser_click` and `browser_type` take. Take a screenshot when what matters is how the page looks.
- The browser belongs to this pane. Agents in other panes have browsers of their own, and you can't reach theirs.
- The person shares the browser with you and may be signed in to their own accounts in it. Don't sign out, change account settings, buy, send, post or delete anything they didn't ask for.
- Stay in the tab you have unless the task needs another. When you're done, leave the page open: the person may want to look at it.

If a tool can't connect, Shepherd isn't running or isn't showing a browser for this machine. Tell the person rather than retrying.

## If the tools aren't there

`shepherd-browser` isn't registered with this agent yet. Run the setup script that comes with this skill. Where `npx skills` or Shepherd installed it, that is:

```bash
sh ~/.agents/skills/shepherd-browser/scripts/setup.sh
```

It registers the server with Claude Code and with Codex, whichever this machine has, and replaces an earlier registration. Settings → Agents → Set Up in Shepherd does the same. An agent loads its MCP servers when its session starts, so the tools appear only in a session started afterwards. Tell the person to restart this one.

## How it connects

`scripts/mcp.sh` starts Playwright MCP (`npx @playwright/mcp@latest`) with the CDP endpoint Shepherd serves for this pane's browser:

```
ws://127.0.0.1:${SHEPHERD_BROWSER_PORT:-9333}/herdr/<session>/pane/<HERDR_PANE_ID>
```

`<session>` is the herdr session the pane is in. It is `default` unless herdr was started with `--session`, and it comes from `HERDR_SOCKET_PATH`. Codex passes an MCP server only the environment variables its config names in `env_vars`, so the setup script names all of these.
