# Terminal focus-frame regression

## File-click ownership

`run-pointer-tests.py` compiles the production terminal handlers against pinned
SwiftTerm and uses a raw owned kernel PTY plus a never-shown AppKit window.
OSC8 file targets are claimed on plain or Cmd mouse-down: zero remote input
bytes, one local preview on release. Plain-text paths, source locations and
`file://` URIs are not links: with or without Cmd they stay TUI input. Drag cancellation, invalid
host/read failure and missing callbacks stay local. Callback ownership is captured
at press; modifier or pane changes cannot redirect a release.
HTTP(S) URLs, plain text or OSC8, are claimed the same way. On release the view
hands the URL, and whether ⌘ was held at that moment, to the window: a plain
click opens it in the clicked pane's In-app Browser, a ⌘-click in the Mac's
default browser (`run-web-link-tests.py`), and nothing opens it on the remote
machine. A double or triple click on a link opens it once, with mouse reporting
off or on. Its second and third presses are claimed too, even if they land off
the link; they open nothing and send zero bytes. The next single click still
goes to the TUI. A double click on a word still selects it with mouse reporting
off, and still goes to the program with it on. Invalid URLs and
stale ownership never fall back or auto-enable browsing. URL validation rejects
credentials, control characters and unsupported schemes.
Non-link clicks retain the complete remote TUI press/release gesture. No user GUI or SSH server is
operated. Live remote acceptance remains separate.

## Selection

```sh
python3 Tests/Terminal/run-selection-tests.py --output /tmp/shepherd-selection-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

The test presses, drags, types and turns the wheel on the production terminal
view (`FocusReportingTerminalView`) in never-shown windows. A kernel PTY that
the test opens itself stands in for the herdr attach, and the test checks what
the view writes to it. It feeds the view what herdr sends: the pane on the
alternate screen, frames wrapped in synchronized-output markers, and, when the
pane's program uses the mouse, the mouse modes that `herdr terminal attach`
turns on. Each case runs twice: with mouse reporting off, as in a shell or
Claude Code, and on, as in Pi or Codex.

- A plain drag selects with mouse reporting off and writes nothing. With it on,
  the drag goes to the program with the same bytes as before and selects nothing.
- ⇧-drag selects with mouse reporting on or off, also when it starts on a web or
  file link, and writes nothing. When the mouse button goes down with ⇧ held,
  the view turns mouse reporting off until that button comes up, even if ⇧ is
  let go during the drag. Reporting is turned back on when the button comes up,
  at the next button press if the button-up never arrived, and when the view
  leaves its window. ⇧-click on a link opens nothing and extends a selection if
  there is one. A ⇧ double click selects a word.
- A program that asked for ⇧ clicks (XTSHIFTESCAPE, `CSI > 1 s`) gets ⇧ presses
  as before, and a ⇧-click on a link opens it.
- A selection stays through frames that change other cells, or that redraw its
  own cells unchanged, and ends when a frame changes the text in it. Changes
  that arrive while it is still being dragged out don't end it. A plain, ⌥ or ⌘
  click, a typed key, a change of size, and a switch between the normal and
  alternate screens end it. The selected text is what ⌘C would copy; the test
  reads it with `getSelection()` and does not touch the pasteboard.
- Plain and ⌘ clicks on links open them once and write nothing, as before. With
  mouse reporting off, a plain drag that starts on a link becomes a selection,
  starting where the button went down, once it has moved more than 8pt; within
  8pt it is still a click that opens the link. With mouse reporting on, and for
  ⌘ and ⌥ drags, a drag that starts on a link selects nothing and opens nothing.
- ⌥-drag, ⌃-click and double clicks do what they did before: SwiftTerm's own
  selection with mouse reporting off, and the same bytes to the program with it
  on.
- The wheel. With mouse reporting off and the alternate screen up, an event
  monitor the view installs turns each line of scrolling into a wheel report at
  the cell under the pointer (`CSI < 64 ; col ; row M` up, `65` down), with ⌥
  and ⌃ added the way SwiftTerm adds them, so that herdr scrolls its scrollback.
  Trackpad scrolling is added up into lines. With mouse reporting on, the same
  events give the same bytes from SwiftTerm itself. While the button of a ⇧
  press is down, the wheel still goes to herdr (or, with mouse reporting on, to
  the program). The monitor leaves the event to SwiftTerm when ⇧ is held, when
  another view is drawn over the terminal, for another window, for a hidden
  terminal, and on the normal screen. A view outside a window has no monitor.
- `AgentTerminalViewModel` passes an attach's output to the view through
  `feedKeepingSelection`. It runs with an in-memory session and a stand-in for
  swift-nio's `ByteBuffer`.

The test makes wheel events from CoreGraphics scroll events and sends them
through `NSApp.sendEvent`, which hands them to local event monitors. AppKit has
no public way to make a scroll event for a given window, so the test sets the
target window through CGEvent field 51 (the field AppKit reads the window number
from) and the position in that window through the private
`CGEventSetWindowLocation`, looked up at run time. The app uses neither. A real
mouse or trackpad, the pasteboard, herdr and the installed app are not covered.

## Keys

```sh
python3 Tests/Terminal/run-key-tests.py --output /tmp/shepherd-keys-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

The test presses keys on the production terminal view (`FocusReportingTerminalView`)
in never-shown windows and checks the bytes the view passes on, which are what
the pane's program receives. It presses them the way AppKit delivers a key-down:
first it offers the key to the window's views through `performKeyEquivalent`, and
only if no view handles it there does the key go to SwiftTerm's `keyDown`. Byte
strings below are written with CSI for `ESC [`.

- ⌘← and ⌘→ while the program has turned on the kitty keyboard protocol, as Pi
  does: the terminal view handles them in `performKeyEquivalent` and sends the
  same bytes as the Home and End keys, `CSI H` and `CSI F`. The test covers the
  three settings programs ask for, `CSI > 1 u`, `> 5 u` and `> 7 u` (Pi asks for
  7). Under `> 7 u` a key held down repeats as `CSI 1;1:2H` and `CSI 1;1:2F`, as
  Home and End do. With Caps Lock on they send what Home and End send with Caps
  Lock on. Without this change SwiftTerm would send super+← and super+→, which
  Pi ignores.
- ⌘← and ⌘→ while the protocol is off, or after the program turns it off with
  `CSI < u`: still `ESC b` and `ESC f`, as before.
- ⌘⌫ and ⇧⌘⌫: Ctrl-U (0x15), with the protocol on or off, as before.
- Every other key is left to SwiftTerm and sends what SwiftTerm sends for it,
  which for some keys is nothing. The test presses ⇧⌘← and ⇧⌘→, ⌥⌘←, ⌃⌘→, ⌥← and ⌥→,
  ⌃← and ⌃→, ⌘↑, ⌘↓, ⌫, ⌥⌫, ⌘⌦ and the letter a.
- With two terminals in one window, only the one with keyboard focus turns ⌘←
  into Home; when neither has focus, neither does. The same is checked with the
  app's `TerminalHostView` placed inside an `NSHostingView`, as the app's window
  holds it.

The test runs with a private HOME, so the user's own key bindings can't change
the result.

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

## Passing the name on to the agent's session

```sh
python3 Tests/Agents/run-session-naming-tests.py --output /tmp/shepherd-session-naming-FRESH
```

(`FRESH` stands for a new folder name of your choice, as in the other runners.)
Needs no app, herdr, agent or SSH. The runner has three stages (build, the Swift
tests, the Pi tests) and then source checks:

- Swift tests (`Tests/Agents/SessionNamingTests.swift`), compiled with the real
  `HerdrClient`, `TitleRename` and `BoardItem` (the sidebar's row type). They
  check:
  - the `/rename <name>` command;
  - name clean-up: trimming, control characters, line breaks and U+2028 turned
    into spaces, the cut at 200 characters, and nothing sent for an empty name;
  - what a rename registers: nothing for a tab, an empty name or a pane with no
    agent, and a Pi rename going to its launch;
  - the verdicts: idle and done are sent; working, blocked, unknown and
    `launch_pending` are held; a closed pane, or another terminal, agent kind or
    agent session, drops the name;
  - the input box check: Claude's empty prompt and its dim suggestion count as
    empty, a draft or a prompt dialog does not, and the resume check still
    treats a suggestion as text;
  - held names: a newer rename replaces the held one, and the same pane ID on
    another Machine or herdr machine is a different pane;
  - sending, against a fake herdr written in the test: an empty input box gets
    `agent.prompt` exactly once; a draft gets nothing until the box is empty;
    blocked and a failed connection keep the name and send again later;
    `agent_not_found` or another session drops it; two renames send only the
    last name; a herdr machine is reached with `herdr --machine`, and a name
    with quotes in it stays one argument.
- Pi tests (`Tests/AgentBrowser/Phase3/PiIntegrationTests.mjs`):
  `pi-session-name.mjs` sets each sequence number's name once, right away when Pi
  is idle and after `agent_settled` when Pi is working, and sets the name of a
  new number. The same runs through `createPiHost` against a fake bridge socket.
- Source checks: only a rename herdr accepted is passed on, the sidebar passes
  every snapshot to `AgentSessionNamer`, Pi is named through its launch and the
  bridge, and the resource hash in `runtime.mjs` covers `pi-session-name.mjs`.

`Tests/AgentBrowser/Phase3/run-pi-bridge-tests.py` checks the bridge itself:
each launch's `status` replies carry only that launch's latest name, and invalid
names are refused.

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
