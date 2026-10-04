# shepherd-releases
Shepherd for macOS: releases and the Sparkle update feed

## Agent skill

`skills/shepherd-browser` lets Claude Code and Codex, running in a herdr pane, use the browser Shepherd shows beside that pane. Shepherd installs it from Settings → Agents → Set Up. To install it by hand:

```sh
npx skills add Bldg-7/shepherd --skill shepherd-browser --global
sh ~/.agents/skills/shepherd-browser/scripts/setup.sh
```

The second command registers the skill's `shepherd-browser` MCP server with Claude Code and Codex.
