---
name: shepherd-browser
description: "Migration notice for the retired global Shepherd browser skill. The browser is now the In-app Browser of 3rdr, and only a new session that 3rdr manages provides it."
---

# Use a session managed by 3rdr

This legacy global skill cannot grant browser access. Do not install MCP servers,
run npm/npx, derive endpoints from environment variables, reuse another pane's
credentials, or silently remove existing user configuration.

Ask the user to turn on **Settings → Experimental Features → In-app Browser** in 3rdr,
complete Preparation, and open a new Claude Code, Codex or Pi tab from 3rdr's new tab
launcher. That session supplies its own bundled `3rdr-browser` skill, guidance and
authenticated MCP connection. If Preparation reports a conflict with an old global
registration, ask the user to review that registration and remove only their old
`shepherd-browser` registration themselves. Do not replace it with an unauthenticated endpoint.
