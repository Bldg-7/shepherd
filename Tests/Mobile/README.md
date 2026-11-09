# Keyboard avoidance

```sh
python3 Tests/Mobile/run-keyboard-avoidance-tests.py --output /tmp/shepherd-keyboard-FRESH
```

This runner compiles `ShepherdMobile/KeyboardAvoidance.swift` into an owned
UIKit fixture on newly created iPhone and iPad simulators and deletes only those
devices afterward. It checks synthetic docked, hidden, rotation, and narrow
container guide positions; verifies the docked-only guide configuration,
owning-view/window isolation, and teardown behavior; and verifies the ordinary
bottom safe area is consumed once.

It also hosts the production `KeyboardAvoidingBottomBarContainer` (which the
iPhone/iPad hc terminal screen, `HcMobileTerminalView`, wraps its bottom bar in)
in a `UIHostingController`. Its composer-shaped and response-bar-shaped
fixture inputs share that exact production wrapper, so the test observes the
representable → observable state → SwiftUI safe-area-inset placement path. It
checks baseline/undocked placement, one exact docked shift, initial docked
attachment, and narrow/landscape-sized hosted containers. The fixture injects
only a deterministic docked obstruction into the production bridge; this is
not a real OS floating/split keyboard gesture test. Synthetic guide positions
deliberately do not claim to exercise a real floating-keyboard UI.
`verification.json` records that distinction, natural fixture exit, and
defensive helper cleanup.
