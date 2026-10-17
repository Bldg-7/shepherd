# ShepherdKit

ShepherdKit is a local Swift package that holds the parts of Shepherd that
don't depend on a platform. The macOS app depends on it today. The iOS app
planned in docs/mobile-design.md (section 8) will depend on it as well.

## What is in it

- `HerdrKit/`: everything that talks to herdr. `HerdrTransport` carries
  herdr's socket API, over the Unix socket on this Mac or over SSH, and
  `HerdrClient` wraps it in typed calls. The folder also holds the pane, tab
  and workspace models that herdr's snapshots are read into, the agent event
  JSON contract (`AgentEvent`), and `TerminalSession`, which attaches to a
  pane's terminal over SSH.
- `Machines/`: a `Machine` (a saved SSH host running herdr), the Keychain
  store for its credential, `MachineStore`, and `MachineMonitor`, which keeps
  one machine's panes up to date for the board.
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

## How the app uses the package

Every type the app reaches is `public`. A struct the app constructs has an
explicit public initializer, because the memberwise one Swift synthesises is
internal to the package.

The app imports the package once, in `Shepherd/ShepherdKitImport.swift`, with
`@_exported import ShepherdKit`. An exported import makes the package's
types visible to every file of the importing module, so the app's other
files need no import line of their own.

The package's compiler settings mirror the app target's: Swift 5 language
mode, the upcoming-feature flags Xcode groups as approachable concurrency,
and MainActor as the default isolation. See `Package.swift`.

## Strings

The package's user-facing strings live in
`Sources/ShepherdKit/Resources/Localizable.xcstrings`, in English, Korean and
Japanese. Code reads them with `bundle: .shepherdKit`. That accessor, in
`Resources.swift`, locates the package's resource bundle in the app, next to
an executable built with `swift build`, or in a framework. When no resource
bundle exists, as in the test builds below, it falls back to the main bundle.

A string that both the package and the app show is kept in both catalogs.

## Tests

The runners under `Tests/` don't import the ShepherdKit module. Each one
compiles a chosen set of production source files, from the package and from
the app alike, into a single test module, next to fakes written for that
test. For that reason the runners list the package's files by path, and
`Resources.swift` is part of every such build.

A fake that stands in for a type named by a public signature, such as the
`HerdrTransport` protocol or `AgentKind`, is declared `public` in the test
file, or the compiler rejects the public signature.
