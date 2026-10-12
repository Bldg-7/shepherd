# Terminal focus-frame regression

## File-click ownership

`run-pointer-tests.py` compiles the production terminal handlers against pinned
SwiftTerm and uses a raw owned kernel PTY plus a never-shown AppKit window.
Recognized file paths/URIs/OSC8 targets are claimed on plain or Cmd mouse-down:
zero remote input bytes, one local preview on release. Drag cancellation, invalid
host/read failure and missing callbacks stay local. Callback ownership is captured
at press; modifier or pane changes cannot redirect a release. Non-file/web clicks
retain the complete remote TUI press/release gesture. No user GUI or SSH server is
operated. Live remote acceptance remains separate.

## Focus frame

```sh
python3 Tests/Terminal/run-frame-tests.py --output /tmp/shepherd-frame-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

Uses the actual `TerminalPaneFrame`, `TerminalHostView` and pinned SwiftTerm
object/module from an existing build. No package download/plugin approval.

The test creates one owned, never-shown AppKit window and one owned kernel PTY
pair (`openpty`), with CLOEXEC descriptors and explicit closure. It never starts a
shell, attaches Herdr, accesses SSH/Keychain, activates a window, or sends user GUI
input. Real `TerminalViewDelegate.sizeChanged` requests are mirrored to this owned
PTY via `TIOCSWINSZ` and verified with `TIOCGWINSZ`.

At 800×480, 520×330 and 1040×600 points:
- The native terminal is inset 7pt on every edge, outside the 2pt stroke band,
  with Group by Tab ON or OFF. Standalone uses the actual AgentTerminalView
  wrapper with a session-only test seam; tab mode uses the same production
  frame, with its parent wiring audited. The inner pane does not double-pad.
- Actual native row/column counts and resize callback/kernel-PTY dimensions agree.
- Focus changes retain the same native view, bounds, grid and resize count.
- The bottom-left first cell of owned status text remains intact.

This checks real SwiftTerm/AppKit geometry and kernel PTY size delivery. It is not
interactive acceptance of the user's installed app or a live Herdr/SSH session.
The production session resize path is unchanged; its existing factory/lifecycle
regressions are run separately. File-link hit testing remains in native terminal
coordinates, not in the outer gutter's coordinates.
