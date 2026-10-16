# Pane navigation / preview improvements

```
python3 Tests/Terminal/run-usability-tests.py --output /tmp/usability-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

Private HOME/defaults/cache, bounded natural-exit stages, no user files, sockets,
SSH, credentials or vendor calls. Compiles actual production block parsing,
board selection declaration, snapshot/identity models, picker view, native detail
controller, SwiftTerm and shared terminal frame, and the new tab launcher's text
field.

- Machines: edit/delete slots stay in place but are visible/enabled only during
  row hover; local machine stays protected; context-menu alternatives and delete
  confirmation remain. Active/Make Active comes last, right aligned.
- Single window: the app's scene is one `Window`, with no New Window command;
  closing it leaves the app running. Cmd-N opens the new tab launcher with
  nothing picked, Cmd-T with the herdr and workspace of the selected pane or tab
  picked. The preset comes from existing board snapshots: a nested herdr's
  workspace is never taken for the host's of the same raw ID, a workspace no
  longer listed leaves only the machine picked, and nothing selected or a herdr
  no tab can be opened on falls back to asking from the start.
- Launcher field: the new tab launcher's actual `LauncherField` in a never-shown
  window, driven as a Korean input method drives it: committed text through
  `insertText`, the syllable being composed through `setMarkedText`. The syllable
  being composed stays in the field when a commit starts the next one and when
  the launcher is redrawn. Return submits the whole word. Emptying the field
  mid-word leaves both the field and the launcher's text empty. Only typing
  changes the launcher's text, and the stage log, kept with
  `OS_ACTIVITY_DT_MODE=1`, has no SwiftUI "Modifying state during view update"
  warning. No input method, app or user GUI is involved.
- Cmd-W: the File menu's Close is replaced and never closes the window. Cmd-W
  closes the selected tab (Group by Tab on) or pane (off, or a herdr too old to
  report tabs) after the sidebar's confirmation; Close Window stays, without a
  shortcut. Nothing selected disables it; the launcher, Settings, the pane
  switcher, an alert or an expanded preview over the terminal make it close
  nothing. The board also ignores it while a name is being typed into the
  window's title, and while its own close or failure dialog is up.
- Cmd-P: the window's focused-scene menu replaces Print. Search uses existing
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
