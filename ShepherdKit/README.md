# ShepherdKit

ShepherdKit is a local Swift package that holds the parts of Shepherd that
don't depend on a platform. The macOS app and the iOS app (ShepherdMobile/)
both depend on it (docs/mobile-design.md, section 8).

## What is in it

- `CoreKit/`: the bounded generation-1 framed wire/RPC/streams, official hc
  process/SSH transports, workspace CAS/recovery, terminal and attention models.
  This is the ordinary macOS Debug/Release and mobile backend, not a candidate
  waiting to replace a legacy runtime. See `Tests/CoreProtocol/README.md`.
- `HerdrKit/`: presentation/persistence models, pinned SSH credentials/key
  handling, bounded line primitives, local command execution and shell quoting.
  The directory keeps its historical name; it holds no herdr client or
  transport.
- `Machines/`: saved machine metadata/credentials, `MachineStore`,
  `HcMachineConnection`, `HcAttentionMonitor` and the hc mobile screen model.
- `Pairing/`: what the macOS and iOS apps both need to pair a Mac with the iOS
  app by QR code: the address kinds and the ranges each is held to
  (`PairingAddress`), looking a name up once and keeping only an address in
  the kind's range (`PairingAddressResolver`), the QR
  code's text (`PairingPayload`), the encrypted pairing messages and their
  confirmation code (`PairingProtocol`), and the line the Mac adds to
  `~/.ssh/authorized_keys` (`AuthorizedKeyLine`). The code for the device's
  key, kept in its Secure Enclave, is in
  `HerdrKit/Transport/SecureEnclaveSSHKey.swift`.
- `Notifications/`: the person's notification preferences
  (`NotificationPreferences`), what a notification says
  (`NotificationText.Content`) and where a click on one leads
  (`HcNotificationRoute`). Showing the notification stays in the app.
- `Agents/AgentKind.swift`: the agents herdr recognises (Claude Code, Codex,
  Pi).

The macOS app has Terminal File Drop, file Preview and the hc notification
coordinator/presenter. The mobile app has the hc screen/input, pairing, cache
and the existing archive history.

## How the apps use the package

Every type the apps use is `public`. A struct the apps construct has an
explicit public initializer, because the memberwise initializer Swift
synthesises is internal to the package.

The macOS app imports the package once, in `Shepherd/ShepherdKitImport.swift`,
with `@_exported import ShepherdKit`. An exported import makes the package's
types visible to every file of the importing module, so the app's other
files need no import line of their own. The iOS app imports it the same way, in `ShepherdMobile/ShepherdKitImport.swift`.

The package's compiler settings mirror the app targets'. They are Swift 6
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

Many runners under `Tests/` compile chosen production sources, from the package
and app alike, together with fakes into one test module. Other integration gates
import/link the actual normal product SDK and its exact objects. Historical
component source tests do not mean those files are part of the shipping SDK. So the runners list the package's files by path. `Resources.swift`
is part of every such build because the strings in the other files read
`bundle: .shepherdKit`, which it defines.

A fake that stands in for a package type is sometimes named by a public
signature in a compiled file (the `HerdrTransport` protocol, `AgentKind`).
Such a fake is declared `public` in the test file; otherwise the compiler
rejects the public signature for naming an internal type.

`Tests/Pairing/` compiles the package's sources the same way. Its SSH stages
also link the Citadel, swift-nio-ssh, swift-nio and swift-crypto that an app
build made (`--products`), because what they check can't be done with
stand-ins.
