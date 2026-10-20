# ShepherdKit

ShepherdKit is a local Swift package that holds the parts of Shepherd that
don't depend on a platform. The macOS app and the iOS app (ShepherdMobile/)
both depend on it (docs/mobile-design.md, section 8).

## What is in it

- `HerdrKit/`: everything that talks to herdr. `HerdrTransport` carries
  herdr's socket API, over the Unix socket on this Mac or over SSH, and
  `HerdrClient` wraps it in typed calls. The folder also holds three more
  things: the pane, tab and workspace models that herdr's snapshots are read
  into; the agent event JSON contract, `AgentEvent`; and `TerminalSession`,
  which attaches to a pane's terminal over SSH.
- `Machines/`: a `Machine` (a saved SSH host running herdr), the Keychain
  store for its credential, `MachineStore`, and `MachineMonitor`, which keeps
  one machine's panes up to date for the board, the list of panes the apps
  show.
- `Notifications/`: `NotificationPolicy` decides whether an agent event is
  shown, and `NotificationText` decides what the notification says. Showing
  the notification stays in the app.
- `Agents/AgentKind.swift`: the agents herdr recognises (Claude Code, Codex,
  Pi).

Everything macOS-only stays in the app: the embedded browser, the Node agent
runtime, Terminal File Drop, the file preview, the password managers, the
notification coordinator and presenter, and `LocalTerminalSession`, which
attaches to a pane on this Mac through a local PTY. One exception sits in the
package under `#if os(macOS)`: `LocalHerdrTransport` and `LocalCommand`,
which reach this Mac's own herdr. The iOS app compiles the package without
them.

## How the apps use the package

Every type the apps use is `public`. A struct the apps construct has an
explicit public initializer, because the memberwise initializer Swift
synthesises is internal to the package.

The macOS app imports the package once, in `Shepherd/ShepherdKitImport.swift`,
with `@_exported import ShepherdKit`. An exported import makes the package's
types visible to every file of the importing module, so the app's other
files need no import line of their own. The iOS app's files import it
directly.

The package's compiler settings mirror the app targets'. They are Swift 5
language mode, MainActor as the default isolation, and the upcoming-feature
flags that Xcode's "approachable concurrency" setting turns on. See
`Package.swift`.

## Strings

The package's user-facing strings live in
`Sources/ShepherdKit/Resources/Localizable.xcstrings`, in English, Korean and
Japanese. Code reads them with `bundle: .shepherdKit`. That accessor, in
`Resources.swift`, looks for the package's resource bundle in three places:
inside the app, beside an executable built with `swift build`, and inside a
framework. When no resource bundle exists, as in the test builds below, it
falls back to the main bundle.

A string that both the package and the app show is kept in both catalogs.

## Tests

The runners under `Tests/` don't import the ShepherdKit module. Each runner
compiles a chosen set of production source files, from the package and from
the app alike, together with fakes written for that test, into a single test
module. So the runners list the package's files by path. `Resources.swift`
is part of every such build because the strings in the other files read
`bundle: .shepherdKit`, which it defines.

A fake that stands in for a package type is sometimes named by a public
signature in a compiled file (the `HerdrTransport` protocol, `AgentKind`).
Such a fake is declared `public` in the test file; otherwise the compiler
rejects the public signature for naming an internal type.
