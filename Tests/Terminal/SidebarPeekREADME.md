# Sidebar peek layout

Automatic startup/restoration is not pin intent. The detail-column observer
uses public NSSplitViewController/NSSplitViewItem APIs and KVO to recognize
an initially collapsed sidebar before the first hover, without toggling it or
rewriting native visibility. Native expansion must never pin the hover drawer.
An explicit pin action cancels startup inference, but native collapse remains
observed for the whole window lifetime. Divider-drag collapse releases pin intent;
expansion/hover never pins. Command revisions + live native state reject old
callbacks, and the button checks the live collapsed item to reopen in one press
even before a queued collapse update arrives. Tests include automatic-expanded, explicit-hidden, and
**automatic-native-collapsed with no toolbar toggle before first hover**.
`--restoration-red` omits the startup observer and must fail that last case.
`--collapse-red` restores the startup-only observer and must fail the pinned →
native close → one-button reopen regression. macOS sizing is min280/ideal360/
max480pt; native fullscreen automatic sizing is capped at360pt rather than
using the standard sidebar fraction to shrink the hover drawer. Explicit divider
resizing still works. Mobile retains its previous220/280/360pt sizing. Actual production ContentView/board/terminal + owned Herdr was
also tested in a separate whole-app fullscreen window, never toggling the pin
button before the first mouse hover; see build/sidebar-production-v4 evidence.

In actual fullscreen the hover drawer came up 140pt wide, half the 280pt
minimum, whatever the item's thickness settings were. The observer therefore
also holds a width constraint on the native sidebar's view: the preferred
360pt while the sidebar is not pinned, and the 280pt minimum while it is, so a
pinned sidebar can still be dragged narrower and closed. The component test
requires a revealed, unpinned drawer to be at least 360pt wide. `--width-red`
leaves that constraint inactive and must fail the check. Actual fullscreen with
the real pointer measured 140pt without the constraint and 360pt with it, and
the whole-app run (first hover, toolbar click, divider dragged closed, one-click
reopen, repeated hide and show) passed at 360pt; see
build/sidebar-width-collapse-v1 evidence.

```sh
python3 Tests/Terminal/run-sidebar-peek-tests.py --output /tmp/sidebar-FRESH \
  --swiftterm-products /path/to/DerivedData/Build/Products/Debug
```

Compiles the production `WorkspaceNavigationSplitView`/`WorkspaceSidebarState`
with actual SwiftUI, AppKit, SwiftTerm, current 7pt gutter and an owned kernel PTY.

**Actual fullscreen hover changes native column visibility to `.all`.** The
previous test simulated only the safe-area inset and missed this state change.
Only explicit pin action grants pin intent. Native collapse releases it, including
narrowing a pinned sidebar until it closes. Native hover/reveal never grants it.

**The actual detail is an HSplitView, not a directly hosted terminal.** Its
children create native hosting boundaries which reapply inherited sidebar safe
areas. The outer-only fix passed a flat-view GUI test but failed this real layout
(1714→1426pt). Each terminal/preview/browser child now uses production
`WorkspaceSidebarDetailLayout`, driven by the window's explicit pin environment.
A second failure was found with two HSplitView children: its native delegate
redistributes pane widths according to inherited safe area even if children
ignore it. The final `WorkspaceDetailSplitView` uses a normal native NSSplitView
and stable environment-forwarding NSHostingControllers with safeAreaRegions=[];
its rectangle is already positioned by SwiftUI. Native divider drag/minimums,
user proportion on resize, panel close/reopen and terminal host identity are
checked. `--legacy` retains the HSplitView boundary and must reproduce the bug.

The unshown-window component test calls public native `toggleSidebar` to reveal
and dismiss WITHOUT a pin action, waits for real `.all`/`.detailOnly` binding
updates and observes actual native sidebar safe-area adjustment. At 1200×700
and 900×600, with initially pinned, explicitly hidden, and automatically restored
native-hidden sidebars (the last without any preliminary toolbar toggle):

- Native reveal leaves terminal frame/instance/grid/resize callbacks/PTY stable.
- Explicit `togglePin` while already revealed/.all still reserves normal width.
- Repeated reveal/dismissal never changes pin intent or recreates the terminal.
- Top/trailing safe areas remain intact; one native sidebar, no reparenting,
  responder interception, private API, event heuristic or duplicate drawer.

`--legacy` retains the previous outer-only HSplitView policy, requiring it to
fail the same preview-width assertion after reveal.
Failed receipts remain evidence, not passing gates.

Actual fullscreen Space/mouse-hover/production-toolbar GUI qualification uses a
separate owned SwiftUI test app with private HOME, bounded lifetime, cursor and
foreground restoration; results live in the scoped operator evidence, not this
unshown component runner. Neither test touches installed Shepherd/SSH sessions.
iOS retains the original unbound native NavigationSplitView path.
