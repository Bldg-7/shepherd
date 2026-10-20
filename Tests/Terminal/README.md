# Terminal focus-frame regression

## File-click ownership

`run-pointer-tests.py` compiles the production terminal handlers against pinned
SwiftTerm and uses a raw owned kernel PTY plus a never-shown AppKit window.
OSC8 file targets are claimed on plain or Cmd mouse-down: zero remote input
bytes, one local preview on release. Plain-text paths, source locations and
`file://` URIs are not links: with or without Cmd they stay TUI input. Drag cancellation, invalid
host/read failure and missing callbacks stay local. Callback ownership is captured
at press; modifier or pane changes cannot redirect a release. HTTP(S) URLs (implicit text or OSC8) are claimed the same way and dispatched,
with ⌘ as held at release and the click's place, to the window, which opens them in
the clicked pane's In-app Browser or the Mac's default browser as the Open links
in setting says (`run-web-link-tests.py`), never a remote opener. Invalid URLs and
stale ownership never fall back or auto-enable browsing. URL validation rejects
credentials, control characters and unsupported schemes.
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

## Renaming in the title

```sh
python3 Tests/Terminal/run-title-rename-tests.py --output /tmp/shepherd-title-rename-FRESH
```

Needs no SwiftTerm build. It has three stages.

- Model: the rules, without views. A rename starts with the current name, and
  the automatic title as grey placeholder. Names are trimmed. An empty tab name
  is refused. An empty pane name removes the name given to the pane, so it shows
  its automatic title again. An unchanged name is not sent. Panes with the same
  ID on different herdr machines are kept apart. The title shows the typed name
  right after Return, until herdr's own snapshot shows it too or the rename
  fails.
- Field: the production title field in a never-shown window. It takes the
  keyboard with the name selected and gives it back afterwards. While a syllable
  is being composed, Return and Escape go to the input method. Once the syllable
  is committed, Return submits the whole name, that syllable included.
  Redrawing the board during composition keeps the same field, text and
  composition. On an empty tab name Return is refused and editing goes on.
  Losing the keyboard, or the field going away, saves the name typed so far
  (an empty tab name is dropped), once, on the next turn of the run loop.
  The insertion point, the text and the grey placeholder start 12pt in from
  the field's left edge. AppKit alone puts them 6pt in, against the rounded
  end.
- Toolbar: the production split views in a never-shown window. It checks that
  the window's title is the selected terminal view's title, also while a file
  preview is open. While renaming, the title is hidden and the field takes its
  place, before the other toolbar items, and gets the keyboard. The buttons
  after the field stay exactly where they were, and the field sits on their
  line, no taller than they are. After Return the title and the buttons come
  back as they were.
- Title double-click, in the toolbar stage: the watcher in
  `TitleDoubleClick.swift`, on the same window. A double-click on the title's
  text starts a rename, as the row's Rename item does, with the name selected.
  The watcher keeps the second mouse press and the release after it from
  AppKit, so the window is not zoomed. AppKit still gets these clicks
  unchanged:
  - a single click on the title
  - a double-click elsewhere in the bar, or just past the title's text
  - a double-click on the title while nothing can be renamed
  - a double-click on the field while it is up

The field and toolbar stages also read the system log
(`OS_ACTIVITY_DT_MODE=1`) and fail on SwiftUI's "Modifying state during view
update" or AppKit's `layoutSubtreeIfNeeded` warning. Source checks: the board has
no rename dialog, Cmd-W is ignored while renaming, the field's text is set only
when the field is made, and Return and Escape are handled only when nothing is
being composed. The source checks also look for three things in the code. The
flexible space after the field is there only while the field is up. The field
uses its own cell. A double-click on the title renames what Cmd-W would close,
and does so only while no name is being typed and no sheet is over the window.
A real keyboard, input method, full screen and the installed app are not
covered. Nor is what the system does with a double-click in the title bar,
because a never-shown window neither zooms nor minimizes.

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
