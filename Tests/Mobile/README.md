# Mobile pane-header layout

```sh
python3 Tests/Mobile/run-pane-header-tests.py --output /tmp/shepherd-pane-header-FRESH
python3 Tests/Mobile/run-pane-header-tests.py --output /tmp/shepherd-pane-header-26-FRESH \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

The runner compiles the production `PaneHeaderViews.swift` into a small layout-only
UIKit/SwiftUI app. It creates its own iPhone and iPad simulators, installs only
that fixture, measures the real `NavigationStack` navigation bar, then removes
only those created devices. Existing booted simulators and installed apps are
not used or changed. The fixture performs no SSH, provider, pairing, credential
or other network operation. No simulator GUI is opened.

Cases cover:

- Short/very long titles and state changes; native title compression after
  fixed-size controls have taken their space.
- Full localized state labels from ShepherdKit's actual English/Korean/Japanese
  strings, reserving the widest label so status changes do not resize the badge.
- Narrow phone widths and compact/wide iPad layouts, normal and larger text.
- Actual pane bars (Back + status), and a stress variant with two additional
  icon menu actions. UIKit may suppress its centered title when those artificial
  extra actions leave a very narrow center span (thresholds differ by OS); the
  ordinary pane title must remain present.
- Native buttons keep their allocated sizes; badge text has its intrinsic width,
  is not clipped by an ancestor, and does not overlap the title.

Toolbar `Menu` labels become native UIKit bar buttons; their SwiftUI backgrounds
are not live views and are not used as geometry probes. UIKit also pre-truncates
its title label, so geometry is read from the native title container rather than
matching its text against the original long string. The badge measurement uses
the toolbar's effective Dynamic Type size, including UIKit's normal size cap.

Per-device JSON records, compiler/process logs and source hashes are retained
under the output path. `owned-devices.json` must end as an empty array.

# Keyboard avoidance

```sh
python3 Tests/Mobile/run-keyboard-avoidance-tests.py --output /tmp/shepherd-keyboard-FRESH
```

This runner compiles `ShepherdMobile/KeyboardAvoidance.swift` into an owned
UIKit fixture on newly created iPhone and iPad simulators and deletes only those
devices afterward. It checks synthetic docked, hidden, rotation, and narrow
container guide positions; verifies the docked-only guide configuration,
owning-view/window isolation, and teardown behavior; and verifies the ordinary
bottom safe area is consumed once. Synthetic guide positions deliberately do
not claim to exercise a real floating-keyboard UI. `verification.json` records
that distinction, natural fixture exit, and defensive helper cleanup.
