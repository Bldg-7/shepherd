# Terminal focus-frame regression

## File-click ownership

`run-pointer-tests.py` compiles the production terminal handlers against pinned
SwiftTerm and uses a raw owned kernel PTY plus a never-shown AppKit window.
OSC8 file targets are claimed on plain or Cmd mouse-down: zero remote input
bytes, one local preview on release. Plain-text paths, source locations and
`file://` URIs are not links: with or without Cmd they stay TUI input. Drag cancellation, invalid
host/read failure and missing callbacks stay local. Callback ownership is captured
at press; modifier or pane changes cannot redirect a release. HTTP(S) URLs (implicit text or OSC8) are claimed the same way and dispatched to
the clicked pane's Shepherd browser, not a remote opener. Browser OFF/unavailable,
invalid URLs and stale ownership never fall back or auto-enable browsing. URL
validation rejects credentials, control characters and unsupported schemes.
Non-link clicks retain the complete remote TUI press/release gesture. No user GUI or SSH server is
operated. Live remote acceptance remains separate.

## Keys

```sh
python3 Tests/Terminal/run-key-tests.py --output /tmp/shepherd-keys-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

Sends real key-downs through SwiftTerm's `keyDown` into the production terminal
view in a never-shown window, and checks the bytes it hands its delegate. ⌘⌫
and ⇧⌘⌫ send Ctrl-U (0x15), with the kitty keyboard protocol pushed or not.
⌫, ⌥⌫, ⌘←, ⌘→ and a letter send what SwiftTerm sent before. The private HOME
keeps the user's own key bindings out.

## Drawing while hidden

```sh
python3 Tests/Terminal/run-draw-gate-tests.py --output /tmp/shepherd-draw-gate-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

Puts the production terminal view in a never-shown window, which macOS reports
as not visible, and counts SwiftTerm's actual draws. Output fed while the
window can't be seen reaches SwiftTerm's buffer but is not drawn. The test then
tells the view it can be seen again, as the window's visibility notifications
would: it is drawn once in full, and output after that is drawn as usual. The
view's `isHidden` is never set, so it stays first responder and keeps getting
keystrokes throughout. The `TerminalDrawGate` rules that decide visibility (a
covered window, a window on another Space, a minimized window, a hidden app)
are also tested directly, without a window.

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
