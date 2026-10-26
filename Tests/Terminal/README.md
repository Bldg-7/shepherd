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

The test compiles the production row modifier, focus request and terminal view
model, drives a List fixture's activation callback, and checks the actual AppKit
first responder in an owned never-shown window. It covers first selection,
reselection with fresh tokens, split targeting, retained views and refreshes
while another input owns the keyboard. App wiring is source-checked; synthetic
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

An OSC8 target that is an `.html` or `.htm` file is claimed like any other file
target: zero bytes to the PTY, and one open for a double or triple click. In a
pane of This Mac (not of a herdr machine), `TerminalLinkRoute` then hands it to
the window's `openWeb` as a `file://` URL, together with whether ⌘ was held, the
way it hands an HTTP(S) URL; in a pane of an SSH machine or a herdr machine it
still goes to the preview. `run-pointer-tests.py` clicks `report.html`,
`file:///…/Report.HTM#sec` and `report.html:12`, plainly and with ⌘, with one,
two and three presses, and sends each through the app's own `TerminalLinkRoute`
for a pane of This Mac and for a pane elsewhere. `run-web-link-tests.py`
checks:
- the page URLs: the extension in any letter case, a file link's `#fragment`
  kept, a `path:line` link's line dropped, a query or another host left to the
  preview, Korean names kept composed;
- the four pane locations: This Mac, a herdr machine of This Mac, an SSH
  machine, and a herdr machine of an SSH machine;
- the destination table in section 10 of `docs/link-opening-ux.md`: plain
  click or ⌘, In-app Browser on or off, Intel, an agent connected or not, and
  the two notices (In-app Browser unavailable, an agent using it);
- that a file for the default browser goes to the app that opens `https`
  links, with a stand-in opener (nothing is actually opened);
- by reading the source, that `openWeb` asks whether an agent is connected only
  about the browser the file would open in, and that an agent connecting to a
  pane's browser empties its `file:` tabs before the agent is given control of
  its pages.

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

  Each Ctrl+B press, and ⌃⇧B's `0x02`, is then written to herdr twice; see
  "Ctrl+B and herdr's attach" below.

The test runs with a private HOME, so the user's own key bindings can't change
the result.

## Ctrl+B and herdr's attach

```sh
python3 Tests/Terminal/run-attach-input-tests.py --output /tmp/shepherd-attach-input-FRESH
```

Each pane's terminal is a `herdr terminal attach`, and herdr's attach client
takes Ctrl+B as its prefix: it holds the key back and waits for the next one, and
q after it ends the attach. So the bytes the terminal view sends go through
`AgentTerminalViewModel.send`, which hands them to `HerdrAttachInput` before
writing them to the attach. `HerdrAttachInput` writes each Ctrl+B press that
herdr would take as its prefix twice, and herdr then passes one Ctrl+B on to the
pane.

Which forms herdr takes as its prefix depends on its version. herdr 0.9.0 and
later take `0x02` and the kitty keyboard protocol's and modifyOtherKeys' forms of
Ctrl+B; older herdr takes only `0x02`. The attach runs on the machine the pane
belongs to, This Mac or an SSH machine, and that machine's `MachineMonitor` runs
herdr commands there. `herdr machine list` exists only from 0.9.0 on, so when
herdr answers it with "unknown command", the monitor notes that this herdr is
older than 0.9.0. The terminal asks the monitor at every write. Until the monitor
knows, and for a pane on a herdr machine, whose version the app can't learn,
herdr is taken to be 0.9.0 or later.

The test uses Foundation only: no herdr, no process, no terminal and no key
presses.

- A table of single writes, for herdr 0.9.0 and later:
  - Written twice: `0x02` (as `0x02 0x02`), and `ESC 0x02`, which some
    terminals send for Alt+Ctrl+B (as `ESC 0x02 0x02`); a kitty press whose key
    code is 98 (b) with Ctrl alone, that is `CSI 98;5u`, also with Caps Lock
    (`CSI 98;69u`) or Num Lock on, with the press event type written out
    (`CSI 98;5:1u`), or with the alternate-key fields that `> 5 u` adds; and
    modifyOtherKeys' `CSI 27;5;98~`.
  - Written as they are: a repeat or a release; Ctrl+B with Shift, Alt or Super
    added (`CSI 98;6u`, `CSI 98;7u` and so on); a press that carries its text; a
    press from a non-Latin layout, whose key code isn't 98 even when its base
    layout key is b (`CSI 1080::98;5u`); and q and other letters.
  - A bracketed paste with `0x02 q` inside it is written as it is.
  - Each row is also run through the model below, to check that what is written
    twice is exactly what herdr 0.9 takes as its prefix.
  - For an older herdr, the same table is checked with only the `0x02` bytes
    written twice.
- A ⌘V paste, which SwiftTerm sends in three writes (the paste's start marker,
  its text and its end marker): the text is written as it is even when it holds
  `0x02`, and a Ctrl+B after the end marker is written twice again.
- A model of herdr's attach client, ported from herdr's source. For 0.9.0, 0.9.1
  and master: the stdin framer (`src/raw_input.rs`), `filter_input`
  (`src/client/attach.rs`, lines 57–146) and the key parser
  (`src/input/parse.rs`). For 0.5.12 to 0.8.2: the byte loop in
  `src/client/mod.rs`. The test types key sequences such as Ctrl+B then q into
  the model:
  - Without `HerdrAttachInput`, Ctrl+B then q ends the attach, as it did in the
    app. On 0.9 the same happens when that Ctrl+B comes in its kitty, Caps Lock,
    modifyOtherKeys or `ESC 0x02` form.
  - With `HerdrAttachInput`, no key sequence ends the attach on either version,
    and the pane gets exactly the bytes the view sent, whether herdr reads them
    all at once or one byte at a time.
  - One limit of herdr 0.8.2 remains, and the test checks it: `0x02 q` inside a
    paste still ends the attach.
  - The test also shows why the version matters. If the writes meant for 0.8.2
    went to herdr 0.9, a kitty Ctrl+B followed by q would still end the attach.
    If the writes meant for 0.9 went to herdr 0.8.2, a kitty Ctrl+B would reach
    the pane twice.

The model is a port, not herdr itself. When herdr is updated, compare its
`attach.rs` and `parse.rs` with the model.

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
  the app's `PaneTerminalView` wraps it: the drop reaches the terminal view;
  taking the drop handler away unregisters its pasteboard type; and clicks on
  the border still reach the terminal. `ImageRenderer` draws the border: accent
  color at the edge, nothing inside.
- Source checks:
  - the sidebar's pane rows and tab rows use the modifier;
  - a pane's terminal takes the drop whenever its attach is connected, whatever
    the Terminal File Drop setting, and shows the border;
  - with Group by Tab on, each pane is attached through the same view;
  - the marker type is declared for this process only, so no other app can
    read it or send it;
  - the ID is written to the pasteboard as data, not as an `NSString`.

Not covered: a real mouse drag, the system's drag pasteboard, real drops from
other apps (the test only marks a drag as coming from one), and the installed
app.

## Reordering the sidebar's groups

```sh
python3 Tests/Terminal/run-board-group-order-tests.py --output /tmp/shepherd-group-order-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

(`FRESH` stands for a new folder name of your choice, as in the other runners.)
One test program (`BoardGroupOrderTests.swift`), built with the pinned SwiftTerm,
then source checks. It uses never-shown windows, named pasteboards of its own
(not the general one) for the row drag it compares against, and a kernel PTY it
opens itself. It starts no real drag session, and doesn't touch the user's
pasteboard or defaults, herdr, SSH or the installed app.

- The rules (`BoardGroupOrder`, `BoardGroupFolding`):
  - The order is kept as one group ID per line. Groups in the kept order come
    first, in that order. The others follow in herdr's order, the host's own
    first. IDs of groups that are gone are ignored.
  - A header let go at a given height goes into the gap above the first header
    whose middle is below it.
  - When a search hides some groups, a group moves only among the shown ones:
    moved up, it goes right before the shown group just below the line; moved
    down, right after the shown group just above the line. Hidden groups keep
    their places.
  - While a header is dragged, no group lists its rows, whatever the search or
    the groups the person folded. The saved folding (which groups the person
    folded) is not written during a drag, and a header click changes it only
    when no drag is going on.
- The drag (`BoardGroupDrag`), with AppKit views standing in for the list and
  its headers:
  - The first move starts it. The line goes between the two headers the group
    would go between, and isn't drawn over the group's own place or outside the
    list.
  - The headers' positions are read from AppKit views, so after the list moves
    a header, its new position is used.
  - Let go inside the list, the group moves to the line. Let go outside the
    list, over the group's own place or outside the window, nothing moves.
    Escape also moves nothing, and the rest of that drag is ignored.
  - When the mouse button comes up and the gesture hasn't ended the drag, the
    drag ends shortly after. A mouse button going down ends a drag still open
    at once.
  - After a drop the groups change in three steps: first the order changes
    while every group still shows only its header; then every group but the
    last unfolds as it was; then the last one does.
- The board: the production header drag and insertion line, in a sidebar List
  laid out as `AgentBoardView`'s, beside the production terminal view. The test
  calls the drag as the gesture's `onChanged` and `onEnded` would. It checks:
  - every group shows its header alone while a header is dragged, and its rows
    again after a drop, Escape, or the mouse coming up or going down;
  - the saved folding is never written by a drag;
  - the selected row stays selected, and ↓ and ↑ follow the new order;
  - a header let go over the terminal changes no order and writes zero bytes to
    the PTY, so no group name is pasted; a row dragged onto the terminal still
    pastes its ID;
  - headers give the List nothing to drag, and rows still do;
  - a group herdr adds goes last, and one that is gone is left out the next time
    the order is kept.

  The run fails if the system log shows SwiftUI's "Modifying state during view
  update", AppKit's `layoutSubtreeIfNeeded` warning or its reentrant table view
  warning.
- Source checks (reading the source files): the order is kept per host under
  `AgentBoardView.groupOrder.<machine id>`; the host and the herdr machines are
  listed in one `ForEach` in that order; both kinds of header use the drag; a
  header click saves the folding only when no drag is going on; rows still use
  `herdrItemDrag` (the row drag of SHPHRD-94), and nothing of the header drag
  uses a pasteboard; Escape is consumed by the drag's event monitor; the iOS
  app's board is unchanged.

Not covered: a real mouse or trackpad drag (SwiftUI takes no clicks or gestures
in a never-shown window), that Escape pressed during a drag doesn't reach the
terminal that has the keyboard (the test's windows never become the key
window), and the installed app.

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
update" or AppKit's `layoutSubtreeIfNeeded` warning. Source checks: the board has
no rename dialog, Cmd-W is ignored while renaming, the field's text is set only
when the field is made, and Return and Escape are handled only when nothing is
being composed. The source checks also look for three things in the code. The
flexible space after the field is there only while the field is up. The field
uses its own cell. A double-click on the title renames what Cmd-W would close,
and does so only while no name is being typed and no sheet is over the window.
A physical keyboard, physical input method, real window-resize gestures, full
screen and the installed app are not covered. Nor is what the system does with
a double-click in the title bar, because a never-shown window neither zooms nor
minimizes.

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
