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
  token recognition, size limits, FIFO/directory/binary rejection, cancellation,
  native Markdown block layout and width-based iPad policy.
- Production SFTP reader compiled with an **explicit in-memory Citadel module**:
  read-only flags, pinned endpoint, no shell-command API, bounded chunk reads,
  non-regular/oversized files, cancellation and late acquisition compensation.
- Actual model and MachineStore with in-memory secrets/SSH and a pane-value seam:
  no local credential lookup, missing/refreshed pin, stale endpoint/epoch denial,
  cancellation and the actual 15-second read timeout/connection cleanup.
- Actual SwiftTerm objects with owned windowless AppKit views: screen cells,
  Korean wide characters, soft wraps, OSC8 vs implicit links, BiDi fallback denial
  and current coordinator callback. **Not GUI click automation.**

## Product behavior

Mac file paths, file URIs and file OSC8 links all use Cmd-click for Shepherd
preview. Ordinary clicks remain TUI input, not a second local preview on release.
iOS recognizes file touches at began and owns the full gesture before native TUI
recognizers can emit a tap/drag. Non-file gestures remain native TUI behavior. Markdown file links stay in the same preview and
resolve against the displayed file's parent directory. Relative terminal links
resolve against the clicked pane's reported cwd, not the app's cwd.

macOS: browser/preview are mutually exclusive columns. Switching hides the
browser region, not the browser feature or its tabs/profiles/agent connection.
The last file can be reopened via the toolbar. Files and file contents are
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

Only the clicked Machine is accessed. Localhost in a file URI denotes that source
machine. Other URI hosts must match the configured hostname (or known local Mac
host aliases); they never redirect the reader. Nested Herdr machine filesystem
routing is explicitly unsupported. Unknown cwd requires an absolute path; ~/ and
shell variables are not expanded. Ambiguous bare paths containing spaces should
use an explicit OSC8/file URI. Unsupported URI schemes are not dispatched.

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
must deliver zero PTY bytes; ordinary clicks must deliver a complete mouse gesture.
OSC8, implicit file URIs, source locations, drag cancellation, preview failure and
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
