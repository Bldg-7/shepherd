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
  presses headings and buttons through the accessibility API, which it turns on
  for its own process only. A heading pressed comes to the top of the rendering
  and of the source, expanded or not, and is highlighted. The header button
  hides the table of contents for one preview only, and a Markdown file opened
  anew starts with it shown. With no headings the button is disabled; a file
  that isn't Markdown has no button. Showing the table of contents doesn't
  change where a pane's scroll place comes back when the pane is selected
  again: within 2 points in the source, and in the rendering of a file whose
  blocks above the scroll place are paragraphs of one height; for a file that
  mixes headings and code blocks, the same place as with it hidden. Its strings
  have Korean and Japanese, and nothing of it is written to UserDefaults.

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
showing it again with the toolbar's Show Preview reads the file again, and so
does Retry. A shown preview covers the browser column in its own pane only;
other panes show the browser column if Show Browser is on. Choosing Show Browser
in a pane that shows a preview closes the preview but keeps its file, so Show
Preview can bring it back. Switching between the preview and the browser hides
the browser region, not the browser feature or its tabs/profiles/agent
connection. Moving to another pane or tab while the preview is expanded ends the
expansion. Previews stay through a machine switch. A pane's preview is dropped
when a herdr that answered no longer lists the pane, or when the pane's Machine
is removed or edited to connect differently. Files and file contents are
window-local memory state, not SceneStorage or global shared state.

iPhone: Navigation push. iPad: a detail-area width of 760 points or greater
shows terminal + preview; narrower windows push the preview alone. Resize uses
actual detail width, not an orientation assumption. Back/Close dismisses preview.

Markdown is native and intentionally a basic renderer: headings, inline
emphasis/links, fenced code, quotes and bullets. Fences use their language label
for native lexical highlighting and wrap to the panel width. Tables/nested lists/
full CommonMark fidelity are not promised. Source mode is available; source line links open that
mode and highlight the line. Text must be UTF-8 and rendering stops at 120,000
characters with a visible notice. Maximum file size is 4 MiB. Common bitmap images
use an ImageIO thumbnail (first frame, max 2048px); metadata is capped at 16 MP
and 16,000 pixels per dimension before decoding. HTML/SVG are inert source;
there is no WebView, script execution, remote image fetch or external URL launch.

A Markdown file has a table of contents of its headings on a Liquid Glass panel
at the top right of the preview, in rendered and source modes, expanded or not.
It lists headings H1–H6, both `#` headings and underlined ones, by their text
without Markdown (bold, code and links become plain text), and none from fenced
code. Closing `#` characters, as in `## Title ##`, are not taken off: the
rendering shows them in the heading, and the table of contents shows them too.
The panel is half the preview's width, from 160 to 260 points, and at most the
preview's height less 24 points; a longer list scrolls inside it. Clicking a
heading brings it to the top: its block in the rendering, its line in the
source. The heading you are reading is highlighted. That is the last heading at
or above the first block or line visible at the top of the preview; above the
first heading, none is highlighted. The list scrolls to keep the highlighted
heading in view. The list button beside Source hides or shows the table of
contents for that preview only. Whether it is shown is kept with the pane's
preview, like its file and scroll place: in memory while the window is open,
not saved. Opening a Markdown file, or reading it again with Retry, starts with
it shown. With no headings the button is disabled. Esc and `#anchor` links in
the preview behave as they did before.

A known limit, with or without the table of contents: in the rendering, a
Markdown file that mixes blocks of different heights, such as headings and code
blocks, can come back a few dozen to a few hundred points away from where it was
left when its pane is selected again. A file of paragraphs of one height comes
back where it was left.

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
