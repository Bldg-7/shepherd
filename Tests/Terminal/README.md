# Terminal focus-frame regression

## Sidebar row activation

```sh
python3 Tests/Terminal/run-board-row-focus-tests.py --output /tmp/shepherd-row-focus-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

macOS pane/tab rows issue an explicit keyboard-focus request on each primary
click, including reselecting the same row. Tabs use their last activated pane,
falling back to herdr's focused pane. The terminal view/attach is retained.
Search edits and metadata refreshes do not issue requests; context menus and
row dragging keep their native behavior. Clicking a row also ends title editing
and moves an expanded preview back beside the terminal.

The test compiles the production row modifier and terminal view, makes focus
requests as the pane does (a fresh one each time), drives a List fixture's
activation callback, and checks the actual AppKit first responder in an owned
never-shown window. It covers first selection,
reselection with fresh tokens, split targeting, retained views and refreshes
while another input owns the keyboard. App wiring (`HcWorkspaceView`) is
source-checked; synthetic
mouse delivery in an inactive test app is not a live click test. Manually check
single/repeated row clicks, drag cancellation and context menus in the running
macOS app. No herdr/SSH session or user-window input is used.

## Sidebar selection appearance

```sh
python3 Tests/Terminal/run-board-selection-style-tests.py --output /tmp/shepherd-selection-style-FRESH
```

Selected pane/tab rows retain AppKit's native emphasized (focused) selection
appearance even when the terminal or another input owns the keyboard. A scoped
row anchor observes native emphasis changes and restores the last native value
when deselected, detached or reused. It does not replace the List delegate,
change first responder, pretend the window is active, or hard-code colors.
Group headers and other lists are unchanged; seen/notification state continues
to use the real window activity.

Tests cover native light/dark/high-contrast appearances, focus-loss writes,
restoration and teardown, and production modifier hosting in a real SwiftUI List
through pane/tab selection, metadata changes, reorder and deselection. Cached
native row pixels are compared with keyboard focus in the sidebar and in a
terminal stand-in. Removing persistent observation fails the focus-loss check.
The tests use an owned never-shown window. The existing row-activation fixture also includes
the styling modifier so terminal focus hand-off is checked with both present.

## File-click ownership

`run-pointer-tests.py` compiles the production terminal handlers against pinned
SwiftTerm and uses a raw owned kernel PTY plus a never-shown AppKit window.
OSC8 file targets are claimed on plain or Cmd mouse-down: zero remote input
bytes, one local preview on release. Plain-text paths, source locations and
`file://` URIs are not links: with or without Cmd they stay TUI input. Drag cancellation, invalid
host/read failure and missing callbacks stay local. Callback ownership is captured
at press; modifier or pane changes cannot redirect a release.
HTTP(S) URLs, plain text or OSC8, are claimed the same way. On release the view
hands the URL, and whether ⌘ was held at that moment, to the pane, which opens
it in the Mac's default browser (`run-web-link-tests.py`); nothing opens it on
the remote machine. A double or triple click on a link opens it once, with mouse reporting
off or on. Its second and third presses are claimed too, even if they land off
the link; they open nothing and send zero bytes. The next single click still
goes to the TUI. A double click on a word still selects it with mouse reporting
off, and still goes to the program with it on. Invalid URLs and
stale ownership never fall back or auto-enable browsing. URL validation rejects
credentials, control characters and unsupported schemes.

An OSC8 target that is an `.html` or `.htm` file is claimed like any other file
target: zero bytes to the PTY, and one open for a double or triple click. In a
pane of This Mac, `TerminalLinkRoute` then makes it a `file://` URL for the
default browser, the way it hands on an HTTP(S) URL; in a pane of an SSH
machine it still goes to the preview. `run-pointer-tests.py` clicks `report.html`,
`file:///…/Report.HTM#sec` and `report.html:12`, plainly and with ⌘, with one,
two and three presses, and sends each through the app's own `TerminalLinkRoute`
for a pane of This Mac and for a pane elsewhere. `run-web-link-tests.py`
checks:
- the page URLs: the extension in any letter case, a file link's `#fragment`
  kept, a `path:line` link's line dropped, a query or another host left to the
  preview, Korean names kept composed;
- the routes, as the terminal pane asks for them: from a pane that opens
  pages (This Mac) and from one that doesn't (an SSH machine);
- the destination table of `LinkDestinationPolicy`, as in section 10 of
  `docs/link-opening-ux.md`: plain click or ⌘, In-app Browser on or off,
  Intel, an agent connected or not, and the two notices;
- by reading the source, that the terminal pane (`HcTerminalPane`) routes a
  click with `TerminalLinkRoute`, opening pages only on This Mac, and sends a
  page to the app that opens `https` links rather than to what opens `.html`.

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
- The terminal pane (`HcTerminalPane`) passes an attach's output to the view
  through `feedKeepingSelection`; the runner checks this in the source.

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
- Ctrl+B with the protocol off and under `> 1 u`, `> 5 u` and `> 7 u`: plain,
  with Caps Lock, held down, let go, ⌃⌥B and ⌃⇧B. The view sends what SwiftTerm
  sends for each:
  - Ctrl+B: `0x02` with the protocol off, `CSI 98;5u` under it, and
    `CSI 98;69u` with Caps Lock on.
  - Held down and let go: under `> 7 u`, a repeat is `CSI 98;5:2u` and a
    release is `CSI 98;5:3u`. Under the other settings, a repeat is another
    press and a release sends nothing.
  - ⌃⌥B: `ESC b` with the protocol off, `CSI 98;7u` under it.
  - ⌃⇧B: `0x02` with the protocol off, `CSI 98;6u` under `> 1 u`, and
    `CSI 98:2;6u` under `> 5 u` and `> 7 u`.

The test runs with a private HOME, so the user's own key bindings can't change
the result.

## Pasting a pane's or tab's ID

```sh
python3 Tests/Terminal/run-item-drop-tests.py --output /tmp/shepherd-item-drop-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

One test program (`ItemDropTests.swift`), built with the pinned SwiftTerm, then
source checks. It uses never-shown windows, pasteboards it creates under names of
its own (`NSPasteboard(name:)`, released at the end) and a kernel PTY it opens
itself. It starts no real drag session and doesn't touch the user's pasteboard,
herdr, SSH or the installed app.

- Drag source. Rows with the production `herdrItemDrag` modifier in a List.
  Showing the list starts no drag. For each row the test asks the List's outline
  view for the row's pasteboard writer, as AppKit does when a drag starts, and
  writes it to an owned pasteboard. The pasteboard then holds the marker type
  `com.bldg-7.shepherd.herdr-item` and the ID as plain text, and no URL type.
  Asking for the writer is what records that row as the row dragged last.
- Rules (`HerdrItemDrag`). A terminal pastes only when both hold: the dropped
  text is the ID of the row dragged last, and that row is on the same herdr
  server as the terminal's pane. The same herdr server means the same Machine
  with the same connection settings, and either the same herdr machine or a
  herdr machine on neither side. Taken: a row on a terminal of its own herdr,
  for a Machine's own herdr, for a herdr machine and for This Mac. Refused: a
  herdr machine's row on a pane of the Machine's own herdr and the reverse, a
  row of another herdr machine, a row of another Machine, and a row of the same
  Machine after its credentials changed. The ID must be 1 to 64 ASCII letters,
  digits, `:`, `_` and `-`; an ID with an escape sequence in it is refused even
  when it matches. Of the drag operations the drag allows, the drop uses the
  first of copy, generic and move; a drag that allows none of them is refused.
- Drop target. The production terminal view (`FocusReportingTerminalView`) with
  the production drop handler. A marked drag from the app writes `w1:p4 ` or
  `w1:t2 ` to the PTY in one write, between the bracketed-paste markers when the
  program has turned bracketed paste on, and the keyboard stays with the view
  that had it. Refused with zero bytes and no border: a drag that the test marks
  as coming from another app, text without the marker type, text other than the
  ID of the row dragged last, empty or missing text, a row of another herdr
  server, an unsafe or too long ID, and a drag that allows none of copy, generic
  and move.
- The border. It is turned on once when a drop becomes possible, not again on
  each move. It is turned off when the drag leaves the terminal, when the drag
  changes to an operation that isn't taken, when the drag ends, when the drop is
  made, and when the terminal stops taking drops during the drag because its
  attach disconnected.
- File drops (Terminal File Drop) still work on the same view. The file handler
  and the ID handler each register only their own pasteboard type.
- The terminal inside an `NSHostingView`, wrapped in `TerminalHostView` the way
  the app's terminal pane wraps it: the drop reaches the terminal view;
  taking the drop handler away unregisters its pasteboard type; and clicks on
  the border still reach the terminal. `ImageRenderer` draws the border: accent
  color at the edge, nothing inside.
- Source checks:
  - the terminal pane (`HcTerminalPane`) gives the view its row drop and shows
    the border; which rows it takes is `HcWorkspaceItemDrag`'s, checked in
    `Tests/HcBackend`;
  - the marker type is declared for this process only, so no other app can
    read it or send it;
  - the ID is written to the pasteboard as data, not as an `NSString`.

Not covered: a real mouse drag, the system's drag pasteboard, real drops from
other apps (the test only marks a drag as coming from one), and the installed
app.

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

Needs no SwiftTerm build. The rename session is a stand-in with what the app's
holds (the starting name, the grey placeholder, whether it names a tab); a tab
name left empty is refused as the workspace view refuses it.

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
- Toolbar: the production split views in never-shown windows. It checks that
  the window's title is the selected terminal view's title, also while a file
  preview is open. While renaming, the title is hidden and the field takes its
  place, before the other toolbar items, and gets the keyboard. The buttons
  after the field stay exactly where they were, and the field sits on their
  line, no taller than they are. A legacy no-seam negative control records
  SwiftUI's original fixed native 280...280 pt range. The production item's
  actual `NSToolbarItem` range is 120...280 pt (not merely the SwiftUI source),
  and the actual field stays 280 pt wide at 1000 pt. It then shrinks within
  that range while attached for 280 pt and 360 pt sidebars, and with the
  sidebar hidden, before expanding back. A separate hidden-sidebar window also
  starts a rename narrow and checks its actual field geometry, native focus and
  selection. The fixture rebuilds layout, verifies an old-window resize seam
  callback cannot cancel a rehosted window's update, and verifies that resizing
  one window cannot alter the other window's item. Synthetic IME composition
  keeps Return with the input method until its marked text commits. After Return
  the title and the buttons come back as they were, and all independent rename
  states clean up.
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
update" or AppKit's `layoutSubtreeIfNeeded` warning. Source checks: the
workspace view (`HcWorkspaceView`) puts the field in the title's place, the
field's text is set only when the field is made, and Return and Escape are
handled only when nothing is being composed. The source checks also look for
three things in the code. The flexible space after the field is there only
while the field is up. The field uses its own cell. A double-click on the title
starts a rename of the current selection, and the watcher does nothing while a
sheet is over the window.
A physical keyboard, physical input method, real window-resize gestures, full
screen and the installed app are not covered. Nor is what the system does with
a double-click in the title bar, because a never-shown window neither zooms nor
minimizes.

## Agent logos in the sidebar

```sh
python3 Tests/Agents/run-agent-logo-tests.py --output /tmp/shepherd-agent-logo-FRESH
```

(`FRESH` stands for a new folder name of your choice, as in the other runners.)
Needs no app, herdr, window or network. The runner builds one test program
(`Tests/Agents/AgentLogoTests.swift`) with `AgentLogo.swift` and ShepherdKit's
agent models, runs it, and then checks the source files:

- Which agents have a logo: herdr's `claude` and `claude-code` get Claude's,
  and `pi` gets Pi's. `codex`, every other agent name herdr knows and the empty
  name get none. `AgentKind.allCases` stays `claude`, `codex`, `pi`.
- The path data: the sha256 of each path's `d` string equals the sha256 of the
  `d` string in the official SVG it was copied from. The parser reads Claude's
  spark as 159 drawing commands and Pi's badge as 24, with the same bounds as
  the SVGs, and rejects a relative or unknown command, an exponent or a missing
  number.
- The drawing: `ImageRenderer` draws each logo at 1x, 2x and 3x, in light and
  dark mode, and on a selected row. Every drawn pixel has the logo's own color
  (#D97757 for Claude; #111111 for Pi, or #F6F6F6 in dark mode). Nothing is
  drawn in the 1 pt margin inside the logo's 12 pt square, the logo keeps its
  proportions, the area it covers is within 5% of its outline's area, and only
  Pi's color differs between light and dark.
- The row: measured in an `NSHostingView` that is in no window, a pane row
  with a logo is as tall as one that shows the name in words.
- Source checks: the pane row's second line is `AgentPaneCaption`; a search
  still goes by the agent's name; the logo is one accessibility element read
  as "Claude Code" or "Pi", shows that name as its tooltip, and is never
  tinted; the iOS app and ShepherdKit don't use the logos; the macOS
  third-party notices have the trademark section.

Not covered: the real sidebar, VoiceOver and the tooltip on screen.

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
- The native terminal is inset 7pt on every edge, outside the 2pt stroke band.
  The source check confirms that the terminal pane (`HcTerminalPane`) is the
  frame's one production user and wraps its content in it once, so the inner
  pane does not double-pad.
- Actual native row/column counts and resize callback/kernel-PTY dimensions agree.
- Focus changes retain the same native view, bounds, grid and resize count.
- The bottom-left first cell of owned status text remains intact.

This checks real SwiftTerm/AppKit geometry and kernel PTY size delivery. It is not
interactive acceptance of the user's installed app or a live Herdr/SSH session.
The production session resize path is unchanged; its existing factory/lifecycle
regressions are run separately. File-link hit testing remains in native terminal
coordinates, not in the outer gutter's coordinates.
