# Pane navigation / preview improvements

```
python3 Tests/Terminal/run-usability-tests.py --output /tmp/usability-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

Private HOME/defaults/cache, bounded natural-exit stages, no user files, sockets,
SSH, credentials or vendor calls. Compiles actual production block parsing,
board selection declaration, snapshot/identity models, picker view, native detail
controller, SwiftTerm and shared terminal frame.

- Machines: edit/delete slots stay in place but are visible/enabled only during
  row hover; local machine stays protected; context-menu alternatives and delete
  confirmation remain. Active/Make Active comes last, right aligned.
- Cmd-P: front-window focused-scene menu replaces Print. Search uses existing
  board snapshots, independent of sidebar filters/folded groups. Arrow keys,
  Return, Escape/cancel. Each word matches title/agent/paneID/cwd/location.
  Disconnected rows cannot be selected. On native sheet dismissal revalidate
  machine connection, qualified pane ID and terminal ID against latest snapshot;
  grouped mode selects the current containing tab, then focuses the exact pane.
  Focus is presentation-only, with no attach recreation for an already-open tab.
- Markdown: bounded native heading/inline/list/task/table/fence/quote rendering.
  Document-leading closed YAML `---` / `...` and TOML `+++` frontmatter becomes
  display-only metadata rows, retaining nested/multiline/raw values. Unclosed or
  mid-document markers do not swallow content. Not a complete YAML/TOML evaluator
  or CommonMark implementation. No HTML execution, remote image fetch, template
  expansion or YAML tag/alias evaluation. Original source toggle remains.
- macOS modal: same single preview hosting controller stays on a permanent
  surface above the native split; a placeholder reserves its normal divider slot.
  Expanding makes the surface fill the detail/terminal region, excluding sidebar.
  No terminal/panel reparent or duplicate reader. Normal frame/divider proportion
  and preview source state survive contraction. Clicks on the covered terminal
  land on the modal surface; keyboard focus leaves terminal, Escape contracts,
  close dismisses preview. Native tests repeatedly check actual terminal frame,
  grid, resize callback count, owned PTY, keyboard and pointer hit testing.

Source/tree checks and whole macOS/iOS builds are separate from installed-app,
live SSH or real user keyboard/hover acceptance, which this runner does not claim.
Existing sidebar/preview/machine/session lifecycle tests remain additional gates.
