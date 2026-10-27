# File preview

```sh
python3 Tests/FilePreview/run-tests.py --output /tmp/shepherd-preview-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

Requires Xcode/Swift 6 and a fresh output directory. Without the optional products
path the actual SwiftTerm tests are skipped. The products must come from the
project's pinned SwiftTerm build; the runner never downloads packages, approves
plugins, accesses user Keychain items, or connects to SSH servers.

Coverage:
- Actual owned files: path/source-location parsing, URL decoding/host validation,
  size limits, FIFO/directory/binary rejection, cancellation,
  native Markdown block layout and width-based iPad policy.
- Production SFTP reader compiled with an **explicit in-memory Citadel module**:
  read-only flags, pinned endpoint, no shell-command API, bounded chunk reads,
  non-regular/oversized files, cancellation and late acquisition compensation.
- Actual model and MachineStore with in-memory secrets/SSH and a pane-value seam:
  no local credential lookup, missing/refreshed pin, stale endpoint/epoch denial,
  cancellation and the actual 15-second read timeout/connection cleanup.
- Actual SwiftTerm objects with owned windowless AppKit views: screen cells,
  Korean wide characters, soft wraps, OSC8 file links vs plain paths that open
  nothing, BiDi fallback denial, prose run on after a path or URL and current
  coordinator callback. **Not GUI click automation.**
- Pane previews: the actual per-pane store with the actual pane and tab models,
  and the actual panel in an owned never-shown window. Selecting pane P, then Q,
  then P again keeps each pane's loaded file, source choice and scroll place
  without reading the file again, and never carries one pane's scroll place to
  another pane's file. A preview closed and shown again reads its file again.
  Selecting a pane again opens no SSH connection and reads no Keychain item, and
  a read that was cancelled when its pane was left starts again when the pane is
  selected again. The window's log has no SwiftUI "Modifying state during view
  update" warning.
- Markdown table of contents. The markdown stage of
  `Tests/Terminal/run-usability-tests.py` checks which headings are listed:
  H1–H6, both `#` headings and headings underlined with `===` or `---`, named
  by their text without Markdown; none from fenced code and none whose text is
  empty. It also checks that each heading has the line number the source view
  shows it on, also after a BOM, CRLF line ends, frontmatter, a lone CR or
  U+2028, and which heading is highlighted for a given scroll place. The actual
  panel is checked in an owned never-shown window. The test reads the list and
  presses its accessible viewport trigger and headings through the accessibility
  API, which it turns on for its own process only. It separately checks the
  eight-state view-local presentation policy (pointer state, keyboard focus
  and explicit accessible reveal) and, after an accessibility press opens the production panel, its native AX
  trigger/panel/region frames for trailing placement and visible-region bounds.
  The trigger's public AX contract is one named `AXButton` with a working
  accessible press path; in this containment hierarchy its AX semantic frame
  is region-sized, not a proxy for control pixels. A narrow source contract
  preserves the distinct 32-point child control declaration and separate
  panel/bridge region declaration, while the accepted one-off geometry probe
  recorded the actual post-modifier control layout as 32×32. Those evidence
  layers do not prove a physical hit frame or real VoiceOver behavior. The
  geometry checks disable animations only in their owned root transaction, so
  they measure the nonanimated end state rather than visible-window insertion
  animation timing. This is policy/state and AX/native-geometry coverage, not system-pointer integration: physical
  visible-window hover, trigger-to-panel transfer, leave, and normal-motion
  animation remain manual release checks and are not run here. A long outline
  uses the production `LazyVStack`: the test checks a meaningful initial
  realized subset, then publicly scrolls only the owned outline scroll view to
  verify its last heading is reachable rather than requiring all rows to exist
  in AX simultaneously. Exact top
  navigation uses a scrollable fixture with body below its target heading, so a
  bottom-clamped short document cannot mask a navigation regression. A heading
  pressed comes to the top of the rendering and of the source, and is
  highlighted. A headed Markdown preview starts with its TOC closed; a no-heading Markdown or
  non-Markdown preview has no affordance. Pane and changed-document reload
  checks confirm that reveal state does not stick. The reload scroll fixture
  has an explicitly named derived completion-panel stage that compiles
  inverse-verified copies of the panel, source preview, and panel test with a
  per-panel completion callback. The callback fires only after existing
  semantic-anchor restoration has finished and published its offset; it then
  tests the restored source/rendered anchor before issuing a direct owned
  1500-point clip move. The named derived receipt is not an ordinary full-panel
  product pass. Normal ScrollRestore stages separately compile and hash the
  tracked production panel/source files. The callback and token are test
  infrastructure, not production API or proof of physical wheel/gesture
  behavior. The row-anchor checks below also cover
  mixed-height headings, code blocks and tables rather than only paragraphs of
  one height. Its strings have Korean and Japanese, and nothing of it is written
  to UserDefaults.
- Find (⌘F), in two parts.
  - `FindTests.swift`, a stage of this runner, checks the search without a
    window. Matching ignores case, and a Korean syllable stored as one composed
    character (NFC) matches the same syllable stored as separate jamo (NFD), in
    both directions. A rendered Markdown file is searched in its visible text:
    inline Markdown rendered, link targets left out, code, table cells, and
    frontmatter keys and values. The source view is searched line by line. The
    first match is the first at or after the line or block at the top, and next
    and previous wrap around. A match at the very end of the 120,000 characters
    shown is found. The highlights have the right ranges and two colors, and
    link and syntax colors stay under them. The test also lists which keys the
    preview takes.
  - The actual panel in an owned never-shown window, beside a view that stands
    in for the terminal. Keys are sent through the window's
    `performKeyEquivalent`, as AppKit sends ⌘ keys, and the keyboard is moved
    between the views only with `makeFirstResponder`. While the terminal view
    has the keyboard, the preview takes neither ⌘F nor ⌘G. While the preview has
    it, ⌘F opens the find bar with the keyboard in its field. Typing, ⌘G, ⇧⌘G
    and Return move the current match, and the preview scrolls to it, in the
    rendering and in the source. A new search starts from the first block or
    line actually on screen; a row that the lazy stack (SwiftUI's `LazyVStack`)
    laid out but never put on screen is not counted. In the rendering, with
    block 30 (the first match of "deploy") at the top, typing "paragraph 2",
    which matches blocks 2, 20 to 29 and 200, makes block 200 the current match,
    not block 20. In the source, with line 181 at the top, typing "paragraph 9"
    selects line 183, already in view, without scrolling. After a search finds
    nothing further down, wraps around to the start and brings line 9 to the
    top, typing "paragraph 1" selects line 21, also already in view. The bar
    reads 1 / 4 with a current match, 0 / 6 right after switching to Source (no
    current match yet), and No Results. Esc in the field closes only the bar;
    with the keyboard in the preview, the first Esc closes the bar and the next
    one the preview. Selecting another pane and coming back keeps the search,
    and a new read clears it. A text file is searched in its first 120,000
    characters only. ⌘F does nothing for a file that couldn't be read. The table
    of contents sits below the bar.
  - Clicks: a real click can't be sent to a window that is never shown. The
    test checks instead which part of the window a click position falls in (the
    text, the terminal, the find field, the rest of the find bar) and what a
    click there does with the keyboard. After the test gives the preview the
    keyboard the same way, returning an expanded preview to its place or
    closing the preview gives the keyboard back to the terminal view.
  - The new strings have Korean and Japanese translations. The preview's
    sources use no SwiftUI `keyboardShortcut`: such a shortcut would take ⌘F
    even while the terminal has the keyboard.
- Reload (↻ and ⌘R), in three parts.
  - The actual model and MachineStore, with in-memory secrets and SSH. A reload
    keeps the link, the Source choice, the scroll place, the table of contents
    switch and the find bar's search. When the text changed, the find bar has
    no current match; a file read the same as before is not written to the
    model again and keeps its current match. A link to a line opens the file
    in Source the first time the file is shown, also when that is a Retry
    after the first read failed; a reload doesn't switch to Source again. A
    deleted file, a file over 4 MiB, a directory and
    a pane on a herdr machine fail as on a first read, and the model keeps how
    the file was looked at for the next read that works. While a remote file
    is read again, the old text stays and the model marks it as being read
    again; a preview that had failed shows Reading File… instead. When the
    pane is left during a remote reload, the reload is cancelled: its
    connection is closed and the old text stays. When the pane is selected
    again, the reload is made again, once. The same holds for a reload started
    from a failed preview. A late reload doesn't override a newer read of another
    file. Each remote reload makes one SSH connection, reads the Keychain once
    and checks the pinned host key; a local reload reads no credential.
  - The actual panel in an owned never-shown window, beside a view that stands
    in for the terminal, read and pressed through the accessibility API. The
    button is named Reload, its help is Reload (⌘R), and it is enabled after
    a read ends, whether the read worked or failed. It remains left of Expand on Markdown, other text files and images. Reloaded at 900 points, the new text is in the same scroll
    view at 900 points, and a new heading is listed in the table of contents.
    A preview brought back to 900 points by selecting its pane again, then
    scrolled to 1,500 points and reloaded, stays at 1,500. A source view opened from a link to
    line 40 and scrolled away stays where it was, the line still highlighted;
    read again shorter, it stops at its end. A changed Markdown document starts with its TOC closed. The find bar stays open with its search and the keyboard in its
    field, and its count goes from five matches to 0 / 6 (no current match,
    six matches). With the file
    deleted, Reload shows Cannot Preview File with Retry; with the file back,
    Retry shows it in Source at the same place. ⌘R sent through the window's
    `performKeyEquivalent` is not taken while the terminal view has the
    keyboard, and nothing is read. While the preview or its find field has the
    keyboard, ⌘R reads, from the failed screen too, and three ⌘R presses in a
    row leave the file shown once, at its place. An image keeps its horizontal
    and vertical scroll place.
  - `FindTests.swift` checks that ⌘R, with or without Caps Lock, is the
    preview's, and that ⇧⌘R, ⌥⌘R, a bare r and a key-up are not. Static checks:
    ⌘R is among the keys `PreviewKeyCatcher` takes; there is no SwiftUI
    `keyboardShortcut`; only the close button is Liquid Glass; the button is
    disabled while the file is read; only a new read, not a reload, clears the
    find bar; and the strings "Reload" and "Reload (⌘R)" have Korean and
    Japanese translations.

## Product behavior

File OSC8 links (for example from `ls --hyperlink`) use plain click or Cmd-click
for hrdrhrdrhrdr preview. Plain text is never a file link, even when it looks like a
path, a source location (`path:line:column`), `~/…` or a `file://` URI: its click
is TUI input like any other text, with or without Cmd. File intent is claimed at
mouse-down before any remote input. HTTP(S) links, plain text or OSC8, are also
claimed at mouse-down. A plain click opens one in a new tab of the clicked
pane's In-app Browser, and a ⌘-click opens it in the Mac's default browser; a
double or triple click opens it once. Clicks off a link remain TUI input, and
releasing them opens no preview. With In-app Browser OFF, links open in the
default browser. With In-app Browser on but unable to run on this Mac, links
also open in the default browser, and a notice says why. An invalid web URL
shows the Could Not Open Link alert on the Mac; it is not sent to the remote
machine, and In-app Browser is not turned on for it. Localhost URLs resolve on this Mac;
opening a URL does not create an SSH tunnel or remote browser-agent grant.
iOS recognizes file touches at began and owns the full gesture before native TUI
recognizers can emit a tap/drag. Non-file gestures remain native TUI behavior. Markdown file links stay in the same preview and
resolve against the displayed file's parent directory. Relative OSC8 file links
resolve against the clicked pane's reported cwd, not the app's cwd.

macOS: the preview and the browser share one side-panel column. Each pane, or
each tab with Group by Tab on, keeps its own preview while another one is
selected. Selecting it again shows the same file, already loaded, in the same
source or rendered view and at the same scroll place. Closing the preview and
showing it again with the toolbar's Show Preview reads the file again, starting
over in the rendered view at the top. Reload, ⌘R and Retry read it again too,
keeping how it is looked at (see Reload below). A shown preview covers the
browser column in its own pane only; other panes show the browser column if Show
Browser is on. Choosing Show Browser in a pane that shows a preview closes the
preview but keeps its file, so Show Preview can bring it back. Switching between
the preview and the browser hides the browser region, not the browser feature or
its tabs/profiles/agent connection. Moving to another pane or tab while the
preview is expanded ends the expansion. Previews stay through a machine switch.
A pane's preview is dropped when a herdr that answered no longer lists the pane,
or when the pane's Machine is removed or edited to connect differently. Files
and file contents are window-local memory state, not SceneStorage or global
shared state.

iPhone: Navigation push. iPad: a detail-area width of 760 points or greater
shows terminal + preview; narrower windows push the preview alone. Resize uses
actual detail width, not an orientation assumption. Back/Close dismisses preview.

Markdown is native and intentionally a basic renderer: headings, inline
emphasis/links, fenced code, quotes and bullets. Fences use their language label
for native lexical highlighting and wrap to the panel width. Tables/nested
lists/ full CommonMark fidelity are not promised. Source mode is available;
source line links open that mode and highlight the line. Text must be UTF-8 and
rendering stops at 120,000 characters with a visible notice. Maximum file size
is 4 MiB. Common bitmap images use an ImageIO thumbnail (first frame, max
2048px); metadata is capped at 16 MP and 16,000 pixels per dimension before
decoding. HTML/SVG are inert source; there is no WebView, script execution,
remote image fetch or external URL launch. A terminal link to an `.html` or
`.htm` file in a pane of This Mac (not of a herdr machine) no longer reaches the
preview: it opens in a browser, as an HTTP(S) link does (see
`Tests/Terminal/README.md`). HTML files in panes of SSH machines and herdr
machines, links to HTML files clicked inside a preview, and `.xhtml`/`.svg`
files still open in the preview as inert source.

A Markdown file with headings has a table-of-contents affordance inside the upper-right of its preview viewport, in rendered and Source modes and whether expanded or not. Hovering the affordance reveals a bounded Liquid Glass panel that slides in from the right unless Reduce Motion is on. Its hover region includes both the affordance and panel, so the pointer can move between them without a gap; leaving that combined region closes it. The affordance is also named for VoiceOver and can reveal the panel with keyboard focus; Esc leaves the TOC only while it has that focus. A changed document or pane change starts closed. A Markdown file with no headings, and non-Markdown previews, have no TOC affordance. The panel is half the preview width, from 160 to 260 points, and no taller than the viewport below the affordance; a longer list scrolls inside it without resizing the preview or changing its scroll place. Clicking a heading brings its block in rendering, or its line in Source, to the top. The current heading remains highlighted and the list follows it.

Find. ⌘F belongs to the preview only while the preview has the keyboard. A click
anywhere in the preview gives it the keyboard, beside the terminal as well as
expanded; before, only an expanded preview had it. After such a click, typing
goes to the preview until the terminal is clicked, and ⌘F while the terminal has
the keyboard is the terminal's. ⌘F opens a find bar at the top of the preview,
above the text. The bar is a Liquid Glass capsule like the sidebar's Filter, and
the table of contents sits below it. The keyboard goes to the bar's field, with
the last search, if any, selected in it. Matching ignores case; there are no
options such as whole words. A Korean syllable matches whether it is stored
composed or as separate jamo. A rendered Markdown file is searched in its
visible text, without `**` or link targets but with code, tables and
frontmatter. Source and other text files are searched line by line as written,
within the 120,000 characters shown. The bar finds as you type and goes to the
first match at or after the top of the view. Return, ⌘G or the down arrow button
goes to the next match; ⇧Return, ⇧⌘G or the up arrow button to the previous one,
wrapping around at either end. While the bar is closed, ⌘G or ⇧⌘G opens it and
moves to the next or previous match; if no search has been typed yet, it only
opens the bar, as ⌘F does. Every match has a light yellow background and the
current one an orange one. The bar shows 3 / 17, or 0 / 17 while no match is
current yet, or No Results. The current match's line in Source, or its block in
the rendering, comes to the top unless it is already fully in view; in a block
or line too long to fit, the preview scrolls to about where the match is.
Switching between the rendering and Source keeps the search, with no current
match until the next ⌘G or Return. Esc or the close button closes the bar and
removes the highlights, keeping the search for the next ⌘F. With the bar closed
and the keyboard in the preview, Esc returns an expanded preview to its place,
or closes one beside the terminal. Closing the preview, or returning an expanded
one to its place, gives the keyboard back to the terminal that had it. Each
pane's preview keeps its bar, search and current match while another pane is
selected; opening a file starts them over, and Reload, ⌘R and Retry keep them.
Not included: Find menu items in the Edit menu, Use Selection for Find (⌘E), the
find text shared with other apps, replace, regular expressions, and find in the
In-app Browser.

Reload. The preview's header has a Reload button (`arrow.clockwise`), a plain
borderless icon like Expand and the In-app Browser's Reload. It stays left of
Expand for Markdown, other files, images and failed previews. Its help is
Reload (⌘R). The
button, ⌘R and Retry read the same file again from the same machine and path:
a remote file over a new SFTP connection with the saved credential (one
Keychain read) and the pinned host key; a pane on a herdr machine gets the same
error as before. ⌘R belongs to the preview only while the preview has the
keyboard, its find field included; while the terminal has the keyboard, ⌘R is
the terminal's. There is no menu item. While a shown file is read again, it
stays on screen with its header buttons and find bar, and a small spinner
takes the button's place. While a first read, or a read after a failure, is
under way, Reading File… is shown instead. The button is disabled while the
file is being read, so pressing it or ⌘R again starts no second read. If the
file's contents haven't changed, nothing on screen changes. Otherwise the new text replaces the old in the
same scroll view, which keeps its place, or stops at the end when the text is
now shorter. The rendering or Source stays chosen. A link's line stays
highlighted with its Line N, but the preview doesn't scroll back to it. A
changed Markdown document starts with its TOC closed and can reveal its new
headings. The find bar stays open with its search, its matches counted in the
new text, with no
current match until the next ⌘G or Return. A text selection in the preview may
be cleared when the text changes. An image keeps its horizontal and vertical
scroll place and is drawn again. A
read that fails (the file deleted, no permission, over 4 MiB, not UTF-8, or
over 15 seconds) shows Cannot Preview File with the reason and Retry, and keeps
how the file was looked at: the next read that works shows it in the same view
and, as when its pane is selected again, at the place it was left. Selecting
another pane while the file is read again cancels the read (a remote read's
connection is closed) and keeps the old text; selecting the pane again makes
that read again. Opening another file, closing the preview or choosing Show
Browser while the file is read drops the read, as before. The preview never
reads a file again on its own, and selecting its pane again doesn't read it
again.

Returning to a pane, or showing it after Retry succeeds, restores the first
visible Markdown block or source line and the distance into that row. Lazy
stacks' estimates of off-screen heights no longer determine the restored place.
If the width changed while the pane was away, the same row is restored and a
positive distance into it scales with its new height; spacing above a row stays
in points. A missing row falls back to the saved point, clamped by the scroll
view. New files and the Source toggle start at the top; images still keep both
point coordinates. Reload in an existing scroll view keeps its current behavior.

The initial correction is hidden while layout settles (normally a few frames,
with a 40-frame bound of about 0.7 seconds). A new table-of-contents or find
request, or the start of a user scroll gesture, stops the correction. Resizing
while the preview remains visible is not covered by this restoration policy
(SHPHRD-116).

`ScrollRestoreTests.swift` exercises mixed-height Markdown, wrapped source,
places inside tables and tall code blocks, pane switches, width changes while
away, Retry including a shortened file, and explicit navigation during restore
in an owned, never-shown window. It checks the saved row against reported visible
rows, distance within one point, and subsequent anchor updates. It also tests
row geometry, gap preservation, and suppression of intermediate saves. The model
and pane-store tests cover anchor retention and reset. Real user wheel/touch
interruption and visual flashing still need manual checks; the window tests do
not synthesize user input.

Only the clicked Machine is accessed. Localhost in a file URI denotes that source
machine. Other URI hosts must match the configured hostname (or known local Mac
host aliases); they never redirect the reader. Nested Herdr machine filesystem
routing is explicitly unsupported. Unknown cwd requires an absolute path; ~/ and
shell variables are not expanded. Unsupported URI schemes are not dispatched.
Hangul, Han or kana glued to the last letter or digit of a plain URL
(`…/pull/16048에서`) ends the link, and a click on it opens nothing. Text after
an OSC8 link is not part of it.

Remote reads use a separate read-only SFTP connection and the existing saved
credential + host-key pin. An unpinned machine must first connect through the
normal terminal flow. There are no shell fallbacks or local-path fallbacks for
remote files. The read deadline closes the owned connection before draining a
pending operation; underlying SSH connect/login timeouts also apply. A late SSH
acquisition after cancellation closes rather than reopening the request.

Actual interactive navigation/resizing/browser-tab preservation and live SSH
acceptance remain separate manual/integration checks, not claimed by this runner.

## Source resize regression

```sh
python3 Tests/FilePreview/run-resize-tests.py --output /tmp/shepherd-resize-FRESH
```

This compiles the actual `SourceFilePreview` and resizes an owned, never-shown
AppKit window hosting it. Short-source document width must follow 800 → 400 →
1200 → 600 → 900 points. Highlighted long lines must wrap without horizontal
overflow at 320/400/500/1000/1200 points; narrowing increases document height and
widening reduces it. No window is ordered or activated and no user GUI input is
sent. There are 17 real SwiftUI/AppKit geometry checks plus lexical/attribute tests.

`--legacy-panel /path/to/saved/FilePreviewPanel.swift` extracts the previous source
renderer and requires this same layout test to fail, preserving its receipt. It
is a negative regression mode, not a passing acceptance run.

Source/code uses automatic wrapping by default. Wrapped fragments retain the
original source line number, and selecting a line highlights the entire row.
There is no horizontal source scrollbar and no file reload on resize.

Syntax highlighting is a bounded, native lexical scanner (not compiler/LSP
semantic highlighting). Extensions and fenced-code labels recognize Swift,
Python, JS/TS, JSON, YAML, TOML, shell, C-family, Rust, Go, Ruby and SQL. Keywords,
strings, comments, numbers, common type/function names and object keys receive
light/dark-adapted colors. Unknown languages stay plain. Multiline strings/comments
retain state across source rows, Unicode graphemes remain intact, and attributed
text never gets URL/executable attributes. This is intentionally not a complete
language grammar; templates/raw literals/preprocessor semantics may be approximate.

## File gesture ownership

`Tests/Terminal/run-pointer-tests.py` uses the real SwiftTerm view with mouse
reporting/SGR enabled and a raw owned kernel PTY. Captured file press/drag/release
must deliver zero PTY bytes with or without Cmd; non-file clicks must deliver a
complete mouse gesture. OSC8 file URIs, paths and source locations, plain paths,
source locations and file URIs that stay TUI input with or without Cmd, missing
preview callbacks, drag cancellation, preview failure and
owner-callback capture at press are covered. No user window or SSH server is used.
The iOS recognition adapter is separately compiled by the full iOS app build;
live iOS touch competition remains an interactive acceptance check.

Once claimed, failed reads, invalid URI hosts, deleted panes or changed connections
never replay a click to the remote TUI or invoke `open`, `xdg-open` or an editor.
Machine/pane/cwd and existing SFTP pin/credential policy remain authoritative, not
URI host or a new pane under the pointer at release. No local filesystem fallback.

Tokenization runs off the main actor and is cached per text/language, so resize
and color-scheme changes do not re-tokenize. The existing 120,000-character render
budget remains. No grammar packages, shell commands, WebView or downloads are used.
