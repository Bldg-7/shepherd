---
name: shepherd-browser
description: "Migration notice for the retired global Shepherd browser skill. Browser resources are now provided only by a new managed Shepherd session."
---

# Use a managed Shepherd session

This legacy global skill cannot grant browser access. Do not install MCP servers,
run npm/npx, derive endpoints from environment variables, reuse another pane's
credentials, or silently remove existing user configuration.

Ask the user to enable **Settings → Experimental Features** in Shepherd, complete
Preparation, and open a new managed Claude Code, Codex or Pi tab. That session supplies
its own bundled skill, guidance and authenticated MCP connection. If preparation reports
a legacy global conflict, have the owner review and remove only their old Shepherd
registration explicitly. Do not replace it with an unauthenticated endpoint.
